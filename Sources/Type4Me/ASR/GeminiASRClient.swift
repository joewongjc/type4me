import Foundation
import os

enum GeminiASRError: Error, LocalizedError, Equatable {
    case unsupportedProvider
    case invalidConfig
    case invalidEndpoint
    case handshakeTimedOut
    case setupTimedOut
    case setupRejected(String?)
    case emptyAudio
    case closedBeforeSetup(code: Int, reason: String?)
    case closed(code: Int, reason: String?)
    case quotaExceeded(String?)
    case sessionLimitReached
    case invalidResponse
    case serverError(code: Int?, message: String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return L("Gemini 识别配置无效", "GeminiASRClient requires GeminiASRConfig")
        case .invalidConfig:
            return L("Gemini 识别配置无效", "Gemini ASR configuration is invalid")
        case .invalidEndpoint:
            return L("Gemini WebSocket 地址无效", "Invalid Gemini WebSocket URL")
        case .handshakeTimedOut:
            return L("Gemini 握手超时", "Gemini WebSocket handshake timed out")
        case .setupTimedOut:
            return L("Gemini 初始化超时", "Gemini Transcribe setup timed out")
        case .setupRejected(let msg):
            if let msg, !msg.isEmpty {
                return L("Gemini 初始化失败：\(msg)", "Gemini Transcribe setup rejected: \(msg)")
            }
            return L("Gemini 初始化失败", "Gemini Transcribe setup rejected")
        case .emptyAudio:
            return L("没有录到有效音频", "No valid audio recorded")
        case .closedBeforeSetup(let code, let reason):
            if let reason, !reason.isEmpty {
                return L("Gemini 连接在初始化完成前关闭（\(code)）：\(reason)", "Gemini WebSocket closed before setup (\(code)): \(reason)")
            }
            return L("Gemini 连接在初始化完成前关闭（\(code)）", "Gemini WebSocket closed before setup (\(code))")
        case .closed(let code, let reason):
            if let reason, !reason.isEmpty {
                return L("Gemini 连接意外关闭（\(code)）：\(reason)", "Gemini WebSocket closed unexpectedly (\(code)): \(reason)")
            }
            return L("Gemini 连接意外关闭（\(code)）", "Gemini WebSocket closed unexpectedly (\(code))")
        case .quotaExceeded(let msg):
            if let msg, !msg.isEmpty {
                return L("当前项目达到 Gemini API 配额限制（\(msg)）", "Gemini API quota exceeded: \(msg)")
            }
            return L("当前项目达到 Gemini API 配额限制，请稍后重试或检查额度", "Gemini API quota exceeded or rate limited. Please try again later or check your quota.")
        case .sessionLimitReached:
            return L("Gemini 单次实时识别最长约 10 分钟，请缩短录音", "Gemini live transcription session limit reached (~10 min). Please keep recordings shorter.")
        case .invalidResponse:
            return L("Gemini 返回了无法解析的识别结果", "Gemini returned an invalid response")
        case .serverError(let code, let msg):
            let desc = msg ?? L("未知错误", "Unknown error")
            if let code {
                return L("Gemini 服务端错误（\(code)）：\(desc)", "Gemini server error (\(code)): \(desc)")
            }
            return L("Gemini 服务端错误：\(desc)", "Gemini server error: \(desc)")
        }
    }

    /// Maps a WebSocket close frame to an error, or `nil` when the close is a
    /// benign end-of-stream. Gemini Live surfaces most failures (quota, session
    /// limit, internal errors) as close frames rather than JSON error payloads,
    /// so this is the primary failure channel once setup has completed.
    static func unexpectedClose(
        code: URLSessionWebSocketTask.CloseCode,
        reason: String?
    ) -> GeminiASRError? {
        switch code {
        case .normalClosure, .goingAway, .noStatusReceived:
            return nil
        default:
            if isSessionLimitReason(reason) {
                return .sessionLimitReached
            }
            return .closed(code: Int(code.rawValue), reason: reason)
        }
    }

    private static func isSessionLimitReason(_ reason: String?) -> Bool {
        guard let reason, !reason.isEmpty else { return false }
        let lowered = reason.lowercased()
        let sessionMarkers = ["session", "duration", "connection"]
        let limitMarkers = ["limit", "exceed", "too long", "maximum", "max "]
        return sessionMarkers.contains { lowered.contains($0) }
            && limitMarkers.contains { lowered.contains($0) }
    }
}

