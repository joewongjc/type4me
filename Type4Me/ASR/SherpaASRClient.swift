import Foundation
import os
#if canImport(SherpaOnnxLib)
import SherpaOnnxLib
#endif

enum SherpaASRError: Error, LocalizedError {
    case unsupportedConfig
    case modelNotFound(String)
    case recognizerInitFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedConfig:
            return "SherpaASRClient requires SherpaASRConfig"
        case .modelNotFound(let path):
            return L("模型未找到: \(path)", "Model not found: \(path)")
        case .recognizerInitFailed:
            return L("识别引擎初始化失败", "Recognizer initialization failed")
        }
    }
}

/// Local streaming speech recognizer using SherpaOnnx.
///
/// Supports both Paraformer (encoder+decoder) and Zipformer CTC (single model)
/// architectures, selected via `ModelManager.selectedStreamingModel`.
actor SherpaASRClient: SpeechRecognizer {

    private let logger = Logger(
        subsystem: "com.type4me.asr",
        category: "SherpaASRClient"
    )

    // MARK: - State

    private var recognizer: SherpaOnnxRecognizer?
    private var punctProcessor: SherpaPunctuationProcessor?

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    /// Accumulated confirmed segments (after endpoint detection).
    private var confirmedSegments: [String] = []
    /// Current partial text (between endpoints).
    private var currentPartialText: String = ""
    /// Total audio samples fed so far.
    private var totalSamplesFed: Int = 0

    /// Samples to skip at start to avoid start-sound interference.
    /// 200ms delay + 150ms tone + 50ms margin = 400ms × 16 samples/ms = 6400 samples.
    private let skipInitialSamples = 6400
    private var samplesSkipped: Int = 0

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events {
            return existing
        }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream
        return stream
    }

    // MARK: - Cached recognizer (avoid reloading model each session)

    private static let cacheLock = NSLock()
    private static var _cachedRecognizer: SherpaOnnxRecognizer?
    private static var _cachedPunctProcessor: SherpaPunctuationProcessor?
    private static var _cachedModelDir: String?

    private static var cachedRecognizer: SherpaOnnxRecognizer? {
        get { cacheLock.withLock { _cachedRecognizer } }
        set { cacheLock.withLock { _cachedRecognizer = newValue } }
    }
    private static var cachedPunctProcessor: SherpaPunctuationProcessor? {
        get { cacheLock.withLock { _cachedPunctProcessor } }
        set { cacheLock.withLock { _cachedPunctProcessor = newValue } }
    }
    private static var cachedModelDir: String? {
        get { cacheLock.withLock { _cachedModelDir } }
        set { cacheLock.withLock { _cachedModelDir = newValue } }
    }

    /// Pre-load models at app startup for instant first recording.
    static func preloadModels(config: SherpaASRConfig) {
        let modelDir = config.onlineModelDir
        guard cachedRecognizer == nil || cachedModelDir != modelDir else { return }

        NSLog("[SherpaASR] Preloading models from %@", modelDir)

        var recConfig = buildRecognizerConfig(modelDir: modelDir)
        cachedRecognizer = SherpaOnnxRecognizer(config: &recConfig)
        cachedModelDir = modelDir
        NSLog("[SherpaASR] Online model preloaded")

        // Preload punctuation if available
        let punctDir = config.punctModelDir
        if ModelManager.shared.isModelAvailable(ModelManager.AuxModelType.punctuation) {
            cachedPunctProcessor = SherpaPunctuationProcessor(modelDir: punctDir)
            NSLog("[SherpaASR] Punctuation model preloaded")
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

        let modelDir = sherpaConfig.onlineModelDir

        // Use cached recognizer if model dir matches, otherwise create new
        if let cached = Self.cachedRecognizer, Self.cachedModelDir == modelDir {
            cached.reset()
            recognizer = cached
            punctProcessor = Self.cachedPunctProcessor
            logger.info("Reusing cached recognizer")
        } else {
            // Verify model files exist
            let selectedModel = ModelManager.selectedStreamingModel
            let checkPath = (modelDir as NSString).appendingPathComponent(selectedModel.modelFileName)
            guard FileManager.default.fileExists(atPath: checkPath) else {
                throw SherpaASRError.modelNotFound(modelDir)
            }

            var recConfig = Self.buildRecognizerConfig(modelDir: modelDir)
            recognizer = SherpaOnnxRecognizer(config: &recConfig)
            Self.cachedRecognizer = recognizer
            Self.cachedModelDir = modelDir

            // Load punctuation if available
            if ModelManager.shared.isModelAvailable(ModelManager.AuxModelType.punctuation) {
                punctProcessor = SherpaPunctuationProcessor(modelDir: sherpaConfig.punctModelDir)
                Self.cachedPunctProcessor = punctProcessor
            }

            logger.info("Created new recognizer from \(modelDir)")
        }

        // Feed a short silence to warm up the feature pipeline so the first
        // real audio frames are not clipped by the model's receptive field.
        let warmupMs = 200  // 200 ms of silence
        let warmupSamples = [Float](repeating: 0, count: 16 * warmupMs)  // 16 samples/ms at 16kHz
        recognizer?.acceptWaveform(samples: warmupSamples, sampleRate: 16000)

        eventContinuation?.yield(.ready)
        logger.info("SherpaASR connected (local)")
    }

    // MARK: - Build Config

    private static func buildRecognizerConfig(modelDir: String) -> SherpaOnnxOnlineRecognizerConfig {
        let selectedModel = ModelManager.selectedStreamingModel
        let tokensPath = (modelDir as NSString).appendingPathComponent("tokens.txt")

        let modelConfig: SherpaOnnxOnlineModelConfig

        switch selectedModel.architecture {
        case .ctc:
            let ctcConfig = sherpaOnnxOnlineZipformer2CtcModelConfig(
                model: (modelDir as NSString).appendingPathComponent(selectedModel.modelFileName)
            )
            modelConfig = sherpaOnnxOnlineModelConfig(
                tokens: tokensPath,
                zipformer2Ctc: ctcConfig,
                numThreads: 2,
                provider: "cpu",
                debug: 0,
                modelType: "zipformer2"
            )
        case .paraformer:
            let paraConfig = sherpaOnnxOnlineParaformerModelConfig(
                encoder: (modelDir as NSString).appendingPathComponent("encoder.int8.onnx"),
                decoder: (modelDir as NSString).appendingPathComponent("decoder.int8.onnx")
            )
            modelConfig = sherpaOnnxOnlineModelConfig(
                tokens: tokensPath,
                paraformer: paraConfig,
                numThreads: 2,
                provider: "cpu",
                debug: 0,
                modelType: "paraformer"
            )
        }

        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        return sherpaOnnxOnlineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            enableEndpoint: true,
            rule1MinTrailingSilence: 1.5,
            rule2MinTrailingSilence: 0.8,
            rule3MinUtteranceLength: 20,
            decodingMethod: "greedy_search"
        )
    }

    // MARK: - Send Audio

    func sendAudio(_ data: Data) async throws {
        guard let recognizer else { return }

        var floatSamples = Self.int16ToFloat32(data)
        totalSamplesFed += floatSamples.count

        // Skip initial audio that overlaps with the start sound to avoid first-char errors.
        // The start sound plays ~200ms after recording begins and lasts ~150ms.
        if samplesSkipped < skipInitialSamples {
            let remaining = skipInitialSamples - samplesSkipped
            if floatSamples.count <= remaining {
                samplesSkipped += floatSamples.count
                return  // entire chunk is within skip window
            }
            floatSamples = Array(floatSamples.dropFirst(remaining))
            samplesSkipped = skipInitialSamples
        }

        recognizer.acceptWaveform(samples: floatSamples, sampleRate: 16000)

        while recognizer.isReady() {
            recognizer.decode()
        }

        if recognizer.isEndpoint() {
            let result = recognizer.getResult()
            let segmentText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if !segmentText.isEmpty {
                let punctuated = punctProcessor?.addPunctuation(to: segmentText) ?? segmentText
                confirmedSegments.append(punctuated)
                logger.info("Endpoint detected, confirmed: \(punctuated)")
            }

            recognizer.reset()
            currentPartialText = ""

            emitTranscript(isFinal: false)
        } else {
            let result = recognizer.getResult()
            let partialText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if partialText != currentPartialText {
                currentPartialText = partialText
                emitTranscript(isFinal: false)
            }
        }
    }

    // MARK: - End Audio

    func endAudio() async throws {
        guard let recognizer else { return }

        recognizer.inputFinished()

        while recognizer.isReady() {
            recognizer.decode()
        }

        let result = recognizer.getResult()
        let remainingText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if !remainingText.isEmpty {
            let punctuated = punctProcessor?.addPunctuation(to: remainingText) ?? remainingText
            confirmedSegments.append(punctuated)
        }

        // Clear partial so it doesn't duplicate the just-confirmed text
        currentPartialText = ""

        emitTranscript(isFinal: true)
        eventContinuation?.yield(.completed)

        logger.info("SherpaASR finalized: \(self.confirmedSegments.count) segments, \(self.totalSamplesFed) samples")
    }

    // MARK: - Disconnect

    func disconnect() async {
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        recognizer = nil
        punctProcessor = nil
        confirmedSegments = []
        currentPartialText = ""
        logger.info("SherpaASR disconnected")
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
        eventContinuation?.yield(.transcript(transcript))
    }

    /// Convert Int16 PCM data to Float32 array normalized to [-1.0, 1.0].
    static func int16ToFloat32(_ data: Data) -> [Float] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        return data.withUnsafeBytes { raw in
            let int16Ptr = raw.bindMemory(to: Int16.self)
            return (0..<sampleCount).map { Float(int16Ptr[$0]) / 32768.0 }
        }
    }
}
