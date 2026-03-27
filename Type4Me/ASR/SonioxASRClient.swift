import Foundation
import os

enum SonioxASRError: Error, LocalizedError, Equatable {
    case unsupportedProvider
    case handshakeTimedOut
    case closedBeforeSessionStart(code: Int, reason: String?)
    case serverRejected(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "SonioxASRClient requires SonioxASRConfig"
        case .handshakeTimedOut:
            return "Soniox WebSocket handshake timed out"
        case .closedBeforeSessionStart(let code, let reason):
            if let reason, !reason.isEmpty {
                return "Soniox WebSocket closed before session start (\(code)): \(reason)"
            }
            return "Soniox WebSocket closed before session start (\(code))"
        case .serverRejected(let code, let message):
            return "Soniox request failed (\(code)): \(message)"
        }
    }
}

actor SonioxASRClient: SpeechRecognizer {

    private let logger = Logger(
        subsystem: "com.type4me.asr",
        category: "SonioxASRClient"
    )

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var session: URLSession?
    private var sessionDelegate: SonioxWebSocketDelegate?
    private var connectionGate: SonioxConnectionGate?

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    private var accumulator = SonioxTranscriptAccumulator()
    private var lastTranscript: RecognitionTranscript = .empty
    private var audioPacketCount = 0
    private var didRequestEnd = false
    private var didReceiveFinished = false

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
        guard let sonioxConfig = config as? SonioxASRConfig else {
            throw SonioxASRError.unsupportedProvider
        }

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream

        let url = try SonioxProtocol.buildWebSocketURL()
        let gate = SonioxConnectionGate()
        let delegate = SonioxWebSocketDelegate(connectionGate: gate)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        task.resume()

        connectionGate = gate
        sessionDelegate = delegate
        self.session = session
        webSocketTask = task
        accumulator = SonioxTranscriptAccumulator()
        lastTranscript = .empty
        audioPacketCount = 0
        didRequestEnd = false
        didReceiveFinished = false

        startReceiveLoop()

        try await sendStartMessage(
            SonioxProtocol.buildStartMessage(
                config: sonioxConfig,
                options: options
            ),
            over: task,
            timeout: .seconds(5)
        )
        try await gate.waitForValidationWindow(timeout: .milliseconds(500))
        logger.info("Soniox WebSocket connected")
    }

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask else { return }
        audioPacketCount += 1
        try await task.send(.data(data))
    }

    func endAudio() async throws {
        guard let task = webSocketTask else { return }
        didRequestEnd = true
        try await task.send(.string(SonioxProtocol.finalizeMessage(trailingSilenceMs: 300)))
        try await task.send(.string(""))
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
        accumulator = SonioxTranscriptAccumulator()
        lastTranscript = .empty
        audioPacketCount = 0
        didRequestEnd = false
        didReceiveFinished = false
        logger.info("Soniox disconnected")
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = await self.webSocketTask else { break }
                    let message = try await task.receive()
                    let action = await self.handleMessage(message)
                    switch action {
                    case .none:
                        break
                    case .finished:
                        await self.markFinished()
                        await self.emitEvent(.completed)
                        return
                    case .fatal(let error):
                        await self.connectionGate?.markFailure(error)
                        await self.emitEvent(.error(error))
                        await self.emitEvent(.completed)
                        return
                    }
                } catch {
                    if Task.isCancelled {
                        break
                    }

                    let didRequestEnd = await self.didRequestEnd
                    let didReceiveFinished = await self.didReceiveFinished
                    if didRequestEnd || didReceiveFinished {
                        await self.emitEvent(.completed)
                    } else {
                        await self.connectionGate?.markFailure(error)
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

    private enum MessageAction {
        case none
        case finished
        case fatal(Error)
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) -> MessageAction {
        do {
            let data: Data
            switch message {
            case .data(let payload):
                data = payload
            case .string(let text):
                data = Data(text.utf8)
            @unknown default:
                return .none
            }

            guard let event = try SonioxProtocol.parseServerEvent(from: data) else {
                return .none
            }

            switch event {
            case .transcript(let update):
                applyTranscriptUpdate(update)
                return .none

            case .finished:
                return .finished

            case .error(let code, let message):
                return .fatal(
                    SonioxASRError.serverRejected(
                        code: code,
                        message: message
                    )
                )
            }
        } catch {
            return .fatal(error)
        }
    }

    private func applyTranscriptUpdate(_ update: SonioxTranscriptUpdate) {
        accumulator.apply(update)
        let transcript = accumulator.transcript
        guard transcript != lastTranscript else { return }
        lastTranscript = transcript
        emitEvent(.transcript(transcript))
    }

    private func markFinished() {
        didReceiveFinished = true
    }

    private func sendStartMessage(
        _ message: String,
        over task: URLSessionWebSocketTask,
        timeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await task.send(.string(message))
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                throw SonioxASRError.handshakeTimedOut
            }

            let result: Void? = try await group.next()
            group.cancelAll()
            return result ?? ()
        }
    }
}

struct SonioxTranscriptAccumulator: Sendable {

    private var confirmedText = ""
    private var partialText = ""

    mutating func apply(_ update: SonioxTranscriptUpdate) {
        if !update.finalizedText.isEmpty {
            confirmedText += update.finalizedText
        }
        partialText = update.partialText
    }

    var transcript: RecognitionTranscript {
        let authoritativeText = confirmedText + partialText
        return RecognitionTranscript(
            confirmedSegments: confirmedText.isEmpty ? [] : [confirmedText],
            partialText: partialText,
            authoritativeText: authoritativeText,
            isFinal: partialText.isEmpty
        )
    }
}

private extension SonioxASRClient {
    func emitEvent(_ event: RecognitionEvent) {
        eventContinuation?.yield(event)
    }
}

private final class SonioxWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {

    private let connectionGate: SonioxConnectionGate

    init(connectionGate: SonioxConnectionGate) {
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
                SonioxASRError.closedBeforeSessionStart(
                    code: Int(closeCode.rawValue),
                    reason: reasonText
                )
            )
        }
    }
}
