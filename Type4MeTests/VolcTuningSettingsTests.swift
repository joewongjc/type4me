import XCTest
@testable import Type4Me

final class VolcTuningSettingsTests: XCTestCase {

    private func request(_ tuning: VolcTuningSettings, enablePunc: Bool = true) throws -> [String: Any] {
        let payload = VolcProtocol.buildClientRequest(
            uid: "u",
            options: ASRRequestOptions(enablePunc: enablePunc),
            tuning: tuning
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        return try XCTUnwrap(json["request"] as? [String: Any])
    }

    func testDefaultsReproduceShippedRequest() throws {
        let request = try request(VolcTuningSettings())
        XCTAssertEqual(request["enable_nonstream"] as? Bool, true)
        XCTAssertEqual(request["enable_ddc"] as? Bool, true)
        XCTAssertEqual(request["enable_punc"] as? Bool, true)
        XCTAssertEqual(request["end_window_size"] as? Int, 3000)
        XCTAssertEqual(request["force_to_speech_time"] as? Int, 0)
        XCTAssertNil(request["vad_segment_duration"])
        XCTAssertNil(request["enable_accelerate_text"])
        XCTAssertNil(request["accelerate_score"])
    }

    func testTunedValuesAndOmittedFields() throws {
        var tuning = VolcTuningSettings()
        tuning.sendEndWindowSize = false
        tuning.sendForceToSpeechTime = false
        tuning.sendVadSegmentDuration = true
        tuning.vadSegmentDurationMs = 1200
        tuning.enableAccelerateText = true
        tuning.accelerateScore = 8
        tuning.enableDDC = false
        tuning.enableITN = false
        tuning.enableNonstream = false

        let request = try request(tuning)
        XCTAssertNil(request["end_window_size"])
        XCTAssertNil(request["force_to_speech_time"])
        XCTAssertEqual(request["vad_segment_duration"] as? Int, 1200)
        XCTAssertEqual(request["enable_accelerate_text"] as? Bool, true)
        XCTAssertEqual(request["accelerate_score"] as? Int, 8)
        XCTAssertEqual(request["enable_ddc"] as? Bool, false)
        XCTAssertEqual(request["enable_itn"] as? Bool, false)
        XCTAssertEqual(request["enable_nonstream"] as? Bool, false)
    }

    func testCallerCanStillDisablePunctuation() throws {
        XCTAssertEqual(try request(VolcTuningSettings(), enablePunc: false)["enable_punc"] as? Bool, false)
    }

    func testDecodingKeepsDefaultsForMissingKeysAndClamps() throws {
        let data = Data(#"{"endWindowSizeMs": 50, "audioChunkMs": 123}"#.utf8)
        let decoded = try JSONDecoder().decode(VolcTuningSettings.self, from: data).clamped
        XCTAssertEqual(decoded.endWindowSizeMs, 200)
        XCTAssertEqual(decoded.audioChunkMs, 200)
        XCTAssertEqual(decoded.finalWaitMs, 2000)
        XCTAssertTrue(decoded.enableNonstream)
    }

    func testAudioChunkByteSize() {
        var tuning = VolcTuningSettings()
        XCTAssertEqual(tuning.audioChunkByteSize, AudioCaptureEngine.chunkByteSize)
        tuning.audioChunkMs = 100
        XCTAssertEqual(tuning.audioChunkByteSize, 3200)
    }

    func testCJKAwareJoin() {
        XCTAssertEqual(CJKAwareJoiner.join(["不是我本", "地的版本。"]), "不是我本地的版本。")
        XCTAssertEqual(CJKAwareJoiner.join(["打开", "GitHub"]), "打开GitHub")
        XCTAssertEqual(CJKAwareJoiner.join(["open", "GitHub"]), "open GitHub")
        XCTAssertEqual(CJKAwareJoiner.join(["done", ", next"]), "done, next")
        XCTAssertEqual(CJKAwareJoiner.join(["a ", "b"]), "a b")
    }

    func testAccumulatorCJKJoinRemovesServerBoundarySpace() {
        var accumulator = VolcTranscriptAccumulator(cjkAwareJoin: true)
        let result = VolcASRResult(
            text: "不是我本 低的版本",
            utterances: [
                VolcUtterance(text: "不是我本", definite: true),
                VolcUtterance(text: "低的版本", definite: false),
            ]
        )
        let transcript = accumulator.apply(result: result, isFinal: false).transcript
        XCTAssertEqual(transcript.authoritativeText, "不是我本低的版本")
        XCTAssertEqual(transcript.confirmedSegments, ["不是我本"])
        XCTAssertEqual(transcript.partialText, "低的版本")
        XCTAssertEqual(transcript.composedText, transcript.authoritativeText)

        accumulator.reset()
        let again = accumulator.apply(result: result, isFinal: false).transcript
        XCTAssertEqual(again.authoritativeText, "不是我本低的版本")
    }

    func testAccumulatorDefaultKeepsServerText() {
        var accumulator = VolcTranscriptAccumulator()
        let transcript = accumulator.apply(
            result: VolcASRResult(
                text: "不是我本 低的版本",
                utterances: [
                    VolcUtterance(text: "不是我本", definite: true),
                    VolcUtterance(text: "低的版本", definite: false),
                ]
            ),
            isFinal: false
        ).transcript
        XCTAssertEqual(transcript.authoritativeText, "不是我本 低的版本")
    }

    func testOtherProvidersIgnoreSavedTuning() {
        XCTAssertEqual(VolcTuningStorage.effective(for: .soniox), VolcTuningSettings())
    }
}
