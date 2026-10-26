import Foundation
import os

enum AssemblyAIASRError: Error, LocalizedError {
    case unsupportedProvider
    case handshakeTimedOut
    case closedBeforeSessionBegan(code: Int, reason: String?)
    case unauthorized(reason: String?)
    case serverCancelled(reason: String?)
    case closed(code: Int, reason: String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return L("AssemblyAI 识别配置无效", "AssemblyAIASRClient requires AssemblyAIASRConfig")
        case .handshakeTimedOut:
            return L("AssemblyAI 流式会话启动超时", "AssemblyAI streaming session begin timed out")
        case .closedBeforeSessionBegan(let code, let reason):
            if let reason, !reason.isEmpty {
                return L("AssemblyAI 连接在会话开始前关闭（\(code)）：\(reason)", "AssemblyAI WebSocket closed before session begin (\(code)): \(reason)")
            }
            return L("AssemblyAI 连接在会话开始前关闭（\(code)）", "AssemblyAI WebSocket closed before session begin (\(code))")
        case .unauthorized(let reason):
            if let reason, !reason.isEmpty {
                return L("AssemblyAI 鉴权失败：\(reason)", "AssemblyAI unauthorized connection: \(reason)")
            }
            return L("AssemblyAI 鉴权失败", "AssemblyAI unauthorized connection")
        case .serverCancelled(let reason):
            if let reason, !reason.isEmpty {
                return L("AssemblyAI 会话被取消：\(reason)", "AssemblyAI session cancelled: \(reason)")
            }
            return L("AssemblyAI 会话被取消", "AssemblyAI session cancelled")
        case .closed(let code, let reason):
            if let reason, !reason.isEmpty {
                return L("AssemblyAI 会话已关闭（\(code)）：\(reason)", "AssemblyAI session closed (\(code)): \(reason)")
            }
            return L("AssemblyAI 会话已关闭（\(code)）", "AssemblyAI session closed (\(code))")
        }
    }
}

actor AssemblyAIASRClient: SpeechRecognizer {
    private let logger = Logger(
        subsystem: "com.type4me.asr",
        category: "AssemblyAIASRClient"
    )

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var session: URLSession?
    private var sessionDelegate: AssemblyAIWebSocketDelegate?
    private var connectionGate: AssemblyAIConnectionGate?
    private var closeTracker: AssemblyAICloseTracker?

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    private var accumulator = AssemblyAITranscriptAccumulator()
    private var lastTranscript: RecognitionTranscript = .empty
    private var audioPacketCount = 0
    private var didRequestTerminate = false

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
        guard let assemblyConfig = config as? AssemblyAIASRConfig else {
            throw AssemblyAIASRError.unsupportedProvider
        }

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream

        let url = try AssemblyAIProtocol.buildWebSocketURL(config: assemblyConfig, options: options)
        var request = URLRequest(url: url)
        request.setValue(assemblyConfig.apiKey, forHTTPHeaderField: "Authorization")

        let gate = AssemblyAIConnectionGate()
        let closeTracker = AssemblyAICloseTracker()
        let delegate = AssemblyAIWebSocketDelegate(connectionGate: gate, closeTracker: closeTracker)
        let session = URLSession(configuration: options.urlSessionConfiguration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.resume()

        self.connectionGate = gate
        self.closeTracker = closeTracker
        sessionDelegate = delegate
        self.session = session
        webSocketTask = task
        accumulator = AssemblyAITranscriptAccumulator()
        lastTranscript = .empty
        audioPacketCount = 0
        didRequestTerminate = false

        startReceiveLoop()

        try await gate.waitUntilReady(timeout: .seconds(5))
        logger.info("AssemblyAI WebSocket connected: \(url.absoluteString, privacy: .private(mask: .hash))")

        // Send keyterms via UpdateConfiguration after connection to avoid URL length limits
        if let keytermsMsg = AssemblyAIProtocol.updateConfigurationMessage(hotwords: options.hotwords) {
            try? await task.send(.string(keytermsMsg))
        }
    }

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask else { return }
        try await task.send(.data(data))
        audioPacketCount += 1
    }

    func endAudio() async throws {
        guard let task = webSocketTask else { return }
        didRequestTerminate = true
        try await task.send(.string(AssemblyAIProtocol.terminateMessage()))
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
        closeTracker = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        accumulator = AssemblyAITranscriptAccumulator()
        lastTranscript = .empty
        audioPacketCount = 0
        didRequestTerminate = false
        logger.info("AssemblyAI disconnected")
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
                    case .none: break
                    case .gateReady:
                        await self.connectionGate?.markReady()
                    case .gateFailed(let error):
                        await self.connectionGate?.markFailure(error)
                    }
                } catch {
                    if Task.isCancelled {
                        break
                    }

                    let gate = await self.connectionGate
                    let hasBegun = await gate?.hasBegun ?? false
                    let closeError = await self.closeTracker?.consumeCloseError()
                    let didRequestTerminate = await self.didRequestTerminate
                    let audioPacketCount = await self.audioPacketCount

                    if let gate, !hasBegun {
                        await gate.markFailure(closeError ?? error)
                    } else if let closeError, !didRequestTerminate {
                        await self.emitEvent(.error(closeError))
                        await self.emitEvent(.completed)
                    } else if didRequestTerminate || audioPacketCount > 0 {
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

    private enum MessageAction {
        case none
        case gateReady
        case gateFailed(Error)
    }

    /// Parse and handle a WebSocket message synchronously (no suspension points).
    /// Returns an action for the receive loop to handle asynchronously.
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

            guard let event = try AssemblyAIProtocol.parseServerEvent(from: data) else {
                return .none
            }

            switch event {
            case .begin:
                return .gateReady

            case .turn(let update):
                applyTurnUpdate(update)
                return .none

            case .termination:
                return .none

            case .speechStarted:
                return .none
            }
        } catch {
            emitEvent(.error(error))
            return .gateFailed(error)
        }
    }

    private func applyTurnUpdate(_ update: AssemblyAITurnUpdate) {
        accumulator.apply(update)
        let transcript = accumulator.transcript
        guard transcript != lastTranscript else { return }
        lastTranscript = transcript
        emitEvent(.transcript(transcript))
    }
}

