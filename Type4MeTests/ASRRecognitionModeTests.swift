import XCTest
@testable import Type4Me

final class ASRRecognitionModeTests: XCTestCase {

    private var previousLanguage: String?

    override func setUp() {
        super.setUp()
        previousLanguage = UserDefaults.standard.string(forKey: "tf_language")
    }

    override func tearDown() {
        if let previousLanguage {
            UserDefaults.standard.set(previousLanguage, forKey: "tf_language")
        } else {
            UserDefaults.standard.removeObject(forKey: "tf_language")
        }
        super.tearDown()
    }

    func testUnknownOrMissingValueFallsBackToStreaming() {
        XCTAssertEqual(ASRRecognitionMode(credentialValue: nil), .streaming)
        XCTAssertEqual(ASRRecognitionMode(credentialValue: "weird"), .streaming)
        XCTAssertEqual(ASRRecognitionMode(credentialValue: " batch "), .batch)
    }

    func testLabelsSwitchWithAppLanguage() {
        UserDefaults.standard.set("zh", forKey: "tf_language")
        XCTAssertEqual(ASRRecognitionMode.streaming.displayName, "实时流式")
        XCTAssertEqual(ASRRecognitionMode.batch.displayName, "非实时")
        XCTAssertEqual(ASRRecognitionMode.credentialField.label, "识别方式")
        XCTAssertEqual(ASRRecognitionMode.batchRecordingPlaceholder, "录音中 · 结束后识别")
        XCTAssertTrue(ASRRecognitionMode.batch.summary.contains("结束录音后"))
        XCTAssertEqual(StepFunASRConfig.credentialFields.first { $0.key == "accessMode" }?.label, "接入方式")

        UserDefaults.standard.set("en", forKey: "tf_language")
        XCTAssertEqual(ASRRecognitionMode.streaming.displayName, "Real-time")
        XCTAssertEqual(ASRRecognitionMode.batch.displayName, "Batch")
        XCTAssertEqual(ASRRecognitionMode.credentialField.label, "Recognition")
        XCTAssertEqual(ASRRecognitionMode.batchRecordingPlaceholder, "Recording · text at end")
        XCTAssertTrue(ASRRecognitionMode.batch.summary.contains("when you stop recording"))
        XCTAssertEqual(StepFunASRConfig.credentialFields.first { $0.key == "accessMode" }?.label, "Access Mode")
        XCTAssertEqual(
            BatchASRError.recordingTooLong(provider: "Gemini", maxSeconds: 420).errorDescription,
            "The recording exceeds the 7-minute limit of Gemini batch recognition. Switch to real-time mode."
        )
    }

    func testModelFieldIsSwappedPerMode() {
        func keys(_ type: any ASRProviderConfig.Type, _ mode: ASRRecognitionMode) -> [String] {
            type.displayedCredentialFields(for: ["recognitionMode": mode.rawValue]).map(\.key)
        }
        for type in [BailianASRConfig.self, GeminiASRConfig.self, ElevenLabsASRConfig.self] as [any ASRProviderConfig.Type] {
            XCTAssertTrue(keys(type, .streaming).contains("model"))
            XCTAssertFalse(keys(type, .streaming).contains("batchModel"))
            XCTAssertTrue(keys(type, .batch).contains("batchModel"))
            XCTAssertFalse(keys(type, .batch).contains("model"))
        }
        XCTAssertEqual(keys(GrokASRConfig.self, .batch), keys(GrokASRConfig.self, .streaming))
    }

    func testHistoryModelLabelFollowsRecognitionMode() throws {
        func label(_ provider: ASRProvider, _ type: any ASRProviderConfig.Type, _ values: [String: String]) -> String? {
            RecognitionSession.asrModelLabel(for: provider, config: type.init(credentials: values))
        }
        let name = ASRProvider.bailian.displayName
        XCTAssertEqual(
            label(.bailian, BailianASRConfig.self, ["apiKey": "k"]),
            "\(name) · qwen-audio-3.1-asr-flash-streaming"
        )
        XCTAssertEqual(
            label(.bailian, BailianASRConfig.self, ["apiKey": "k", "recognitionMode": "batch"]),
            "\(name) · qwen-audio-3.1-asr-flash"
        )
        XCTAssertEqual(
            label(.elevenlabs, ElevenLabsASRConfig.self, ["apiKey": "k", "recognitionMode": "batch"]),
            "ElevenLabs · scribe_v2"
        )
        XCTAssertEqual(
            label(.gemini, GeminiASRConfig.self, ["apiKey": "k", "recognitionMode": "batch"]),
            "Gemini · gemini-3.5-transcribe"
        )
        XCTAssertEqual(
            label(.stepfun, StepFunASRConfig.self, ["apiKey": "k", "recognitionMode": "batch"]),
            "\(ASRProvider.stepfun.displayName) · stepaudio-2.5-asr"
        )
        XCTAssertEqual(
            label(.stepfun, StepFunASRConfig.self, ["apiKey": "k"]),
            "\(ASRProvider.stepfun.displayName) · stepaudio-2.5-asr-stream"
        )
    }

