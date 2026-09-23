import XCTest
@testable import Type4Me

final class BailianASRConfigTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "tf_asrUID")
        super.tearDown()
    }

    func testInit_acceptsAPIKeyAndDefaultsModelAndDeviceID() throws {
        let config = try XCTUnwrap(BailianASRConfig(credentials: [
            "apiKey": "sk-test-key"
        ]))

        XCTAssertEqual(config.apiKey, "sk-test-key")
        XCTAssertEqual(config.model, BailianASRConfig.defaultModel)
        XCTAssertEqual(config.languageHint, "")
        XCTAssertEqual(config.vocabularyId, "")
        XCTAssertTrue(config.isValid)
    }

    func testSupportedModelsExposeCurrentRealtimeModels() {
        XCTAssertEqual(BailianASRConfig.defaultModel, "qwen-audio-3.1-asr-flash-streaming")
        XCTAssertEqual(BailianASRConfig.supportedModels.first, "qwen-audio-3.1-asr-flash-streaming")
        XCTAssertTrue(BailianASRConfig.supportedModels.contains("qwen-audio-3.0-asr-flash-streaming"))
        XCTAssertTrue(BailianASRConfig.supportedModels.contains("qwen3-asr-flash-realtime"))
        XCTAssertTrue(BailianASRConfig.supportedModels.contains("fun-asr-realtime"))
        XCTAssertTrue(BailianASRConfig.supportedModels.contains("fun-asr-flash-8k-realtime"))
    }

    func testCredentialFieldsExposeModelPickerWithCustomFallback() throws {
        let modelField = try XCTUnwrap(BailianASRConfig.credentialFields.first { $0.key == "model" })

        XCTAssertEqual(modelField.defaultValue, BailianASRConfig.defaultModel)
        XCTAssertTrue(modelField.allowCustomInput)
        XCTAssertTrue(modelField.options.map(\.value).contains("qwen-audio-3.1-asr-flash-streaming"))
        XCTAssertTrue(modelField.options.map(\.value).contains("fun-asr-realtime"))
    }

    func testInit_rejectsMissingAPIKey() {
        XCTAssertNil(BailianASRConfig(credentials: [:]))
    }

    func testToCredentials_roundTripsConfiguredValues() throws {
        let config = try XCTUnwrap(BailianASRConfig(credentials: [
            "apiKey": "sk-test-key",
            "model": "fun-asr-realtime-2025-11-07",
            "languageHint": "ja",
            "vocabularyId": "vocab-123",
        ]))

        XCTAssertEqual(config.toCredentials()["apiKey"], "sk-test-key")
        XCTAssertEqual(config.toCredentials()["model"], "fun-asr-realtime-2025-11-07")
        XCTAssertEqual(config.toCredentials()["languageHint"], "ja")
        XCTAssertEqual(config.toCredentials()["vocabularyId"], "vocab-123")
    }

    func testInit_acceptsExtendedLanguageHints() throws {
        let config = try XCTUnwrap(BailianASRConfig(credentials: [
            "apiKey": "sk-test-key",
            "languageHint": "yue",
        ]))
        XCTAssertEqual(config.languageHint, "yue")

        let koreanConfig = try XCTUnwrap(BailianASRConfig(credentials: [
            "apiKey": "sk-test-key",
            "languageHint": "ko",
        ]))
        XCTAssertEqual(koreanConfig.languageHint, "ko")
    }

    func testRegistry_exposesAliyunProvider() {
        let entry = ASRProviderRegistry.entry(for: .bailian)

        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isAvailable ?? false)
        XCTAssertTrue(ASRProviderRegistry.configType(for: .bailian) == BailianASRConfig.self)
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .bailian))
    }
}
