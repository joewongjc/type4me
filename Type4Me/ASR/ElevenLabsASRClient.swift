import Foundation
import os

enum ElevenLabsASRError: Error, LocalizedError {
    case unsupportedProvider
    case handshakeTimedOut
    case closedBeforeHandshake(code: Int, reason: String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "ElevenLabsASRClient requires ElevenLabsASRConfig"
        case .handshakeTimedOut:
            return "ElevenLabs WebSocket handshake timed out"
        case .closedBeforeHandshake(let code, let reason):
            if let reason, !reason.isEmpty {
                return "ElevenLabs WebSocket closed before handshake (\(code)): \(reason)"
            }
            return "ElevenLabs WebSocket closed before handshake (\(code))"
        }
    }
}

actor ElevenLabsASRClient: SpeechRecognizer {

    private let logger = Logger(subsystem: "com.type4me.asr", category: "ElevenLabsASRClient")

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var session: URLSession?
    private var sessionDelegate: ElevenLabsWebSocketDelegate?

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    private var confirmedSegments: [String] = []
    private var lastTranscript: RecognitionTranscript = .empty
    private var audioPacketCount = 0
    private var didRequestClose = false
    private var pendingFinalCommit = false   // true after endAudio() sends commit
    private var connectionGate: ElevenLabsConnectionGate?

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events { return existing }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream
        return stream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions = ASRRequestOptions()) async throws {
        guard let elevenConfig = config as? ElevenLabsASRConfig else {
            throw ElevenLabsASRError.unsupportedProvider
        }

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream

        let url = try ElevenLabsProtocol.buildWebSocketURL(config: elevenConfig, options: options)
        var request = URLRequest(url: url)
        request.setValue(elevenConfig.apiKey, forHTTPHeaderField: "xi-api-key")

        let gate = ElevenLabsConnectionGate()
        let delegate = ElevenLabsWebSocketDelegate(gate: gate)
        let session = URLSession(configuration: options.urlSessionConfiguration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.resume()

        self.connectionGate = gate
        self.sessionDelegate = delegate
        self.session = session
        self.webSocketTask = task
        confirmedSegments = []
        lastTranscript = .empty
        audioPacketCount = 0
        didRequestClose = false
        pendingFinalCommit = false

        try await gate.waitUntilOpen(timeout: .seconds(5))
        logger.info("ElevenLabs WebSocket connected: \(url.absoluteString, privacy: .private(mask: .hash))")
        startReceiveLoop()
    }

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask else { return }
        // ElevenLabs STT requires base64-encoded JSON, not raw binary
        try await task.send(.string(ElevenLabsProtocol.audioChunkMessage(data)))
        audioPacketCount += 1
    }

    func endAudio() async throws {
        guard let task = webSocketTask else { return }
        pendingFinalCommit = true
        didRequestClose = true
        try await task.send(.string(ElevenLabsProtocol.commitMessage()))
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        sessionDelegate = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        connectionGate = nil
        confirmedSegments = []
        lastTranscript = .empty
        audioPacketCount = 0
        didRequestClose = false
        logger.info("ElevenLabs disconnected")
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = await self.webSocketTask else { break }
                    let message = try await task.receive()
                    await self.handleMessage(message)
                } catch {
                    if Task.isCancelled { break }
                    logger.info("ElevenLabs receive loop ended: \(String(describing: error), privacy: .public)")
                    let didClose = await self.didRequestClose
                    let packetCount = await self.audioPacketCount
                    if didClose || packetCount > 0 {
                        await self.emitEvent(.completed)
                    } else {
                        await self.emitEvent(.error(error))
                        await self.emitEvent(.completed)
                    }
                    break
                }
            }
            await self.eventContinuation?.finish()
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        do {
            let data: Data
            switch message {
            case .data(let d): data = d
            case .string(let s):
                data = Data(s.utf8)
            @unknown default: return
            }

            if let update = try ElevenLabsProtocol.makeTranscriptUpdate(
                from: data,
                confirmedSegments: confirmedSegments,
                isFinalCommit: pendingFinalCommit
            ) {
                confirmedSegments = update.confirmedSegments
                guard update.transcript != lastTranscript else { return }
                lastTranscript = update.transcript
                logger.info("ElevenLabs transcript confirmed=\(update.transcript.confirmedSegments.count) partial=\(update.transcript.partialText.count) final=\(update.transcript.isFinal)")
                emitEvent(.transcript(update.transcript))
            }
        } catch {
            logger.error("ElevenLabs decode error: \(String(describing: error), privacy: .public)")
            emitEvent(.error(error))
        }
    }

    private func emitEvent(_ event: RecognitionEvent) {
        eventContinuation?.yield(event)
    }
}

// MARK: - Connection Gate

actor ElevenLabsConnectionGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var isOpen = false
    private var failure: Error?

    var hasOpened: Bool { isOpen }

    func waitUntilOpen(timeout: Duration) async throws {
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            self.markFailure(ElevenLabsASRError.handshakeTimedOut)
        }
        defer { timeoutTask.cancel() }
        try await wait()
    }

    func markOpen() {
        guard !isOpen else { return }
        isOpen = true
        continuation?.resume()
        continuation = nil
    }

    func markFailure(_ error: Error) {
        guard !isOpen, failure == nil else { return }
        failure = error
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func wait() async throws {
        if isOpen { return }
        if let failure { throw failure }
        try await withCheckedThrowingContinuation { self.continuation = $0 }
    }
}

// MARK: - WebSocket Delegate

final class ElevenLabsWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {

    private let gate: ElevenLabsConnectionGate

    init(gate: ElevenLabsConnectionGate) { self.gate = gate }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { await gate.markOpen() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { await gate.markFailure(error) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        Task {
            guard await !gate.hasOpened else { return }
            await gate.markFailure(ElevenLabsASRError.closedBeforeHandshake(code: Int(closeCode.rawValue), reason: reasonText))
        }
    }
}