    func testConfigsRememberModelPerMode() throws {
        let config = try XCTUnwrap(ElevenLabsASRConfig(credentials: [
            "apiKey": "k",
            "recognitionMode": "batch",
            "model": "scribe_v2_realtime",
        ]))
        XCTAssertEqual(config.recognitionMode, .batch)
        XCTAssertEqual(config.model, "scribe_v2_realtime")
        XCTAssertEqual(config.batchModel, "scribe_v2")
        XCTAssertEqual(config.toCredentials()["recognitionMode"], "batch")
        XCTAssertTrue(config.isValid)
    }
}

final class StepFunBatchMigrationTests: XCTestCase {

    private let legacyStorageKey = "tf_asr_stepfunBatch"
    private var originalStepFun: [String: String]?
    private var originalSelectedRaw: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard KeychainService.isUsingTestStorage else {
            throw XCTSkip("Requires isolated credential storage")
        }
        originalStepFun = KeychainService.loadASRCredentials(for: .stepfun)
        originalSelectedRaw = UserDefaults.standard.object(forKey: "tf_selectedASRProvider")
        try KeychainService.saveASRCredentials(for: .stepfun, values: [:])
    }

    override func tearDown() {
        guard KeychainService.isUsingTestStorage else {
            super.tearDown()
            return
        }
        try? KeychainService.seedLegacyASRCredentialsForTesting(storageKey: legacyStorageKey, plaintext: [:], secure: [:])
        KeychainService.deleteSecureValuesForTesting(account: KeychainService.stepFunUnusedStandardKeyAccount)
        try? KeychainService.saveASRCredentials(for: .stepfun, values: originalStepFun ?? [:])
        if let originalSelectedRaw {
            UserDefaults.standard.set(originalSelectedRaw, forKey: "tf_selectedASRProvider")
        } else {
            UserDefaults.standard.removeObject(forKey: "tf_selectedASRProvider")
        }
        super.tearDown()
    }

    func testSelectedStepPlanSetupBecomesStepFunBatchModeWithoutTouchingRealtimeKey() throws {
        try KeychainService.saveASRCredentials(for: .stepfun, values: ["apiKey": "sk-realtime", "region": "global"])
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey,
            plaintext: ["accessMode": "stepPlan"],
            secure: ["apiKey": "sk-plan"]
        )
        UserDefaults.standard.set("stepfunBatch", forKey: "tf_selectedASRProvider")

        KeychainService.migrateStoredCredentials()

        XCTAssertEqual(KeychainService.selectedASRProvider, .stepfun)
        let values = try XCTUnwrap(KeychainService.loadASRCredentials(for: .stepfun))
        XCTAssertEqual(values["recognitionMode"], "batch")
        XCTAssertEqual(values["accessMode"], "stepPlan")
        XCTAssertEqual(values["apiKey"], "sk-realtime")
        XCTAssertEqual(values["stepPlanApiKey"], "sk-plan")
        XCTAssertEqual(values["region"], "global")
        XCTAssertFalse(KeychainService.hasStoredCredentialsForTesting(storageKey: legacyStorageKey))

        let config = try XCTUnwrap(KeychainService.loadASRConfig(for: .stepfun) as? StepFunASRConfig)
        XCTAssertEqual(config.batchAPIKey, "sk-plan")
    }

    func testMissingLegacyAccessModeMeansStepPlan() throws {
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey,
            plaintext: [:],
            secure: ["apiKey": "sk-plan"]
        )

        KeychainService.migrateStoredCredentials()

        let values = try XCTUnwrap(KeychainService.loadASRCredentials(for: .stepfun))
        XCTAssertEqual(values["accessMode"], "stepPlan")
        XCTAssertEqual(values["stepPlanApiKey"], "sk-plan")
        XCTAssertEqual(values["recognitionMode"], "batch", "No realtime key, so the batch setup stays active")
    }

    func testUnselectedStandardSetupKeepsExistingRealtimeMode() throws {
        try KeychainService.saveASRCredentials(for: .stepfun, values: ["apiKey": "sk-realtime"])
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey,
            plaintext: ["accessMode": "standard"],
            secure: ["apiKey": "sk-other-standard"]
        )
        UserDefaults.standard.set("volcano", forKey: "tf_selectedASRProvider")

        KeychainService.migrateStoredCredentials()

        XCTAssertEqual(KeychainService.selectedASRProvider, .volcano)
        let values = try XCTUnwrap(KeychainService.loadASRCredentials(for: .stepfun))
        XCTAssertEqual(values["recognitionMode"], "streaming")
        XCTAssertEqual(values["apiKey"], "sk-realtime")
        XCTAssertEqual(values["accessMode"], "standard")
        XCTAssertEqual(
            KeychainService.loadSecureValuesForTesting(account: KeychainService.stepFunUnusedStandardKeyAccount)["apiKey"],
            "sk-other-standard",
            "The unused batch key must be backed up, not discarded"
        )
    }

    func testSelectedStandardBatchKeepsItsOwnKeyWhenKeysDiffer() throws {
        try KeychainService.saveASRCredentials(for: .stepfun, values: ["apiKey": "sk-realtime"])
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey,
            plaintext: ["accessMode": "standard"],
            secure: ["apiKey": "sk-batch"]
        )
        UserDefaults.standard.set("stepfunBatch", forKey: "tf_selectedASRProvider")

        KeychainService.migrateStoredCredentials()

        let values = try XCTUnwrap(KeychainService.loadASRCredentials(for: .stepfun))
        XCTAssertEqual(values["recognitionMode"], "batch")
        XCTAssertEqual(values["apiKey"], "sk-batch", "The active batch setup keeps the key it was using")
        XCTAssertEqual(
            KeychainService.loadSecureValuesForTesting(account: KeychainService.stepFunUnusedStandardKeyAccount)["apiKey"],
            "sk-realtime"
        )
        XCTAssertFalse(KeychainService.hasStoredCredentialsForTesting(storageKey: legacyStorageKey))

        // A second launch must not migrate again.
        KeychainService.migrateStoredCredentials()
        XCTAssertEqual(KeychainService.loadASRCredentials(for: .stepfun)?["apiKey"], "sk-batch")
    }

    func testFailedFileSaveKeepsLegacyDataAndSelectionForRetry() throws {
        try KeychainService.saveASRCredentials(for: .stepfun, values: ["apiKey": "sk-realtime"])
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey,
            plaintext: ["accessMode": "standard"],
            secure: ["apiKey": "sk-batch"]
        )
        UserDefaults.standard.set("stepfunBatch", forKey: "tf_selectedASRProvider")

        KeychainService.failNextCredentialsFileSaveForTesting = true
        KeychainService.migrateStoredCredentials()

        XCTAssertEqual(UserDefaults.standard.string(forKey: "tf_selectedASRProvider"), "stepfunBatch")
        XCTAssertEqual(KeychainService.loadSecureValuesForTesting(account: legacyStorageKey)["apiKey"], "sk-batch")

        // The retry on the next launch completes the merge with the original selection intact.
        KeychainService.migrateStoredCredentials()

        XCTAssertEqual(KeychainService.selectedASRProvider, .stepfun)
        let values = try XCTUnwrap(KeychainService.loadASRCredentials(for: .stepfun))
        XCTAssertEqual(values["recognitionMode"], "batch")
        XCTAssertEqual(values["apiKey"], "sk-batch")
        XCTAssertEqual(
            KeychainService.loadSecureValuesForTesting(account: KeychainService.stepFunUnusedStandardKeyAccount)["apiKey"],
            "sk-realtime"
        )
        XCTAssertFalse(KeychainService.hasStoredCredentialsForTesting(storageKey: legacyStorageKey))
    }

    func testLegacyConfigWithoutRecognitionModeStillCountsAsConfigured() throws {
        let original = KeychainService.loadASRCredentials(for: .bailian)
        defer { try? KeychainService.saveASRCredentials(for: .bailian, values: original ?? [:]) }

        // Saved by an older version: no recognitionMode or batchModel.
        try KeychainService.saveASRCredentials(for: .bailian, values: [
            "apiKey": "sk-old",
            "model": "qwen-audio-3.1-asr-flash-streaming",
        ])
        try KeychainService.saveASRCredentials(for: .stepfun, values: ["apiKey": "sk-old", "region": "china"])

        XCTAssertTrue(ModelSettingsHelpers.hasConfiguredCredentials(for: ASRProvider.bailian))
        XCTAssertTrue(ModelSettingsHelpers.hasConfiguredCredentials(for: ASRProvider.stepfun))
        XCTAssertEqual(ASRProviderRegistry.recognitionMode(for: .bailian), .streaming)
    }

    func testStandardKeyFillsEmptyRealtimeKey() throws {
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey,
            plaintext: ["accessMode": "standard"],
            secure: ["apiKey": "sk-standard"]
        )

        KeychainService.migrateStoredCredentials()

        let values = try XCTUnwrap(KeychainService.loadASRCredentials(for: .stepfun))
        XCTAssertEqual(values["apiKey"], "sk-standard")
        XCTAssertEqual(values["recognitionMode"], "batch")
    }
}
