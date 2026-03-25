import Foundation
import os

/// Wraps the SherpaOnnx CT-Transformer punctuation model for adding
/// punctuation to raw ASR output text.
///
/// Thread-safe: the processor is initialized once and can be called
/// from any context. The underlying SherpaOnnx wrapper manages its own state.
final class SherpaPunctuationProcessor: @unchecked Sendable {

    private let logger = Logger(
        subsystem: "com.type4me.asr",
        category: "Punctuation"
    )

    private var punctWrapper: SherpaOnnxOfflinePunctuationWrapper?
    private let lock = NSLock()

    /// Initialize with the path to the CT-Transformer model directory.
    /// The directory must contain `model.onnx`.
    init(modelDir: String) {
        let modelPath = (modelDir as NSString).appendingPathComponent("model.onnx")

        guard FileManager.default.fileExists(atPath: modelPath) else {
            logger.warning("Punctuation model not found at \(modelDir), punctuation disabled")
            return
        }

        var modelConfig = sherpaOnnxOfflinePunctuationModelConfig(
            ctTransformer: modelPath,
            numThreads: 1,
            debug: 0,
            provider: "cpu"
        )
        var config = sherpaOnnxOfflinePunctuationConfig(model: modelConfig)
        punctWrapper = SherpaOnnxOfflinePunctuationWrapper(config: &config)
        logger.info("Punctuation model loaded from \(modelDir)")
    }

    /// Add punctuation to raw text. Returns the original text if no model is loaded.
    func addPunctuation(to text: String) -> String {
        guard !text.isEmpty else { return text }

        lock.lock()
        defer { lock.unlock() }

        guard let wrapper = punctWrapper else { return text }

        let result = wrapper.addPunct(text: text)
        return result.isEmpty ? text : result
    }

    /// Whether the punctuation model is loaded and ready.
    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return punctWrapper != nil
    }
}
