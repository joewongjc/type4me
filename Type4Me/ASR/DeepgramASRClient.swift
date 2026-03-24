import Foundation
import os

enum DeepgramASRError: Error, LocalizedError {
    case unsupportedProvider
    case handshakeTimedOut
    case closedBeforeHandshake(code: Int, reason: String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "DeepgramASRClient requires DeepgramASRConfig"
        case .handshakeTimedOut:
            return "Deepgram WebSocket handshake timed out"
        case .closedBeforeHandshake(let code, let reason):
            if let reason, !reason.isEmpty {
                return "Deepgram WebSocket closed before handshake completed (\(code)): \(reason)"
            }
            return "Deepgram WebSocket closed before handshake completed (\(code))"
        }
    }
}

actor DeepgramASRClient: SpeechRecognizer {

    private let logger = Logger(
        subsystem: "com.type4me.asr",
        category: "DeepgramASRClient"
    )

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var session: URLSession?
    private var sessionDelegate: DeepgramWebSocketDelegate?

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    private var confirmedSegments: [String] = []
    private var lastTranscript: RecognitionTranscript = .empty
    private var audioPacketCount = 0
    private var didRequestClose = false
    private var connectionGate: DeepgramConnectionGate?

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events {
            return existing
        }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream
        return stream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions = ASRRequestOptions()) async throws {
        guard let deepgramConfig = config as? DeepgramASRConfig else {
            throw DeepgramASRError.unsupportedProvider
        }

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream

        let url = try DeepgramProtocol.buildWebSocketURL(
            config: deepgramConfig,
            options: options
        )
        var request = URLRequest(url: url)
        request.setValue("Token \(deepgramConfig.apiKey)", forHTTPHeaderField: "Authorization")

        let connectionGate = DeepgramConnectionGate()
        let delegate = DeepgramWebSocketDelegate(connectionGate: connectionGate)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.resume()

        self.connectionGate = connectionGate
        sessionDelegate = delegate
        self.session = session
        webSocketTask = task
        confirmedSegments = []
        lastTranscript = .empty
        audioPacketCount = 0
        didRequestClose = false

        try await connectionGate.waitUntilOpen(timeout: .seconds(5))
        logger.info("Deepgram WebSocket connected: \(url.absoluteString, privacy: .private(mask: .hash))")
        startReceiveLoop()
    }

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask else { return }
        audioPacketCount += 1
        try await task.send(.data(data))
    }

    func endAudio() async throws {
        guard let task = webSocketTask else { return }
        didRequestClose = true
        try await task.send(.string(DeepgramProtocol.closeStreamMessage()))
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
        logger.info("Deepgram disconnected")
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = await self.webSocketTask else { break }
                    let message = try await task.receive()
                    await self.handleMessage(message)
                } catch {
                    if Task.isCancelled {
                        break
                    }

                    logger.info("Deepgram receive loop ended: \(String(describing: error), privacy: .public)")
                    let didRequestClose = await self.didRequestClose
                    let audioPacketCount = await self.audioPacketCount
                    if didRequestClose || audioPacketCount > 0 {
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
            case .data(let payload):
                data = payload
            case .string(let text):
                data = Data(text.utf8)
            @unknown default:
                return
            }

            if let update = try DeepgramProtocol.makeTranscriptUpdate(
                from: data,
                confirmedSegments: confirmedSegments
            ) {
                confirmedSegments = update.confirmedSegments
                guard update.transcript != lastTranscript else { return }
                lastTranscript = update.transcript

                logger.info(
                    "Deepgram transcript update confirmed=\(update.transcript.confirmedSegments.count) partial=\(update.transcript.partialText.count) final=\(update.transcript.isFinal)"
                )
                emitEvent(.transcript(update.transcript))
            }
        } catch {
            logger.error("Deepgram decode error: \(String(describing: error), privacy: .public)")
            emitEvent(.error(error))
        }
    }

    private func emitEvent(_ event: RecognitionEvent) {
        eventContinuation?.yield(event)
    }
}

final class DeepgramWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {

    private let connectionGate: DeepgramConnectionGate

    init(connectionGate: DeepgramConnectionGate) {
        self.connectionGate = connectionGate
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task {
            await connectionGate.markOpen()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task {
            await connectionGate.markFailure(error)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        // Only report failure if handshake hasn't completed yet.
        // Post-handshake closes are normal session endings, not errors.
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        Task {
            guard await !connectionGate.hasOpened else { return }
            await connectionGate.markFailure(
                DeepgramASRError.closedBeforeHandshake(
                    code: Int(closeCode.rawValue),
                    reason: reasonText
                )
            )
        }
    }
}
