import Foundation
import os

enum BailianASRError: Error, LocalizedError {
    case unsupportedProvider
    case handshakeTimedOut
    case closedBeforeTaskStart(code: Int, reason: String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "BailianASRClient requires BailianASRConfig"
        case .handshakeTimedOut:
            return "Alibaba Cloud Bailian task-start handshake timed out"
        case .closedBeforeTaskStart(let code, let reason):
            if let reason, !reason.isEmpty {
                return "Alibaba Cloud Bailian socket closed before task-started (\(code)): \(reason)"
            }
            return "Alibaba Cloud Bailian socket closed before task-started (\(code))"
        }
    }
}

actor BailianASRClient: SpeechRecognizer {

    private let logger = Logger(
        subsystem: "com.type4me.asr",
        category: "BailianASRClient"
    )

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var session: URLSession?
    private var sessionDelegate: BailianWebSocketDelegate?
    private var taskStartGate: BailianTaskStartGate?

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    private var confirmedSegments: [String] = []
    private var lastTranscript: RecognitionTranscript = .empty
    private var audioPacketCount = 0
    private var didRequestFinish = false
    private var currentTaskID: String?

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
        guard let bailianConfig = config as? BailianASRConfig else {
            throw BailianASRError.unsupportedProvider
        }

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream

        var request = URLRequest(url: BailianProtocol.endpoint)
        request.setValue("Bearer \(bailianConfig.apiKey)", forHTTPHeaderField: "Authorization")

        let taskID = UUID().uuidString.lowercased()
        let gate = BailianTaskStartGate()
        let delegate = BailianWebSocketDelegate(taskStartGate: gate)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.resume()

        sessionDelegate = delegate
        self.session = session
        webSocketTask = task
        taskStartGate = gate
        confirmedSegments = []
        lastTranscript = .empty
        audioPacketCount = 0
        didRequestFinish = false
        currentTaskID = taskID

        startReceiveLoop()

        let runTaskMessage = BailianProtocol.buildRunTaskMessage(
            config: bailianConfig,
            options: options,
            taskID: taskID
        )
        try await task.send(.string(runTaskMessage))
        try await gate.waitUntilStarted(timeout: .seconds(5))
        logger.info("Alibaba Cloud Bailian ASR task started")
    }

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask else { return }
        audioPacketCount += 1
        try await task.send(.data(data))
    }

    func endAudio() async throws {
        guard let task = webSocketTask,
              let taskID = currentTaskID
        else { return }

        didRequestFinish = true
        try await task.send(.string(BailianProtocol.buildFinishTaskMessage(taskID: taskID)))
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        sessionDelegate = nil
        taskStartGate = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        confirmedSegments = []
        lastTranscript = .empty
        audioPacketCount = 0
        didRequestFinish = false
        currentTaskID = nil
        logger.info("Alibaba Cloud Bailian disconnected")
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

                    let gate = await self.taskStartGate
                    let gateStarted = await gate?.hasStarted ?? false
                    let didRequestFinish = await self.didRequestFinish
                    let audioPacketCount = await self.audioPacketCount

                    if let gate, !gateStarted {
                        await gate.markFailure(error)
                    } else if didRequestFinish || audioPacketCount > 0 {
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

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
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

            guard let event = try BailianProtocol.parseServerEvent(
                from: data,
                confirmedSegments: confirmedSegments
            ) else {
                return
            }

            switch event {
            case .taskStarted:
                if let gate = taskStartGate {
                    await gate.markStarted()
                }

            case .transcript(let update):
                confirmedSegments = update.confirmedSegments
                guard update.transcript != lastTranscript else { return }
                lastTranscript = update.transcript
                emitEvent(.transcript(update.transcript))

            case .taskFinished:
                emitEvent(.completed)

            case .taskFailed(let code, let message):
                let error = BailianProtocolError.taskFailed(code: code, message: message)
                if let gate = taskStartGate {
                    await gate.markFailure(error)
                }
                emitEvent(.error(error))
                emitEvent(.completed)
                webSocketTask?.cancel(with: .normalClosure, reason: nil)
                webSocketTask = nil
            }
        } catch {
            if let gate = taskStartGate {
                await gate.markFailure(error)
            }
            emitEvent(.error(error))
        }
    }

    private func emitEvent(_ event: RecognitionEvent) {
        eventContinuation?.yield(event)
    }
}

private actor BailianTaskStartGate {

    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var isStarted = false
    private var failure: Error?

    var hasStarted: Bool { isStarted }

    func waitUntilStarted(timeout: Duration) async throws {
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            self.markFailure(BailianASRError.handshakeTimedOut)
        }

        defer { timeoutTask.cancel() }
        try await wait()
    }

    func markStarted() {
        guard !isStarted else { return }
        isStarted = true
        continuation?.resume()
        continuation = nil
    }

    func markFailure(_ error: Error) {
        guard !isStarted, failure == nil else { return }
        failure = error
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func wait() async throws {
        if isStarted { return }
        if let failure { throw failure }

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private final class BailianWebSocketDelegate: NSObject, URLSessionWebSocketDelegate {

    private let taskStartGate: BailianTaskStartGate

    init(taskStartGate: BailianTaskStartGate) {
        self.taskStartGate = taskStartGate
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        Task {
            guard await !taskStartGate.hasStarted else { return }
            await taskStartGate.markFailure(
                BailianASRError.closedBeforeTaskStart(
                    code: Int(closeCode.rawValue),
                    reason: reasonText
                )
            )
        }
    }
}
