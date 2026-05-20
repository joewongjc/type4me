import Foundation
import os

/// ASR client that sends audio to the local Qwen3-ASR Python server for final transcription.
/// SenseVoice streaming is now handled natively via SenseVoiceASRClient (sherpa-onnx).
/// This client is only used for Qwen3 final calibration.
actor SenseVoiceWSClient: SpeechRecognizer {

    private let logger = Logger(subsystem: "com.type4me.asr", category: "SenseVoiceWS")

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    private var confirmedSegments: [String] = []

    // Qwen3 incremental speculative transcription
    private var qwen3DebounceTask: Task<Void, Never>?
    private var allAudioData: Data = Data()
    private var qwen3ConfirmedOffset: Int = 0
    private var qwen3ConfirmedSegments: [String] = []
    private var qwen3LatestText: String?
    private var qwen3HasPendingAudio: Bool = false

    private static let qwen3BytesPerSecond = 16000 * 2
    private static let qwen3MaxHTTPAudioSeconds = 30 * 60
    private static let qwen3MaxHTTPAudioBytes = qwen3MaxHTTPAudioSeconds * qwen3BytesPerSecond
    private static let qwen3SpeculativeEnabledKey = "tf_qwen3SpeculativeEnabled"
    private static let qwen3SpeculativeMinAudioBytes = 5 * qwen3BytesPerSecond
    private static let qwen3SpeculativeMaxAudioBytes = 15 * qwen3BytesPerSecond
    private static let qwen3SpeculativeDebounceMs = 8000
    private static let qwen3SpeculativeTimeout: TimeInterval = 15

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events { return existing }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream
        return stream
    }

    // MARK: - Connect

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        // Fresh event stream
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream
        confirmedSegments = []
        resetQwen3State()

        if SenseVoiceServerManager.currentQwen3Port != nil {
            // Qwen3 available, wait for health
            let mgr = SenseVoiceServerManager.shared
            var healthy = false
            for _ in 0..<30 {
                if await mgr.isHealthy() { healthy = true; break }
                try await Task.sleep(for: .seconds(1))
            }
            guard healthy else {
                throw SenseVoiceWSError.serverNotHealthy
            }
            eventContinuation?.yield(.ready)
            logger.info("Qwen3 ASR client ready (port \(SenseVoiceServerManager.currentQwen3Port!))")
        } else {
            // Qwen3 not started, try to start
            let q3Enabled = UserDefaults.standard.object(forKey: "tf_qwen3FinalEnabled") as? Bool ?? true
            if !q3Enabled {
                throw SenseVoiceWSError.allModelsDisabled
            }
            try await SenseVoiceServerManager.shared.start()
            guard SenseVoiceServerManager.currentQwen3Port != nil else {
                throw SenseVoiceWSError.serverNotRunning
            }
            // Server started, wait for health (non-recursive)
            let mgr = SenseVoiceServerManager.shared
            var healthy = false
            for _ in 0..<30 {
                if await mgr.isHealthy() { healthy = true; break }
                try await Task.sleep(for: .seconds(1))
            }
            guard healthy else {
                throw SenseVoiceWSError.serverNotHealthy
            }
            eventContinuation?.yield(.ready)
            logger.info("Qwen3 ASR client ready after server start (port \(SenseVoiceServerManager.currentQwen3Port!))")
        }
    }

    // MARK: - Send Audio

    func sendAudio(_ data: Data) async throws {
        // Accumulate audio for Qwen3 final
        allAudioData.append(data)
        qwen3HasPendingAudio = true
        scheduleSpeculativeQwen3()
    }

    // MARK: - End Audio

    func endAudio() async throws {
        qwen3DebounceTask?.cancel()

        let port = SenseVoiceServerManager.currentQwen3Port

        if let port, allAudioData.count > 3200 {
            guard allAudioData.count <= Self.qwen3MaxHTTPAudioBytes else {
                DebugFileLogger.log("Qwen3 final: skipping oversized request \(allAudioData.count) bytes")
                eventContinuation?.yield(.completed)
                resetQwen3State()
                return
            }

            DebugFileLogger.log("Qwen3 full final: sending \(allAudioData.count) bytes")
            let finalText = await qwen3Transcribe(audio: allAudioData, port: port, timeout: 30) ?? ""
            DebugFileLogger.log("Qwen3 full final: \(finalText.count) chars")

            if !finalText.isEmpty {
                confirmedSegments = [finalText]
                let transcript = RecognitionTranscript(
                    confirmedSegments: confirmedSegments,
                    partialText: "",
                    authoritativeText: finalText,
                    isFinal: true
                )
                eventContinuation?.yield(.transcript(transcript))
            } else {
                DebugFileLogger.log("Qwen3 final failed, empty result")
            }
            eventContinuation?.yield(.completed)
        } else {
            // No Qwen3 port or audio too short
            DebugFileLogger.log("endAudio: no Qwen3 port or audio too short")
            eventContinuation?.yield(.completed)
        }

        resetQwen3State()
    }

    /// POST audio to Qwen3 /transcribe and return text, or nil on failure.
    private func qwen3Transcribe(audio: Data, port: Int, timeout: TimeInterval) async -> String? {
        guard audio.count <= Self.qwen3MaxHTTPAudioBytes else {
            DebugFileLogger.log("Qwen3 transcribe: refusing oversized request \(audio.count) bytes")
            return nil
        }

        let url = URL(string: "http://127.0.0.1:\(port)/transcribe")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = audio
        request.timeoutInterval = timeout
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Qwen3 Speculative

    private func scheduleSpeculativeQwen3() {
        let speculativeEnabled = UserDefaults.standard.object(forKey: Self.qwen3SpeculativeEnabledKey) as? Bool ?? false
        guard speculativeEnabled else { return }

        qwen3DebounceTask?.cancel()
        qwen3DebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.qwen3SpeculativeDebounceMs))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard await self.qwen3HasPendingAudio else { return }
            guard let port = SenseVoiceServerManager.currentQwen3Port else { return }

            let deltaAudio = await self.allAudioData.suffix(from: self.qwen3ConfirmedOffset)
            guard deltaAudio.count >= Self.qwen3SpeculativeMinAudioBytes else { return }
            guard deltaAudio.count <= Self.qwen3SpeculativeMaxAudioBytes else {
                DebugFileLogger.log("Qwen3 speculative: skipping oversized window \(deltaAudio.count) bytes")
                return
            }

            // Snapshot the offset before the HTTP round-trip so audio arriving
            // during the request doesn't get silently marked as processed.
            let offsetSnapshot = await self.allAudioData.count

            let url = URL(string: "http://127.0.0.1:\(port)/transcribe")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(deltaAudio)
            request.timeoutInterval = Self.qwen3SpeculativeTimeout

            DebugFileLogger.log("Qwen3 speculative: sending \(deltaAudio.count) bytes (offset \(await self.qwen3ConfirmedOffset))")

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = json["text"] as? String, !text.isEmpty {
                    await self.confirmQwen3Segment(text, offset: offsetSnapshot)
                }
            } catch {
                DebugFileLogger.log("Qwen3 speculative: failed \(error)")
            }
        }
    }

    private func confirmQwen3Segment(_ text: String, offset: Int) {
        qwen3ConfirmedSegments.append(text)
        qwen3ConfirmedOffset = offset
        qwen3LatestText = nil
        qwen3HasPendingAudio = false
        DebugFileLogger.log("Qwen3 speculative: confirmed segment \(qwen3ConfirmedSegments.count): \(text.count) chars")
    }

    private func resetQwen3State() {
        allAudioData = Data()
        qwen3ConfirmedOffset = 0
        qwen3ConfirmedSegments = []
        qwen3LatestText = nil
        qwen3HasPendingAudio = false
    }

    // MARK: - Disconnect

    func disconnect() async {
        qwen3DebounceTask?.cancel()
        qwen3DebounceTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        logger.info("Qwen3 ASR client disconnected")
    }
}

// MARK: - Errors

enum SenseVoiceWSError: Error, LocalizedError {
    case serverNotRunning
    case serverNotHealthy
    case allModelsDisabled

    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return L("识别服务未启动", "ASR server not running")
        case .serverNotHealthy:
            return L("识别服务未就绪", "ASR server not ready")
        case .allModelsDisabled:
            return L("请先在设置中启动识别模型", "Please start an ASR model in Settings")
        }
    }
}
