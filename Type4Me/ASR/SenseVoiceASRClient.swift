#if HAS_SHERPA_ONNX

import Foundation
import os

import SherpaOnnxLib

enum SherpaASRError: Error, LocalizedError {
    case unsupportedConfig
    case modelNotFound(String)
    case modelFileMissing(file: String, dir: String)
    case recognizerInitFailed
    case vadInitFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedConfig:
            return "SenseVoiceASRClient requires SherpaASRConfig"
        case .modelNotFound(let path):
            return L("模型未找到: \(path)", "Model not found: \(path)")
        case .modelFileMissing(let file, let dir):
            return L("模型文件缺失: \(file) (在 \(dir))", "Model file missing: \(file) (in \(dir))")
        case .recognizerInitFailed:
            return L("识别引擎初始化失败，请重新下载模型", "Recognizer init failed, please re-download models")
        case .vadInitFailed:
            return L("语音检测引擎初始化失败，请重新下载模型", "VAD init failed, please re-download models")
        }
    }
}

/// Local speech recognizer using SenseVoice (offline) + Silero VAD.
///
/// Simulates streaming by running offline recognition periodically on
/// accumulated audio while VAD tracks speech boundaries.
actor SenseVoiceASRClient: SpeechRecognizer {

    private let logger = Logger(
        subsystem: "com.type4me.asr",
        category: "SenseVoiceASR"
    )

    // MARK: - State

    private var recognizer: SherpaOnnxOfflineRecognizer?
    private var vad: SherpaOnnxVoiceActivityDetectorWrapper?
    private var punctProcessor: SherpaPunctuationProcessor?

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    /// Accumulated confirmed segments (after VAD detects speech end).
    private var confirmedSegments: [String] = []
    /// Current partial text (during ongoing speech).
    private var currentPartialText: String = ""
    /// Total audio samples fed so far.
    private var totalSamplesFed: Int = 0

    /// Samples to skip at start to avoid start-sound interference.
    /// 200ms delay + 150ms tone + 50ms margin = 400ms x 16 samples/ms = 6400 samples.
    private let skipInitialSamples = 6400
    private var samplesSkipped: Int = 0

    /// Audio buffer for the current speech segment (used for partial recognition).
    private var speechBuffer: [Float] = []

    /// Accumulated raw PCM audio for Qwen3 final calibration.
    private var allAudioData = Data()

    /// Counter for samples fed to VAD since last partial recognition.
    private var samplesSinceLastPartial: Int = 0

    /// Samples between partial recognition runs (~200ms at 16kHz).
    private let partialRecognitionInterval = 3200

    /// Whether a partial recognition is currently running in the background.
    private var partialRecognitionInFlight = false
    /// Set to true in endAudio() to reject late-arriving partial results.
    private var finalized = false
    /// Number of confirmed segment decodes currently in flight.
    private var pendingConfirmations = 0

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events {
            return existing
        }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream
        return stream
    }

    // MARK: - Model Validation

    /// Validate all required model files exist and have non-zero size.
    private static func validateModelFiles(senseVoiceDir: String, vadDir: String) throws {
        let svFiles = ["model.int8.onnx", "tokens.txt"]
        for file in svFiles {
            let path = (senseVoiceDir as NSString).appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: path) else {
                throw SherpaASRError.modelFileMissing(file: file, dir: senseVoiceDir)
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = attrs?[.size] as? UInt64 ?? 0
            if size == 0 {
                throw SherpaASRError.modelFileMissing(file: "\(file) (0 bytes)", dir: senseVoiceDir)
            }
        }

        let vadFile = "silero_vad.onnx"
        let vadPath = (vadDir as NSString).appendingPathComponent(vadFile)
        guard FileManager.default.fileExists(atPath: vadPath) else {
            throw SherpaASRError.modelFileMissing(file: vadFile, dir: vadDir)
        }
        let vadAttrs = try? FileManager.default.attributesOfItem(atPath: vadPath)
        if (vadAttrs?[.size] as? UInt64 ?? 0) == 0 {
            throw SherpaASRError.modelFileMissing(file: "\(vadFile) (0 bytes)", dir: vadDir)
        }
    }

    // MARK: - Cached models (avoid reloading each session)

    private static let cacheLock = NSLock()
    private static var _cachedRecognizer: SherpaOnnxOfflineRecognizer?
    private static var _cachedVAD: SherpaOnnxVoiceActivityDetectorWrapper?
    private static var _cachedPunctProcessor: SherpaPunctuationProcessor?
    private static var _cachedSenseVoiceModelDir: String?
    private static var _cachedVadModelDir: String?

    private static var cachedRecognizer: SherpaOnnxOfflineRecognizer? {
        get { cacheLock.withLock { _cachedRecognizer } }
        set { cacheLock.withLock { _cachedRecognizer = newValue } }
    }
    private static var cachedVAD: SherpaOnnxVoiceActivityDetectorWrapper? {
        get { cacheLock.withLock { _cachedVAD } }
        set { cacheLock.withLock { _cachedVAD = newValue } }
    }
    private static var cachedPunctProcessor: SherpaPunctuationProcessor? {
        get { cacheLock.withLock { _cachedPunctProcessor } }
        set { cacheLock.withLock { _cachedPunctProcessor = newValue } }
    }
    private static var cachedSenseVoiceModelDir: String? {
        get { cacheLock.withLock { _cachedSenseVoiceModelDir } }
        set { cacheLock.withLock { _cachedSenseVoiceModelDir = newValue } }
    }
    private static var cachedVadModelDir: String? {
        get { cacheLock.withLock { _cachedVadModelDir } }
        set { cacheLock.withLock { _cachedVadModelDir = newValue } }
    }

    /// Release all cached models to free memory (e.g. when switching away from local ASR).
    static func releaseCachedModels() {
        cacheLock.withLock {
            _cachedRecognizer = nil
            _cachedVAD = nil
            _cachedPunctProcessor = nil
            _cachedSenseVoiceModelDir = nil
            _cachedVadModelDir = nil
        }
        NSLog("[SenseVoiceASR] Cached models released")
    }

    /// Pre-load models at app startup for instant first recording.
    static func preloadModels(config: SherpaASRConfig) {
        let svDir = config.senseVoiceModelDir
        let vadDir = config.vadModelDir

        // Validate files before attempting init
        do {
            try validateModelFiles(senseVoiceDir: svDir, vadDir: vadDir)
        } catch {
            NSLog("[SenseVoiceASR] Model validation failed: %@", error.localizedDescription)
            return
        }

        if cachedRecognizer == nil || cachedSenseVoiceModelDir != svDir {
            NSLog("[SenseVoiceASR] Preloading SenseVoice model from %@", svDir)
            var recConfig = buildRecognizerConfig(modelDir: svDir)
            let rec = SherpaOnnxOfflineRecognizer(config: &recConfig)
            // Smoke test: decode 100ms of silence to verify model actually works
            let silence = [Float](repeating: 0.0, count: 1600)
            let test = rec.decode(samples: silence, sampleRate: 16_000)
            if test.text.isEmpty || test.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cachedRecognizer = rec
                cachedSenseVoiceModelDir = svDir
                NSLog("[SenseVoiceASR] SenseVoice model preloaded (smoke test passed)")
            } else {
                NSLog("[SenseVoiceASR] ⚠️ SenseVoice smoke test produced unexpected output for silence: %@", test.text)
                // Still cache it — non-empty output for silence is unusual but not necessarily fatal
                cachedRecognizer = rec
                cachedSenseVoiceModelDir = svDir
            }
        }

        if cachedVAD == nil || cachedVadModelDir != vadDir {
            NSLog("[SenseVoiceASR] Preloading Silero VAD from %@", vadDir)
            var vadConfig = buildVADConfig(modelDir: vadDir)
            cachedVAD = SherpaOnnxVoiceActivityDetectorWrapper(
                config: &vadConfig, buffer_size_in_seconds: 60
            )
            cachedVadModelDir = vadDir
            NSLog("[SenseVoiceASR] Silero VAD preloaded")
        }

        // Preload punctuation if available
        if cachedPunctProcessor == nil,
           ModelManager.shared.isModelAvailable(ModelManager.AuxModelType.punctuation) {
            cachedPunctProcessor = SherpaPunctuationProcessor(modelDir: config.punctModelDir)
            NSLog("[SenseVoiceASR] Punctuation model preloaded")
        }
    }

    // MARK: - Connect

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        guard let sherpaConfig = config as? SherpaASRConfig else {
            throw SherpaASRError.unsupportedConfig
        }

        // Ensure fresh event stream
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream

        // Reset per-session state
        confirmedSegments = []
        currentPartialText = ""
        totalSamplesFed = 0
        samplesSkipped = 0
        speechBuffer = []
        allAudioData = Data()
        samplesSinceLastPartial = 0
        partialRecognitionInFlight = false
        finalized = false
        pendingConfirmations = 0

        let svModelDir = sherpaConfig.senseVoiceModelDir
        let vadModelDir = sherpaConfig.vadModelDir

        // Validate all model files before attempting init
        try Self.validateModelFiles(senseVoiceDir: svModelDir, vadDir: vadModelDir)

        // --- SenseVoice offline recognizer ---
        if let cached = Self.cachedRecognizer, Self.cachedSenseVoiceModelDir == svModelDir {
            recognizer = cached
            logger.info("Reusing cached SenseVoice recognizer")
        } else {
            var recConfig = Self.buildRecognizerConfig(modelDir: svModelDir)
            let rec = SherpaOnnxOfflineRecognizer(config: &recConfig)
            recognizer = rec
            Self.cachedRecognizer = rec
            Self.cachedSenseVoiceModelDir = svModelDir
            logger.info("Created new SenseVoice recognizer from \(svModelDir)")
        }

        // --- Silero VAD ---
        if let cached = Self.cachedVAD, Self.cachedVadModelDir == vadModelDir {
            cached.reset()
            vad = cached
            logger.info("Reusing cached VAD")
        } else {
            var vadConfig = Self.buildVADConfig(modelDir: vadModelDir)
            let v = SherpaOnnxVoiceActivityDetectorWrapper(
                config: &vadConfig, buffer_size_in_seconds: 60
            )
            vad = v
            Self.cachedVAD = v
            Self.cachedVadModelDir = vadModelDir
            logger.info("Created new VAD from \(vadModelDir)")
        }

        // --- Punctuation ---
        if let cached = Self.cachedPunctProcessor {
            punctProcessor = cached
        } else if ModelManager.shared.isModelAvailable(ModelManager.AuxModelType.punctuation) {
            punctProcessor = SherpaPunctuationProcessor(modelDir: sherpaConfig.punctModelDir)
            Self.cachedPunctProcessor = punctProcessor
        }

        eventContinuation?.yield(.ready)
        logger.info("SenseVoiceASR connected (local)")
    }

    // MARK: - Build Configs

    private static func buildRecognizerConfig(modelDir: String) -> SherpaOnnxOfflineRecognizerConfig {
        let modelPath = (modelDir as NSString).appendingPathComponent("model.int8.onnx")
        let tokensPath = (modelDir as NSString).appendingPathComponent("tokens.txt")

        let senseVoiceConfig = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: modelPath,
            language: "auto",
            useInverseTextNormalization: true
        )

        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokensPath,
            numThreads: 2,
            provider: "cpu",
            debug: 0,
            modelType: "sense_voice",
            senseVoice: senseVoiceConfig
        )

        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        return sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            decodingMethod: "greedy_search"
        )
    }

    private static func buildVADConfig(modelDir: String) -> SherpaOnnxVadModelConfig {
        let vadModelPath = (modelDir as NSString).appendingPathComponent("silero_vad.onnx")

        let sileroConfig = sherpaOnnxSileroVadModelConfig(
            model: vadModelPath,
            threshold: 0.5,
            minSilenceDuration: 0.15,
            minSpeechDuration: 0.25,
            windowSize: 512,
            maxSpeechDuration: 30.0
        )

        return sherpaOnnxVadModelConfig(
            sileroVad: sileroConfig,
            sampleRate: 16000,
            numThreads: 1
        )
    }

    // MARK: - Send Audio

    func sendAudio(_ data: Data) async throws {
        guard let vad, let recognizer else {
            logger.error("sendAudio called but recognizer/VAD is nil — engine not initialized")
            throw SherpaASRError.recognizerInitFailed
        }

        // Accumulate raw PCM for Qwen3 calibration
        allAudioData.append(data)

        var floatSamples = Self.int16ToFloat32(data)
        totalSamplesFed += floatSamples.count

        // Skip initial audio that overlaps with the start sound
        if samplesSkipped < skipInitialSamples {
            let remaining = skipInitialSamples - samplesSkipped
            if floatSamples.count <= remaining {
                samplesSkipped += floatSamples.count
                return
            }
            floatSamples = Array(floatSamples.dropFirst(remaining))
            samplesSkipped = skipInitialSamples
        }

        // Feed audio to VAD in chunks of 512 (Silero window size)
        var offset = 0
        while offset + 512 <= floatSamples.count {
            let chunk = Array(floatSamples[offset..<(offset + 512)])
            vad.acceptWaveform(samples: chunk)
            offset += 512

            // Also accumulate in speech buffer when speech is detected
            if vad.isSpeechDetected() {
                speechBuffer.append(contentsOf: chunk)
                samplesSinceLastPartial += 512
            }

            // Process completed speech segments from VAD (async to avoid blocking audio pipeline)
            while !vad.isEmpty() {
                let segment = vad.front()
                vad.pop()

                let samples = segment.samples
                guard !samples.isEmpty else { continue }

                // Clear speech buffer since this segment is finalized
                speechBuffer = []
                samplesSinceLastPartial = 0
                currentPartialText = ""

                pendingConfirmations += 1
                let rec = recognizer
                let punct = punctProcessor
                Task { [weak self] in
                    let result = rec.decode(samples: samples, sampleRate: 16_000)
                    let segmentText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    await self?.confirmSegment(segmentText, punctProcessor: punct)
                }
            }

            // Schedule partial recognition on accumulated buffer periodically.
            // Runs in a detached task so it doesn't block the audio pipeline.
            if vad.isSpeechDetected()
                && samplesSinceLastPartial >= partialRecognitionInterval
                && !partialRecognitionInFlight
                && !speechBuffer.isEmpty
            {
                samplesSinceLastPartial = 0
                partialRecognitionInFlight = true
                let bufferSnapshot = speechBuffer
                let rec = recognizer
                Task { [weak self] in
                    let result = rec.decode(samples: bufferSnapshot, sampleRate: 16_000)
                    let partialText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    await self?.updatePartial(partialText)
                }
            }
        }

        // If speech just ended (no longer detected) and buffer has leftover, clear it.
        // The VAD will pop the segment when it's ready.
        if !vad.isSpeechDetected() && !speechBuffer.isEmpty {
            // VAD hasn't popped yet; the segment is still being finalized.
            // Keep the buffer until VAD pops it.
        }
    }

    // MARK: - End Audio

    func endAudio() async throws {
        guard let vad, let recognizer else {
            DebugFileLogger.log("SenseVoice endAudio: guard failed, vad=\(vad != nil) recognizer=\(recognizer != nil)")
            return
        }

        // Guard: skip processing if audio is too short (< 0.3s).
        // Prevents noise/silence from producing phantom transcriptions.
        let minBytes = Int(0.3 * 16000) * 2  // 0.3s at 16kHz, 16-bit PCM
        if allAudioData.count < minBytes {
            DebugFileLogger.log("SenseVoice endAudio: audio too short (\(allAudioData.count) bytes < \(minBytes)), skipping")
            allAudioData = Data()
            confirmedSegments = []
            speechBuffer = []
            currentPartialText = ""
            emitTranscript(isFinal: true)
            eventContinuation?.yield(.completed)
            return
        }

        DebugFileLogger.log("SenseVoice endAudio: start, confirmed=\(confirmedSegments.count) buffer=\(speechBuffer.count) pending=\(pendingConfirmations)")

        // Wait for any in-flight segment confirmations to land (with timeout)
        let waitStart = ContinuousClock.now
        let maxWait = Duration.seconds(3)
        while pendingConfirmations > 0 {
            if ContinuousClock.now - waitStart > maxWait {
                logger.warning("pendingConfirmations timeout (\(self.pendingConfirmations) still pending), proceeding")
                DebugFileLogger.log("SenseVoice endAudio: pendingConfirmations timeout, \(pendingConfirmations) stuck")
                pendingConfirmations = 0
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        finalized = true  // reject any late-arriving partial results
        // Flush VAD to get any remaining speech
        vad.flush()

        // Process any remaining segments from VAD flush
        var flushedSegments = false
        while !vad.isEmpty() {
            let segment = vad.front()
            vad.pop()
            flushedSegments = true

            let samples = segment.samples
            guard !samples.isEmpty else { continue }

            let result = recognizer.decode(samples: samples, sampleRate: 16_000)
            let segmentText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if !segmentText.isEmpty {
                let punctuated = punctProcessor?.addPunctuation(to: segmentText) ?? segmentText
                confirmedSegments.append(punctuated)
                logger.info("Final segment confirmed: \(punctuated)")
            }
        }

        // Only use speechBuffer as fallback if VAD flush produced nothing.
        // When VAD flushed segments, those segments already contain the speech
        // audio, so decoding speechBuffer again would produce duplicate text.
        if !flushedSegments && !speechBuffer.isEmpty {
            let result = recognizer.decode(samples: speechBuffer, sampleRate: 16_000)
            let remainingText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if !remainingText.isEmpty {
                let punctuated = punctProcessor?.addPunctuation(to: remainingText) ?? remainingText
                confirmedSegments.append(punctuated)
                logger.info("Remaining buffer confirmed: \(punctuated)")
            }
        }
        speechBuffer = []
        currentPartialText = ""

        // Qwen3 calibration: if server is running, send full audio for more accurate result
        let qwen3Enabled = UserDefaults.standard.object(forKey: "tf_qwen3FinalEnabled") as? Bool ?? true
        if qwen3Enabled, let port = SenseVoiceServerManager.currentQwen3Port, allAudioData.count > 3200 {
            DebugFileLogger.log("SenseVoice endAudio: Qwen3 calibration starting (\(allAudioData.count) bytes)")
            if let calibratedText = await qwen3Calibrate(audio: allAudioData, port: port) {
                confirmedSegments = [calibratedText]
                DebugFileLogger.log("SenseVoice endAudio: Qwen3 calibration OK (\(calibratedText.count) chars)")
            } else {
                DebugFileLogger.log("SenseVoice endAudio: Qwen3 calibration failed, using SenseVoice result")
            }
        }
        allAudioData = Data()

        emitTranscript(isFinal: true)
        eventContinuation?.yield(.completed)

        logger.info("SenseVoiceASR finalized: \(self.confirmedSegments.count) segments, \(self.totalSamplesFed) samples")
    }

    // MARK: - Disconnect

    func disconnect() async {
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        recognizer = nil
        vad = nil
        punctProcessor = nil
        confirmedSegments = []
        currentPartialText = ""
        speechBuffer = []
        allAudioData = Data()
        logger.info("SenseVoiceASR disconnected")
    }

    // MARK: - Async recognition callbacks

    private func confirmSegment(_ text: String, punctProcessor: SherpaPunctuationProcessor?) {
        pendingConfirmations = max(0, pendingConfirmations - 1)
        guard !finalized else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let punctuated = punctProcessor?.addPunctuation(to: trimmed) ?? trimmed
        confirmedSegments.append(punctuated)
        currentPartialText = ""
        logger.info("VAD segment confirmed: \(punctuated)")
        emitTranscript(isFinal: false)
    }

    private func updatePartial(_ text: String) {
        partialRecognitionInFlight = false
        guard !finalized else { return }  // endAudio already fired, ignore stale partial
        if text != currentPartialText {
            currentPartialText = text
            emitTranscript(isFinal: false)
        }
    }

    // MARK: - Internal

    private func emitTranscript(isFinal: Bool) {
        let composedText = (confirmedSegments + (currentPartialText.isEmpty ? [] : [currentPartialText])).joined()

        let transcript = RecognitionTranscript(
            confirmedSegments: confirmedSegments,
            partialText: currentPartialText,
            authoritativeText: isFinal ? composedText : "",
            isFinal: isFinal
        )
        DebugFileLogger.log("SenseVoice emit: confirmed=\(confirmedSegments.count) partial=\(currentPartialText.count) composed=\(composedText.count) isFinal=\(isFinal)")
        eventContinuation?.yield(.transcript(transcript))
    }

    // MARK: - Qwen3 Calibration

    private func qwen3Calibrate(audio: Data, port: Int) async -> String? {
        let url = URL(string: "http://127.0.0.1:\(port)/transcribe")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = audio
        request.timeoutInterval = 30
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String, !text.isEmpty else { return nil }
            return text
        } catch {
            logger.error("Qwen3 calibration failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Audio Conversion

    /// Convert Int16 PCM data to Float32 array normalized to [-1.0, 1.0].
    static func int16ToFloat32(_ data: Data) -> [Float] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        return data.withUnsafeBytes { raw in
            let int16Ptr = raw.bindMemory(to: Int16.self)
            return (0..<sampleCount).map { Float(int16Ptr[$0]) / 32768.0 }
        }
    }
}

#endif
