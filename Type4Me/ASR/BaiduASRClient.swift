import Foundation
import os

enum BaiduASRError: Error, LocalizedError {
    case unsupportedProvider
    case handshakeTimedOut
    case closedBeforeHandshake(code: Int, reason: String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "BaiduASRClient requires BaiduASRConfig"
        case .handshakeTimedOut:
            return "Baidu realtime ASR WebSocket handshake timed out"
        case .closedBeforeHandshake(let code, let reason):
            if let reason, !reason.isEmpty {
                return "Baidu realtime ASR WebSocket closed before handshake completed (\(code)): \(reason)"
            }
            return "Baidu realtime ASR WebSocket closed before handshake completed (\(code))"
        }
    }
}

actor BaiduASRClient: SpeechRecognizer {

    private let logger = Logger(
        subsystem: "com.type4me.asr",
        category: "BaiduASRClient"
    )

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var session: URLSession?
    private var sessionDelegate: BaiduWebSocketDelegate?
    private var connectionGate: BaiduConnectionGate?

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    private var confirmedSegments: [String] = []
    private var lastTranscript: RecognitionTranscript = .empty
    private var audioPacketCount = 0
    private var didRequestFinish = false

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
        guard let baiduConfig = config as? BaiduASRConfig else {
            throw BaiduASRError.unsupportedProvider
        }

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream

        let gate = BaiduConnectionGate()
        let delegate = BaiduWebSocketDelegate(connectionGate: gate)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let requestID = UUID().uuidString.lowercased()
        let task = session.webSocketTask(with: BaiduProtocol.buildWebSocketURL(requestID: requestID))
        task.resume()

        connectionGate = gate
        sessionDelegate = delegate
        self.session = session
        webSocketTask = task
        confirmedSegments = []
        lastTranscript = .empty
        audioPacketCount = 0
        didRequestFinish = false

        try await gate.waitUntilOpen(timeout: .seconds(5))
        try await task.send(.string(BaiduProtocol.buildStartMessage(config: baiduConfig, options: options)))
        logger.info("Baidu realtime ASR WebSocket connected")
        startReceiveLoop()
    }

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask else { return }
        audioPacketCount += 1
        try await task.send(.data(data))
    }

    func endAudio() async throws {
        guard let task = webSocketTask else { return }
        didRequestFinish = true
        try await task.send(.string(BaiduProtocol.buildFinishMessage()))
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        sessionDelegate = nil
        connectionGate = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        confirmedSegments = []
        lastTranscript = .empty
        audioPacketCount = 0
        didRequestFinish = false
        logger.info("Baidu realtime ASR disconnected")
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

                    let didRequestFinish = await self.didRequestFinish
                    let audioPacketCount = await self.audioPacketCount

                    if didRequestFinish || audioPacketCount > 0 {
                        await self.emitEvent(.completed)
                    } else {
                        await self.emitEvent(.error(error))
                        await self.emitEvent(.completed)
                    }
                    break
                }
            }

            let continuation = await self.eventContinuation
            continuation?.finish()
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

            guard let event = try BaiduProtocol.parseServerEvent(
                from: data,
                confirmedSegments: confirmedSegments
            ) else {
                return
            }

            switch event {
            case .transcript(let update):
                confirmedSegments = update.confirmedSegments
                guard update.transcript != lastTranscript else { return }
                lastTranscript = update.transcript
                emitEvent(.transcript(update.transcript))

            case .sentenceFailed(let code, let message, let update):
                confirmedSegments = update.confirmedSegments
                if update.transcript != lastTranscript {
                    lastTranscript = update.transcript
                    emitEvent(.transcript(update.transcript))
                }
                logger.warning("Baidu sentence failed code=\(code, privacy: .public) message=\(message, privacy: .public)")

            case .serverError(let code, let message):
                let error = BaiduProtocolError.serverError(code: code, message: message)
                emitEvent(.error(error))
                emitEvent(.completed)
                webSocketTask?.cancel(with: .normalClosure, reason: nil)
                webSocketTask = nil
            }
        } catch {
            emitEvent(.error(error))
        }
    }

    private func emitEvent(_ event: RecognitionEvent) {
        eventContinuation?.yield(event)
    }
}

private actor BaiduConnectionGate {

    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var isOpen = false
    private var failure: Error?

    var hasOpened: Bool { isOpen }

    func waitUntilOpen(timeout: Duration) async throws {
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            self.markFailure(BaiduASRError.handshakeTimedOut)
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

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private final class BaiduWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {

    private let connectionGate: BaiduConnectionGate

    init(connectionGate: BaiduConnectionGate) {
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
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        Task {
            guard await !connectionGate.hasOpened else { return }
            await connectionGate.markFailure(
                BaiduASRError.closedBeforeHandshake(
                    code: Int(closeCode.rawValue),
                    reason: reasonText
                )
            )
        }
    }
}
