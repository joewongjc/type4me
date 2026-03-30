import XCTest
import AVFoundation
@testable import Type4Me

private actor DataOnlyRecognizer: SpeechRecognizer {
    var events: AsyncStream<RecognitionEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {}
    func sendAudio(_ data: Data) async throws {}
    func endAudio() async throws {}
    func disconnect() async {}
}

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

    func testMakePCMBufferFromPCMData_usesTargetFormat() throws {
        let pcmData = Data([0x00, 0x00, 0x01, 0x00, 0xFF, 0xFF, 0x02, 0x00])

        let buffer = try XCTUnwrap(AudioCaptureEngine.makePCMBuffer(from: pcmData))

        XCTAssertEqual(buffer.format.sampleRate, 16000)
        XCTAssertEqual(buffer.format.channelCount, 1)
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(buffer.frameLength, 4)
    }

    func testSpeechRecognizerDefaultBufferInputIsNoOp() async throws {
        let recognizer = DataOnlyRecognizer()
        let pcmData = Data([0x00, 0x00, 0x01, 0x00])
        let buffer = try XCTUnwrap(AudioCaptureEngine.makePCMBuffer(from: pcmData))

        try await recognizer.sendAudioBuffer(buffer)
    }
}
