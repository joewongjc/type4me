import Foundation
import os

#if canImport(SherpaOnnxLib)

/// One-shot offline speech recognizer using SherpaOnnx + Paraformer.
///
/// Used for dual-channel mode: after streaming recognition ends,
/// the complete recorded audio is processed in a single pass for
/// potentially higher accuracy. This parallels `VolcFlashASRClient`
/// for the local provider.
enum SherpaOfflineASRClient {

    private static let logger = Logger(
        subsystem: "com.type4me.asr",
        category: "SherpaOfflineASR"
    )

    // MARK: - Cached recognizer

    private static var cachedRecognizer: SherpaOnnxOfflineRecognizer?
    private static var cachedModelDir: String?
    private static var cachedPunctProcessor: SherpaPunctuationProcessor?
    private static let lock = NSLock()

    /// Recognize complete PCM audio data in a single pass.
    ///
    /// - Parameters:
    ///   - pcmData: Raw Int16 mono 16kHz PCM audio data.
    ///   - config: Sherpa ASR configuration containing model paths.
    /// - Returns: Recognized text with punctuation (if punct model available).
    static func recognize(
        pcmData: Data,
        config: SherpaASRConfig
    ) async throws -> String {
        guard !pcmData.isEmpty else {
            throw SherpaOfflineASRError.emptyAudio
        }

        let modelDir = config.offlineModelDir
        let modelPath = (modelDir as NSString).appendingPathComponent("model.int8.onnx")
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw SherpaOfflineASRError.modelNotFound(modelDir)
        }

        logger.info("Offline recognition: \(pcmData.count) bytes PCM")

        // Get or create recognizer
        let recognizer = try getOrCreateRecognizer(modelDir: modelDir)

        // Convert Int16 PCM → Float32
        let floatSamples = SherpaASRClient.int16ToFloat32(pcmData)

        // Decode in one shot
        let result = recognizer.decode(samples: floatSamples, sampleRate: 16000)
        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        logger.info("Offline result: \(text.prefix(100))")

        // Apply punctuation if available
        if !text.isEmpty {
            let punctProcessor = getOrCreatePunctProcessor(config: config)
            if let proc = punctProcessor {
                text = proc.addPunctuation(to: text)
            }
        }

        return text
    }

    /// Pre-load the offline model for faster first use.
    static func preloadModel(config: SherpaASRConfig) {
        let modelDir = config.offlineModelDir
        guard ModelManager.shared.isModelAvailable(ModelManager.AuxModelType.offlineParaformer) else { return }
        _ = try? getOrCreateRecognizer(modelDir: modelDir)
        NSLog("[SherpaOfflineASR] Offline model preloaded")
    }

    // MARK: - Internal

    private static func getOrCreateRecognizer(modelDir: String) throws -> SherpaOnnxOfflineRecognizer {
        // Fast path: return cached recognizer (lock held briefly, safe in async context)
        lock.lock()
        if let cached = cachedRecognizer, cachedModelDir == modelDir {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Slow path: model initialization runs outside the lock to avoid
        // blocking the cooperative thread pool for extended periods.
        let paraConfig = sherpaOnnxOfflineParaformerModelConfig(
            model: (modelDir as NSString).appendingPathComponent("model.int8.onnx")
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: (modelDir as NSString).appendingPathComponent("tokens.txt"),
            paraformer: paraConfig,
            numThreads: 2,
            provider: "cpu",
            debug: 0,
            modelType: "paraformer"
        )
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        var recConfig = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig
        )

        let recognizer = SherpaOnnxOfflineRecognizer(config: &recConfig)

        lock.lock()
        cachedRecognizer = recognizer
        cachedModelDir = modelDir
        lock.unlock()

        return recognizer
    }

    private static func getOrCreatePunctProcessor(config: SherpaASRConfig) -> SherpaPunctuationProcessor? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedPunctProcessor { return cached }

        guard ModelManager.shared.isModelAvailable(ModelManager.AuxModelType.punctuation) else { return nil }
        let proc = SherpaPunctuationProcessor(modelDir: config.punctModelDir)
        cachedPunctProcessor = proc
        return proc
    }
}

enum SherpaOfflineASRError: Error, LocalizedError {
    case emptyAudio
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return L("没有录音数据", "No audio data to recognize")
        case .modelNotFound(let path):
            return L("离线模型未找到: \(path)", "Offline model not found: \(path)")
        }
    }
}

#endif  // canImport(SherpaOnnxLib)
