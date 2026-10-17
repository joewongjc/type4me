import Foundation
import os

/// WebSocket streaming client for Tencent Cloud Realtime ASR V2.
actor TencentASRClient: SpeechRecognizer {

    private let logger = Logger(subsystem: "com.type4me.asr", category: "TencentASRClient")

    private var config: TencentASRConfig?
    private var options = ASRRequestOptions()
    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?
    private var receiveTask: Task<Void, Never>?
    private var transcriptState = TencentTranscriptState()
    private var didRequestCommit = false
    private var voiceId = ""

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events { return existing }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream
        return stream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        guard let tencentConfig = config as? TencentASRConfig else {
            throw TencentASRError.server(code: -1, message: "Invalid configuration")
        }

        self.config = tencentConfig
        self.options = options
        self.didRequestCommit = false
        self.transcriptState = TencentTranscriptState()
        self.voiceId = UUID().uuidString

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream

        var parameters: [String: String] = [
            "engine_model_type": TencentASRConfig.engineModelType,
            "voice_format": "1",
            "needvad": "1",
            "sentence_strategy": "0",
            "filter_dirty": "0",
            "filter_modal": "0",
            "convert_num_mode": "1",
            "filter_empty_result": "1",
        ]

        if let hotwordList = TencentHotwords.formatList(from: options.hotwords) {
            parameters["hotword_list"] = hotwordList
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let nonce = Int.random(in: 100000...999999999)

        let url = try TencentCloudSigner.signedWebSocketURL(
            appId: tencentConfig.appId,
            secretId: tencentConfig.secretId,
            secretKey: tencentConfig.secretKey,
            parameters: parameters,
            timestamp: timestamp,
            nonce: nonce,
            voiceId: voiceId
        )

        let urlSession = URLSession(configuration: options.urlSessionConfiguration)
        self.session = urlSession
        let ws = urlSession.webSocketTask(with: url)
        self.webSocketTask = ws
        ws.resume()

        // Wait for handshake response (timeout 5s)
        do {
            let handshakeMessage = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                group.addTask {
                    try await ws.receive()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw TencentASRError.handshakeFailed(code: -1, message: "Handshake timed out")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }

            let data: Data
            switch handshakeMessage {
            case .data(let d): data = d
            case .string(let s): data = Data(s.utf8)
            @unknown default: data = Data()
            }

            if let parsed = TencentRealtimeMessage.decode(from: data) {
                if parsed.code != 0 {
                    let errMsg = parsed.message ?? "Handshake rejected"
                    throw TencentASRError.handshakeFailed(code: parsed.code, message: errMsg)
                }
            }
        } catch {
            ws.cancel(with: .normalClosure, reason: nil)
            continuation.yield(.error(error))
            continuation.finish()
            throw error
        }

        continuation.yield(.ready)
        startReceiveLoop()
    }

    func sendAudio(_ data: Data) async throws {
        guard let ws = webSocketTask else { return }
        try await ws.send(.data(data))
    }

    func endAudio() async throws {
        didRequestCommit = true
        guard let ws = webSocketTask else { return }
        let endJson = #"{"type":"end"}"#
        try await ws.send(.string(endJson))
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                do {
                    guard let ws = await self.webSocketTask else { break }
                    let message = try await ws.receive()
                    await self.handleWebSocketMessage(message)
                } catch {
                    await self.handleReceiveFailure(error)
                    break
                }
            }
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: return
        }

        guard let parsed = TencentRealtimeMessage.decode(from: data) else { return }

        if parsed.code != 0 {
            let error = TencentASRError.server(code: parsed.code, message: parsed.message ?? "")
            eventContinuation?.yield(.error(error))
            eventContinuation?.yield(.completed)
            finishSession()
            return
        }

        for update in parsed.updates {
            transcriptState.apply(update)
        }

        if !parsed.updates.isEmpty {
            eventContinuation?.yield(.transcript(transcriptState.transcript))
        }

        if parsed.isFinal {
            transcriptState.markFinal()
            eventContinuation?.yield(.transcript(transcriptState.transcript))
            eventContinuation?.yield(.completed)
            finishSession()
        }
    }

    private func handleReceiveFailure(_ error: Error) {
        if didRequestCommit {
            // End was already requested, commit whatever text we have
            transcriptState.markFinal()
            eventContinuation?.yield(.transcript(transcriptState.transcript))
            eventContinuation?.yield(.completed)
        } else {
            eventContinuation?.yield(.error(error))
            eventContinuation?.yield(.completed)
        }
        finishSession()
    }

    private func finishSession() {
        receiveTask?.cancel()
        receiveTask = nil
        eventContinuation?.finish()
    }

    // MARK: - Credential Validation

    static func validateCredentials(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        let client = TencentASRClient()
        try await client.connect(config: config, options: options)
        let events = await client.events

        // Send 0.5s of silence, then endAudio so the server concludes the session
        let silence = Data(count: 16_000)
        try await client.sendAudio(silence)
        try await client.endAudio()

        // Wait for first error or clean completion within 2 seconds
        let serverError = await withTaskGroup(of: Error?.self) { group in
            group.addTask {
                for await event in events {
                    if case .error(let error) = event { return error }
                    if case .completed = event { return nil }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        await client.disconnect()
        if let serverError {
            throw serverError
        }
    }
}
