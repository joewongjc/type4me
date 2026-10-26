import XCTest
@testable import Type4Me

final class WAVEncoderTests: XCTestCase {

    func testEncode_createsValidRIFFHeader() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let wav = WAVEncoder.encode(pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16)

        XCTAssertEqual(wav.count, 44 + pcm.count)

        // RIFF magic
        XCTAssertEqual(String(data: wav.subdata(in: 0..<4), encoding: .utf8), "RIFF")

        // File size (36 + data size = 40)
        let fileSize = wav.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(fileSize, 40)

        // WAVE magic
        XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .utf8), "WAVE")

        // fmt chunk
        XCTAssertEqual(String(data: wav.subdata(in: 12..<16), encoding: .utf8), "fmt ")
        let fmtSize = wav.subdata(in: 16..<20).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(fmtSize, 16)

        let audioFormat = wav.subdata(in: 20..<22).withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(audioFormat, 1) // PCM

        let numChannels = wav.subdata(in: 22..<24).withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(numChannels, 1)

        let sampleRate = wav.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(sampleRate, 16000)

        let byteRate = wav.subdata(in: 28..<32).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(byteRate, 32000) // 16000 * 1 * 16 / 8

        let blockAlign = wav.subdata(in: 32..<34).withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(blockAlign, 2) // 1 * 16 / 8

        let bitsPerSample = wav.subdata(in: 34..<36).withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(bitsPerSample, 16)

        // data chunk
        XCTAssertEqual(String(data: wav.subdata(in: 36..<40), encoding: .utf8), "data")
        let dataSize = wav.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(dataSize, 4)

        // PCM payload
        XCTAssertEqual(wav.subdata(in: 44..<48), pcm)
    }

    func testEncode_emptyPCMProduces44ByteHeader() {
        let empty = Data()
        let wav = WAVEncoder.encode(pcmData: empty)
        XCTAssertEqual(wav.count, 44)

        let fileSize = wav.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(fileSize, 36)

        let dataSize = wav.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(dataSize, 0)
    }
}
