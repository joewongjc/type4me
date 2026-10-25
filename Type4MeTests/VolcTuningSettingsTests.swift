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

    // MARK: - Presets

    func testAccuratePresetSendsShippedEndpointing() throws {
        let request = try request(.accurate)
        XCTAssertEqual(request["end_window_size"] as? Int, 3000)
        XCTAssertEqual(request["force_to_speech_time"] as? Int, 0)
        XCTAssertEqual(request["enable_nonstream"] as? Bool, true)
        XCTAssertTrue(VolcTuningSettings.accurate.cjkAwareJoin)
        XCTAssertEqual(VolcTuningSettings.accurate.finalWaitMs, 2000)
        XCTAssertFalse(VolcTuningSettings.accurate.commitOnFinalTimeout)
    }

    func testFastPresetLetsServerEndpoint() throws {
        let request = try request(.fast)
        XCTAssertNil(request["end_window_size"])
        XCTAssertNil(request["force_to_speech_time"])
        XCTAssertEqual(request["enable_nonstream"] as? Bool, true)
        XCTAssertTrue(VolcTuningSettings.fast.cjkAwareJoin)
        XCTAssertEqual(VolcTuningSettings.fast.finalWaitMs, 3000)
        XCTAssertTrue(VolcTuningSettings.fast.commitOnFinalTimeout)
    }

    func testProfileEffectiveSettings() {
        var custom = VolcTuningSettings.fast
        custom.endWindowSizeMs = 2500
        XCTAssertEqual(VolcRecognitionProfile().effectiveSettings, .accurate)
        XCTAssertEqual(VolcRecognitionProfile(preset: .fast, custom: custom).effectiveSettings, .fast)
        XCTAssertEqual(VolcRecognitionProfile(preset: .custom, custom: custom).effectiveSettings.endWindowSizeMs, 2500)
        XCTAssertEqual(VolcRecognitionProfile(preset: .custom, custom: nil).effectiveSettings, .accurate)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let name = "VolcRecognitionProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testProfileRoundTripsAndKeepsCustomWhileOnPreset() throws {
        let defaults = try isolatedDefaults()
        var custom = VolcTuningSettings.accurate
        custom.endWindowSizeMs = 1500
        VolcRecognitionProfileStore.save(VolcRecognitionProfile(preset: .fast, custom: custom), userDefaults: defaults)
        let loaded = VolcRecognitionProfileStore.load(userDefaults: defaults)
        XCTAssertEqual(loaded.preset, .fast)
        XCTAssertEqual(loaded.custom?.endWindowSizeMs, 1500)
    }

    func testLegacyTuningMigratesToMatchingPresetOrCustom() throws {
        func migrate(_ settings: VolcTuningSettings) throws -> (VolcRecognitionProfile, UserDefaults) {
            let defaults = try isolatedDefaults()
            defaults.set(try JSONEncoder().encode(settings), forKey: VolcRecognitionProfileStore.legacyTuningKey)
            return (VolcRecognitionProfileStore.load(userDefaults: defaults), defaults)
        }
        let (fast, fastDefaults) = try migrate(.fast)
        XCTAssertEqual(fast.preset, .fast)
        XCTAssertNil(fastDefaults.data(forKey: VolcRecognitionProfileStore.legacyTuningKey))
        XCTAssertEqual(VolcRecognitionProfileStore.load(userDefaults: fastDefaults).preset, .fast)

        var tweaked = VolcTuningSettings.fast
        tweaked.finalWaitMs = 1200
        let (custom, _) = try migrate(tweaked)
        XCTAssertEqual(custom.preset, .custom)
        XCTAssertEqual(custom.custom?.finalWaitMs, 1200)
    }

    func testCJKJoinDropsBoundaryWhitespaceNextToCJK() {
        XCTAssertEqual(CJKAwareJoiner.join(["我刚刚提了一个 PR。", " 然后跑了测试"]), "我刚刚提了一个 PR。然后跑了测试")
        XCTAssertEqual(CJKAwareJoiner.join(["但是 ", "我现在"]), "但是我现在")
        XCTAssertEqual(CJKAwareJoiner.join(["open ", " GitHub"]), "open GitHub")
        XCTAssertEqual(CJKAwareJoiner.join(["用 GitHub", "提交"]), "用 GitHub提交")
    }
}
