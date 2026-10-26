import XCTest
@testable import Type4Me

final class ASRSampleArchiveTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t4m-asr-samples-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSample(pcmBytes: Int, text: String) -> ASRSampleArchive.Sample {
        ASRSampleArchive.Sample(
            pcm: Data(repeating: 0, count: pcmBytes),
            rawText: text,
            provider: .soniox,
            asrModel: "Soniox · stt-rt",
            isStreaming: true,
            status: "completed",
            purpose: "input",
            processingModeId: nil,
            processingModeName: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func readManifest() throws -> [ASRSampleRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = try String(contentsOf: root.appendingPathComponent(ASRSampleArchive.manifestFileName), encoding: .utf8)
        return try text.split(separator: "\n").map {
            try decoder.decode(ASRSampleRecord.self, from: Data($0.utf8))
        }
    }

    func testSaveWritesWAVAndAppendsManifestLines() async throws {
        let archive = ASRSampleArchive(rootDirectory: root)

        let first = await archive.save(makeSample(pcmBytes: 32_000, text: "你好，世界"))
        let second = await archive.save(makeSample(pcmBytes: 16_000, text: "second"))

        let records = try readManifest()
        XCTAssertEqual(records, [first, second].compactMap { $0 })
        XCTAssertEqual(records.map(\.rawText), ["你好，世界", "second"])
        XCTAssertEqual(records.map(\.audioDurationSeconds), [1.0, 0.5])
        XCTAssertEqual(records.first?.asrProvider, ASRProvider.soniox.rawValue)

        let wavURL = root.appendingPathComponent(try XCTUnwrap(first).audioFile)
        let wav = try Data(contentsOf: wavURL)
        XCTAssertEqual(wav.count, 44 + 32_000)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
    }

    func testEmptyAudioIsSkipped() async throws {
        let archive = ASRSampleArchive(rootDirectory: root)

        let record = await archive.save(makeSample(pcmBytes: 0, text: "ignored"))

        XCTAssertNil(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
