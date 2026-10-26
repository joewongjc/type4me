import XCTest
import AVFoundation
@testable import Type4Me

final class AudioCaptureEngineTests: XCTestCase {

    func testAudioChunkSize() {
        XCTAssertEqual(AudioCaptureEngine.chunkByteSize, 6400)
    }

    func testSamplesPerChunk() {
        XCTAssertEqual(AudioCaptureEngine.samplesPerChunk, 3200)
    }

    func testTargetAudioFormat() {
        let format = AudioCaptureEngine.targetFormat
        XCTAssertEqual(format.sampleRate, 16000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatInt16)
    }
}
