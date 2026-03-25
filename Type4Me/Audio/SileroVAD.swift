import Foundation
import os

#if canImport(SherpaOnnxLib)

/// Wraps SherpaOnnx's built-in Silero VAD for real-time voice activity detection.
/// Not thread-safe — call from a single queue (the audio capture queue).
final class SileroVAD {

    /// SherpaOnnx Silero VAD window size (samples @16kHz).
    static let windowSize = 512

    private let detector: SherpaOnnxVoiceActivityDetectorWrapper
    private let logger = Logger(subsystem: "com.type4me.vad", category: "SileroVAD")

    init(modelPath: String) {
        var sileroConfig = sherpaOnnxSileroVadModelConfig(
            model: modelPath,
            threshold: 0.5,
            minSilenceDuration: 0.25,
            minSpeechDuration: 0.25,
            windowSize: Self.windowSize
        )
        var vadConfig = sherpaOnnxVadModelConfig(
            sileroVad: sileroConfig,
            sampleRate: 16000,
            numThreads: 1,
            provider: "cpu"
        )
        detector = SherpaOnnxVoiceActivityDetectorWrapper(
            config: &vadConfig,
            buffer_size_in_seconds: 10
        )
        logger.info("Silero VAD loaded from \(modelPath)")
    }

    /// Convenience initializer: loads model from app bundle.
    convenience init?() {
        guard let url = Bundle.main.url(forResource: "silero_vad", withExtension: "onnx") else {
            NSLog("[SileroVAD] silero_vad.onnx not found in app bundle")
            return nil
        }
        self.init(modelPath: url.path)
    }

    /// Feed audio samples and return whether speech is currently detected.
    /// - Parameter samples: Float32 samples, range [-1, 1]. Must be `windowSize` (512) samples.
    func isSpeechDetected(samples: [Float]) -> Bool {
        detector.acceptWaveform(samples: samples)
        return detector.isSpeechDetected()
    }

    /// Reset detector state. Call when starting a new recording session.
    func reset() {
        detector.reset()
    }
}

#endif
