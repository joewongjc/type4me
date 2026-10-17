import XCTest
@testable import Type4Me

final class PCMSilenceDetectorTests: XCTestCase {

    func testEmptyDataIsSilent() {
        XCTAssertTrue(PCMSilenceDetector.isSilent(Data()))
    }

    func testZeroPCMIsSilent() {
        // 1 second of zero amplitude PCM (16000 * 2 bytes)
        let silence = Data(count: 32_000)
        XCTAssertTrue(PCMSilenceDetector.isSilent(silence))
    }

    func testSubThresholdNoiseIsSilent() {
        // -60 dBFS noise: amplitude around 32767 * 10^(-60/20) ≈ 32
        var pcm = Data(count: 32_000)
        pcm.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<16_000 {
                ptr[i] = Int16(i % 2 == 0 ? 30 : -30)
            }
        }
        XCTAssertTrue(PCMSilenceDetector.isSilent(pcm))
    }

    func testAudibleSineWaveIsNotSilent() {
        // -20 dBFS sine wave: amplitude around 3276.7
        let sampleCount = 16_000 // 1 second
        var pcm = Data(count: sampleCount * 2)
        pcm.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self).baseAddress!
            let amplitude: Double = 3276.0
            for i in 0..<sampleCount {
                let angle = 2.0 * Double.pi * 440.0 * Double(i) / 16000.0
                ptr[i] = Int16(amplitude * sin(angle))
            }
        }
        XCTAssertFalse(PCMSilenceDetector.isSilent(pcm))
    }

    func testShortBurstUnderMinimumAudibleDurationIsSilent() {
        // 0.1s of loud audio followed by 0.9s of silence -> total audible 0.1s < 0.3s minimum
        let sampleCount = 16_000
        var pcm = Data(count: sampleCount * 2)
        pcm.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self).baseAddress!
            let burstSamples = 1600 // 0.1s
            for i in 0..<burstSamples {
                ptr[i] = Int16(10_000 * sin(2.0 * Double.pi * 440.0 * Double(i) / 16000.0))
            }
        }
        XCTAssertTrue(PCMSilenceDetector.isSilent(pcm))
    }
}
