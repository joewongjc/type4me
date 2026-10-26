import Foundation
import os

enum GrokASRError: Error, LocalizedError {
    case unsupportedProvider
    case handshakeTimedOut
    case httpRejected(statusCode: Int)
    case closedBeforeHandshake(code: Int, reason: String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "GrokASRClient requires GrokASRConfig"
        case .handshakeTimedOut:
            return L("Grok STT 握手超时", "Grok STT handshake timed out")
        case .httpRejected(let statusCode):
            return Self.describeHTTPStatus(statusCode)
        case .closedBeforeHandshake(let code, let reason):
            if let reason, !reason.isEmpty {
                return L("Grok 连接被拒绝", "Grok connection rejected") + " (\(code)): \(reason)"
            }
            return L("Grok 连接被拒绝", "Grok connection rejected") + " (\(code))"
        }
    }

    private static func describeHTTPStatus(_ statusCode: Int) -> String {
        switch statusCode {
        case 401:
            return L("API Key 无效或已禁用", "Invalid or disabled API key") + " (HTTP 401)"
        case 403:
            return L("API Key 无权限访问该服务", "API key not authorized for this service") + " (HTTP 403)"
        case 429:
            return L("请求过于频繁", "Too many requests") + " (HTTP 429)"
        default:
            let reason = HTTPURLResponse.localizedString(forStatusCode: statusCode)
            return L("服务器拒绝连接", "Server rejected connection") + " (HTTP \(statusCode): \(reason))"
        }
    }
}

actor GrokASRClient: SpeechRecognizer {

    private let logger = Logger(subsystem: "com.type4me.asr", category: "GrokASRClient")

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var session: URLSession?
    private var sessionDelegate: GrokWebSocketDelegate?

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    private var transcriptState: GrokTranscriptState = .empty
    private var lastTranscript: RecognitionTranscript = .empty
    private var didRequestClose = false
    private var pendingFinalCommit = false
    private var serverReady = false
    private var sessionCompleted = false

    private var connectionGate: GrokConnectionGate?

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events { return existing }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream
        return stream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions = ASRRequestOptions()) async throws {
        guard let grokConfig = config as? GrokASRConfig else {
            throw GrokASRError.unsupportedProvider
        }

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream

        let url = try GrokProtocol.buildWebSocketURL(config: grokConfig, options: options)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(grokConfig.apiKey)", forHTTPHeaderField: "Authorization")

        let gate = GrokConnectionGate()
        let delegate = GrokWebSocketDelegate(gate: gate)
        let session = URLSession(configuration: options.urlSessionConfiguration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.resume()

        self.connectionGate = gate
        self.sessionDelegate = delegate
        self.session = session
        self.webSocketTask = task
        transcriptState = .empty
        lastTranscript = .empty
        didRequestClose = false
        pendingFinalCommit = false
        serverReady = false
        sessionCompleted = false

        startReceiveLoop()

        try await gate.waitUntilOpen(timeout: .seconds(5))
        try await waitUntilServerReady(timeout: .seconds(5))
        logger.info("Grok WebSocket connected: \(url.absoluteString, privacy: .private(mask: .hash))")
    }

    func sendAudio(_ data: Data) async throws {
        guard serverReady, let task = webSocketTask else { return }
        try await task.send(.data(data))
    }

    func endAudio() async throws {
        guard let task = webSocketTask else { return }
        pendingFinalCommit = true
        didRequestClose = true
        try await task.send(.string(GrokProtocol.finalizeMessage()))
        try await task.send(.string(GrokProtocol.audioDoneMessage()))
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
        transcriptState = .empty
        lastTranscript = .empty
        didRequestClose = false
        pendingFinalCommit = false
        serverReady = false
        sessionCompleted = false
        logger.info("Grok disconnected")
    }

    private func waitUntilServerReady(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while !serverReady {
            if ContinuousClock.now >= deadline {
                throw GrokASRError.handshakeTimedOut
            }
            try await Task.sleep(for: .milliseconds(25))
        }
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
                    if Task.isCancelled { break }
                    logger.info("Grok receive loop ended: \(String(describing: error), privacy: .public)")
                    let didClose = await self.didRequestClose
                    if didClose {
                        await self.emitEvent(.completed)
                    } else {
                        await self.emitEvent(.error(error))
                    }
                    break
                }
            }
            await self.eventContinuation?.finish()
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard !sessionCompleted else { return }
        do {
            let data: Data
            switch message {
            case .data(let d): data = d
            case .string(let s): data = Data(s.utf8)
            @unknown default: return
            }

            if let update = try GrokProtocol.makeTranscriptUpdate(
                from: data,
                state: transcriptState,
                isFinalCommit: pendingFinalCommit
            ) {
                if update.serverReady {
                    serverReady = true
                    return
                }

                transcriptState = update.state
                guard update.transcript != lastTranscript else { return }
                lastTranscript = update.transcript
                logger.info("Grok transcript confirmed=\(update.transcript.confirmedSegments.count) partial=\(update.transcript.partialText.count) final=\(update.transcript.isFinal)")
                emitEvent(.transcript(update.transcript))

                if update.transcript.isFinal && pendingFinalCommit {
                    sessionCompleted = true
                    emitEvent(.completed)
                    eventContinuation?.finish()
                }
            }
        } catch {
            logger.error("Grok decode error: \(String(describing: error), privacy: .public)")
            emitEvent(.error(error))
        }
    }

    private func emitEvent(_ event: RecognitionEvent) {
        eventContinuation?.yield(event)
    }
}

actor GrokConnectionGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var isOpen = false
    private var failure: Error?

    var hasOpened: Bool { isOpen }

    func waitUntilOpen(timeout: Duration) async throws {
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            self.markFailure(GrokASRError.handshakeTimedOut)
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

final class GrokWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {

    private let gate: GrokConnectionGate

    init(gate: GrokConnectionGate) { self.gate = gate }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { await gate.markOpen() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task {
            if let response = task.response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode),
               await !gate.hasOpened {
                await gate.markFailure(GrokASRError.httpRejected(statusCode: response.statusCode))
                return
            }
            guard let error else { return }
            await gate.markFailure(error)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        Task {
            guard await !gate.hasOpened else { return }
            await gate.markFailure(GrokASRError.closedBeforeHandshake(code: Int(closeCode.rawValue), reason: reasonText))
        }
    }
}