actor GeminiASRClient: SpeechRecognizer {

    private let logger = Logger(subsystem: "com.type4me.asr", category: "GeminiASRClient")

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sessionTimerTask: Task<Void, Never>?
    private var session: URLSession?
    private var sessionDelegate: GeminiWebSocketDelegate?
    private var connectionGate: GeminiConnectionGate?
    private var closeTracker: GeminiCloseTracker?

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    private var confirmedSegments: [String] = []
    private var lastTranscript: RecognitionTranscript = .empty
    private var residualAudio = Data()
    private var didStartActivity = false
    private var didEndAudio = false
    private var didEmitFinal = false
    private var audioPayloadCount = 0
    private var connectDate: Date?
    private var sessionHotwords: [String] = []

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events { return existing }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream
        return stream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions = ASRRequestOptions()) async throws {
        guard let geminiConfig = config as? GeminiASRConfig else {
            throw GeminiASRError.unsupportedProvider
        }

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream

        let url = try GeminiTranscribeProtocol.buildWebSocketURL(config: geminiConfig, options: options)
        logger.info("Connecting Gemini WebSocket: \(GeminiTranscribeProtocol.redactedURLString(for: url), privacy: .public)")

        let request = URLRequest(url: url)
        let gate = GeminiConnectionGate()
        let tracker = GeminiCloseTracker()
        let delegate = GeminiWebSocketDelegate(gate: gate, closeTracker: tracker)
        let session = URLSession(configuration: options.urlSessionConfiguration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.resume()

        self.connectionGate = gate
        self.closeTracker = tracker
        self.sessionDelegate = delegate
        self.session = session
        self.webSocketTask = task
        self.confirmedSegments = []
        self.lastTranscript = .empty
        self.residualAudio.removeAll()
        self.didStartActivity = false
        self.didEndAudio = false
        self.didEmitFinal = false
        self.audioPayloadCount = 0
        self.connectDate = Date()
        self.sessionHotwords = options.hotwords

        try await gate.waitUntilOpen(timeout: .seconds(5))
        startReceiveLoop()

        let setupMessage = try GeminiTranscribeProtocol.setupMessage(config: geminiConfig, options: options)
        try await task.send(.string(setupMessage))

        try await gate.waitUntilSetupComplete(timeout: .seconds(5))
        logger.info("Gemini WebSocket setup complete and ready")

        startSessionLimitMonitor()
        emitEvent(.ready)
    }

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask, !data.isEmpty else { return }

        residualAudio.append(data)

        if !didStartActivity && !residualAudio.isEmpty {
            try await task.send(.string(GeminiTranscribeProtocol.activityStartMessage()))
            didStartActivity = true
        }

        let payloads = GeminiTranscribeProtocol.sliceAudioPayloads(from: &residualAudio)
        var batchCount = 0
        for payload in payloads {
            try await task.send(.string(GeminiTranscribeProtocol.audioChunkMessage(payload)))
            audioPayloadCount += 1
            batchCount += 1
            if batchCount > 2 {
                await Task.yield()
            }
        }
    }

    func endAudio() async throws {
        guard let task = webSocketTask else { return }

        if let flushed = GeminiTranscribeProtocol.flushResidualAudio(from: &residualAudio) {
            if !didStartActivity {
                try await task.send(.string(GeminiTranscribeProtocol.activityStartMessage()))
                didStartActivity = true
            }
            try await task.send(.string(GeminiTranscribeProtocol.audioChunkMessage(flushed)))
            audioPayloadCount += 1
        }

        // If no audio was sent during this session, silently return without throwing (see §16.1)
        guard didStartActivity else {
            return
        }

        didEndAudio = true
        try await task.send(.string(GeminiTranscribeProtocol.activityEndMessage()))
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        sessionTimerTask?.cancel()
        sessionTimerTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        sessionDelegate = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        connectionGate = nil
        closeTracker = nil
        confirmedSegments = []
        lastTranscript = .empty
        residualAudio.removeAll()
        didStartActivity = false
        didEndAudio = false
        didEmitFinal = false
        audioPayloadCount = 0
        connectDate = nil
        sessionHotwords = []
        logger.info("Gemini disconnected")
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
                    logger.info("Gemini receive loop ended: \(String(describing: error), privacy: .public)")
                    if let gate = await self.connectionGate, await !gate.isReady {
                        await gate.markFailure(error)
                    }

                    // Any termination that did not deliver a final transcript is a
                    // failure, even when it arrives as a WebSocket close frame after
                    // setup completed. Reporting `.completed` alone here would make
                    // RecognitionSession treat a truncated partial as the finished
                    // result: no recovery, no batch fallback, no user-visible error.
                    let didEmitFinal = await self.didEmitFinal
                    var closeError = await self.closeTracker?.consumeCloseError()
                    if closeError == nil && !didEmitFinal {
                        // The URLSession close delegate races with receive()
                        // throwing. Wait briefly so the specific close reason
                        // (quota, session limit) wins over the raw transport
                        // error. Bounded and off the stopRecording() budget.
                        try? await Task.sleep(for: .milliseconds(50))
                        closeError = await self.closeTracker?.consumeCloseError()
                    }

                    if let closeError {
                        logger.error("Gemini stream closed abnormally: \(String(describing: closeError), privacy: .public)")
                        await self.emitEvent(.error(closeError))
                    } else if !didEmitFinal {
                        await self.emitEvent(.error(error))
                    }
                    await self.emitEvent(.completed)
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
            case .string(let s): data = Data(s.utf8)
            @unknown default: return
            }

            if let update = try GeminiTranscribeProtocol.makeTranscriptUpdate(
                from: data,
                confirmedSegments: confirmedSegments,
                didEndAudio: didEndAudio,
                hotwords: sessionHotwords
            ) {
                if update.isSetupComplete {
                    Task { await connectionGate?.markSetupComplete() }
                    return
                }

                // Dedup before mutating state: applying `confirmedSegments`
                // first would let an identical repeated final append twice
                // while the transcript comparison below still saw a change.
                // An empty sanitized final may be identical to the initial
                // transcript. It still has to pass through so stopRecording()
                // receives the completion signal instead of waiting for a
                // timeout.
                guard update.transcript != lastTranscript
                    || (update.transcript.isFinal && didEndAudio)
                else { return }
                confirmedSegments = update.confirmedSegments
                lastTranscript = update.transcript

                logger.info("Gemini transcript update confirmed=\(update.transcript.confirmedSegments.count) partial=\(update.transcript.partialText.count) final=\(update.transcript.isFinal)")
                emitEvent(.transcript(update.transcript))

                if update.transcript.isFinal && didEndAudio {
                    didEmitFinal = true
                    emitEvent(.completed)
                    eventContinuation?.finish()
                }
            }
        } catch {
            logger.error("Gemini decode or server error: \(String(describing: error), privacy: .public)")
            if let gate = connectionGate {
                Task { await gate.markFailure(error) }
            }
            emitEvent(.error(error))
        }
    }

    private func startSessionLimitMonitor() {
        sessionTimerTask?.cancel()
        sessionTimerTask = Task { [weak self] in
            // 9 minutes and 30 seconds = 570 seconds
            try? await Task.sleep(for: .seconds(570))
            guard !Task.isCancelled, let self else { return }
            logger.warning("Gemini live transcription session approaching 10-minute limit")
        }
    }

    private func emitEvent(_ event: RecognitionEvent) {
        eventContinuation?.yield(event)
    }
}
