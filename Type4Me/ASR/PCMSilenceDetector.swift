import Foundation

enum PCMSilenceDetector {
    /// 30 ms frames above -50 dBFS count as audible.
    static let frameDuration: TimeInterval = 0.03
    static let audibleThresholdDBFS: Float = -50
    /// Total audible time required before a recording is worth uploading.
    static let minimumAudibleDuration: TimeInterval = 0.3

    /// Checks whether 16kHz mono 16-bit PCM audio contains enough audible signal.
    static func isSilent(_ pcm: Data) -> Bool {
        let sampleCount = pcm.count / 2
        guard sampleCount > 0 else { return true }

        let frameSampleCount = max(1, Int(16_000 * frameDuration))
        let minAudibleFrames = Int(ceil(minimumAudibleDuration / frameDuration))
        var audibleFrames = 0

        pcm.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }

            var offset = 0
            while offset < sampleCount {
                let currentFrameCount = min(frameSampleCount, sampleCount - offset)
                var sumOfSquares: Double = 0

                for i in 0..<currentFrameCount {
                    let sample = Double(ptr[offset + i]) / 32768.0
                    sumOfSquares += sample * sample
                }

                let rms = sqrt(sumOfSquares / Double(currentFrameCount))
                let dbfs = Float(20 * log10(max(rms, 1e-9)))

                if dbfs > audibleThresholdDBFS {
                    audibleFrames += 1
                    if audibleFrames >= minAudibleFrames {
                        return
                    }
                }

                offset += currentFrameCount
            }
        }

        return audibleFrames < minAudibleFrames
    }
}