struct AssemblyAITranscriptAccumulator: Sendable {

    private struct TurnState: Sendable {
        let order: Int
        var finalizedText: String
        var displayText: String
        var isCompleted: Bool
        var isFormatted: Bool
    }

    private var turns: [Int: TurnState] = [:]

    mutating func apply(_ update: AssemblyAITurnUpdate) {
        let existing = turns[update.turnOrder]

        if let existing, existing.isCompleted, !update.isFinal {
            return
        }

        if update.isFinal {
            if let existing, existing.isFormatted, !update.isFormatted {
                return
            }
            turns[update.turnOrder] = TurnState(
                order: update.turnOrder,
                finalizedText: update.displayText,
                displayText: update.displayText,
                isCompleted: true,
                isFormatted: update.isFormatted
            )
        } else {
            turns[update.turnOrder] = TurnState(
                order: update.turnOrder,
                finalizedText: update.finalizedText,
                displayText: update.displayText,
                isCompleted: false,
                isFormatted: update.isFormatted
            )
        }
    }

    var transcript: RecognitionTranscript {
        let orderedTurns = turns.values.sorted { $0.order < $1.order }

        var confirmedSegments: [String] = []
        var existingText = ""
        var activeTurn: TurnState?

        for turn in orderedTurns {
            if turn.isCompleted {
                let normalized = normalize(segment: turn.displayText, after: existingText)
                confirmedSegments.append(normalized)
                existingText += normalized
            } else {
                activeTurn = turn
            }
        }

        var partialText = ""
        if let activeTurn {
            if !activeTurn.finalizedText.isEmpty {
                let normalizedFinalized = normalize(segment: activeTurn.finalizedText, after: existingText)
                confirmedSegments.append(normalizedFinalized)
                existingText += normalizedFinalized
            }

            let rawPartial: String
            if !activeTurn.finalizedText.isEmpty,
               activeTurn.displayText.hasPrefix(activeTurn.finalizedText) {
                rawPartial = String(activeTurn.displayText.dropFirst(activeTurn.finalizedText.count))
            } else if activeTurn.displayText == activeTurn.finalizedText {
                rawPartial = ""
            } else {
                rawPartial = activeTurn.displayText
            }

            partialText = normalize(segment: rawPartial, after: existingText)
        }

        let authoritativeText = (confirmedSegments + (partialText.isEmpty ? [] : [partialText])).joined()
        return RecognitionTranscript(
            confirmedSegments: confirmedSegments,
            partialText: partialText,
            authoritativeText: authoritativeText,
            isFinal: activeTurn == nil
        )
    }

    private func normalize(segment: String, after existingText: String) -> String {
        guard !segment.isEmpty else { return "" }
        guard let last = existingText.last else { return segment }
        guard let first = segment.first else { return segment }

        if last.isWhitespace || first.isWhitespace {
            return segment
        }

        if first.isClosingPunctuation || last.isOpeningPunctuation {
            return segment
        }

        if last.isCJKUnifiedIdeograph || first.isCJKUnifiedIdeograph {
            return segment
        }

        return " " + segment
    }
}

private actor AssemblyAICloseTracker {

    private var closeError: Error?

    func storeCloseError(_ error: Error) {
        closeError = error
    }

    func consumeCloseError() -> Error? {
        let error = closeError
        closeError = nil
        return error
    }
}

private extension AssemblyAIASRClient {
    func emitEvent(_ event: RecognitionEvent) {
        eventContinuation?.yield(event)
    }
}

private final class AssemblyAIWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {

    private let connectionGate: AssemblyAIConnectionGate
    private let closeTracker: AssemblyAICloseTracker

    init(connectionGate: AssemblyAIConnectionGate, closeTracker: AssemblyAICloseTracker) {
        self.connectionGate = connectionGate
        self.closeTracker = closeTracker
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
        let mappedError = AssemblyAIProtocol.makeCloseError(
            code: Int(closeCode.rawValue),
            reason: reasonText
        )
        Task {
            await closeTracker.storeCloseError(mappedError)
            guard await !connectionGate.hasBegun else { return }
            if case AssemblyAIASRError.unauthorized = mappedError {
                await connectionGate.markFailure(mappedError)
            } else if case AssemblyAIASRError.serverCancelled = mappedError {
                await connectionGate.markFailure(mappedError)
            } else {
                await connectionGate.markFailure(
                    AssemblyAIASRError.closedBeforeSessionBegan(
                        code: Int(closeCode.rawValue),
                        reason: reasonText
                    )
                )
            }
        }
    }
}

// Character extensions (isClosingPunctuation, isCJKUnifiedIdeograph, etc.)
// are defined in AssemblyAIProtocol.swift
