import Foundation
import os

protocol StepFunWebSocketTransport: Sendable {
    func start() async
    func send(_ message: String) async throws
    func receive() async throws -> Data
    func close() async
}

typealias StepFunWebSocketTransportFactory = @Sendable (
    URLRequest,
    URLSessionConfiguration,
    StepFunSessionReadinessGate
) -> any StepFunWebSocketTransport

actor StepFunASRClient: SpeechRecognizer {

    private let logger = Logger(
        subsystem: "com.type4me.asr",
        category: "StepFunASRClient"
    )

    private let transportFactory: StepFunWebSocketTransportFactory
    private var transport: (any StepFunWebSocketTransport)?
    private var receiveTask: Task<Void, Never>?
    private var readinessGate: StepFunSessionReadinessGate?

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var stream: AsyncStream<RecognitionEvent>?
    private var lastTranscript: RecognitionTranscript = .empty
    private var didRequestCommit = false
    private var didComplete = false

    init(transportFactory: @escaping StepFunWebSocketTransportFactory = { request, configuration, gate in
        StepFunURLSessionWebSocketTransport(
            request: request,
            configuration: configuration,
            readinessGate: gate
        )
    }) {
        self.transportFactory = transportFactory
    }

    var events: AsyncStream<RecognitionEvent> {
        if let stream { return stream }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.stream = stream
        eventContinuation = continuation
        return stream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions = ASRRequestOptions()) async throws {
        guard let config = config as? StepFunASRConfig else {
            throw StepFunASRError.invalidConfig
        }

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.stream = stream
        eventContinuation = continuation
        lastTranscript = .empty
        didRequestCommit = false
        didComplete = false

        var request = URLRequest(url: StepFunASRConfig.endpoint)
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let gate = StepFunSessionReadinessGate()
        let transport = transportFactory(
            request,
            options.urlSessionConfiguration,
            gate
        )

        readinessGate = gate
        self.transport = transport
        await transport.start()
        startReceiveLoop()

        try await transport.send(StepFunASRProtocol.buildSessionUpdateMessage(options: options))
        try await gate.waitUntilReady(timeout: .seconds(5))
        logger.info("StepFun streaming ASR session ready")
    }

    func sendAudio(_ data: Data) async throws {
        guard let transport, !data.isEmpty else { return }
        let message = StepFunASRProtocol.buildAppendAudioMessage(data)
        try await transport.send(message)
    }

    func endAudio() async throws {
        guard let transport, !didRequestCommit else { return }
        try await transport.send(StepFunASRProtocol.buildCommitMessage())
        didRequestCommit = true
    }

    func disconnect() async {
        // Wake a connect() that is still waiting for session.updated. Do this
        // explicitly instead of relying on URLSession's close callback, which
        // may arrive later (or not at all for an injected transport).
        await readinessGate?.markFailure(CancellationError())
        receiveTask?.cancel()
        receiveTask = nil
        await transport?.close()
        transport = nil
        readinessGate = nil
        eventContinuation?.finish()
        eventContinuation = nil
        stream = nil
        lastTranscript = .empty
        didRequestCommit = false
        didComplete = false
        logger.info("StepFun streaming ASR disconnected")
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let transport = await self.transport else { break }
                    let data = try await transport.receive()
                    await self.handle(data)
                } catch {
                    if Task.isCancelled { break }
                    await self.handleReceiveFailure(error)
                    break
                }
            }
            let continuation = await self.eventContinuation
            continuation?.finish()
        }
    }

    private func handle(_ data: Data) async {
        do {
            guard let event = try StepFunASRProtocol.parseServerEvent(from: data) else { return }
            switch event {
            case .sessionReady:
                await readinessGate?.markReady()

            case .transcript(let transcript):
                guard transcript != lastTranscript else { return }
                lastTranscript = transcript
                eventContinuation?.yield(.transcript(transcript))
                if transcript.isFinal {
                    finishRecognition()
                }

            case .error(let error):
                await readinessGate?.markFailure(error)
                eventContinuation?.yield(.error(error))
                finishRecognition()
            }
        } catch {
            await readinessGate?.markFailure(error)
            eventContinuation?.yield(.error(error))
            if didRequestCommit {
                finishRecognition()
            }
        }
    }

    private func handleReceiveFailure(_ error: Error) async {
        let isReady = await readinessGate?.isReady ?? false
        if !isReady {
            await readinessGate?.markFailure(error)
            return
        }
        if !didComplete {
            eventContinuation?.yield(.error(error))
            finishRecognition()
        }
    }

    private func finishRecognition() {
        guard !didComplete else { return }
        didComplete = true
        eventContinuation?.yield(.completed)
    }
}

actor StepFunSessionReadinessGate {

    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var isReady = false
    private var failure: Error?

    func waitUntilReady(timeout: Duration) async throws {
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            self.markFailure(StepFunASRError.handshakeTimedOut)
        }
        defer { timeoutTask.cancel() }
        try await wait()
    }

    func markReady() {
        guard !isReady, failure == nil else { return }
        isReady = true
        continuation?.resume()
        continuation = nil
    }

    func markFailure(_ error: Error) {
        guard !isReady, failure == nil else { return }
        failure = error
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func wait() async throws {
        if isReady { return }
        if let failure { throw failure }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private final class StepFunURLSessionWebSocketTransport: StepFunWebSocketTransport, @unchecked Sendable {

    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let delegate: StepFunWebSocketDelegate

    init(
        request: URLRequest,
        configuration: URLSessionConfiguration,
        readinessGate: StepFunSessionReadinessGate
    ) {
        let delegate = StepFunWebSocketDelegate(readinessGate: readinessGate)
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        self.delegate = delegate
        self.session = session
        self.task = session.webSocketTask(with: request)
    }

    func start() async {
        task.resume()
    }

    func send(_ message: String) async throws {
        try await task.send(.string(message))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data):
            return data
        case .string(let text):
            return Data(text.utf8)
        @unknown default:
            throw StepFunASRError.invalidResponse
        }
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}

private final class StepFunWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {

    private let readinessGate: StepFunSessionReadinessGate

    init(readinessGate: StepFunSessionReadinessGate) {
        self.readinessGate = readinessGate
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        Task {
            guard await !readinessGate.isReady else { return }
            await readinessGate.markFailure(
                StepFunASRError.closedBeforeSessionReady(
                    code: Int(closeCode.rawValue),
                    reason: reasonText
                )
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task {
            await readinessGate.markFailure(error)
        }
    }
}
