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
        XCTAssertFalse(BailianASRConfig.supportedModels.contains("qwen3-asr-flash-realtime"))
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
            "languageHint": "ko",
        ]))
        XCTAssertEqual(config.languageHint, "ko")

        let frenchConfig = try XCTUnwrap(BailianASRConfig(credentials: [
            "apiKey": "sk-test-key",
            "languageHint": "fr",
        ]))
        XCTAssertEqual(frenchConfig.languageHint, "fr")
    }

    func testInit_rejectsUnsupportedLanguageHints() throws {
        let config = try XCTUnwrap(BailianASRConfig(credentials: [
            "apiKey": "sk-test-key",
            "languageHint": "invalid-lang",
        ]))
        XCTAssertEqual(config.languageHint, "")
    }
    func testInit_regionDefaultsToChinaAndSelectsChinaKey() throws {
        let config = try XCTUnwrap(BailianASRConfig(credentials: [
            "apiKey": "sk-china-key",
            "intlApiKey": "sk-intl-key",
        ]))

        XCTAssertEqual(config.region, .china)
        XCTAssertEqual(config.apiKey, "sk-china-key")
        XCTAssertEqual(config.chinaApiKey, "sk-china-key")
        XCTAssertEqual(config.intlApiKey, "sk-intl-key")
    }

    func testInit_internationalRegionSelectsIntlKey() throws {
        let config = try XCTUnwrap(BailianASRConfig(credentials: [
            "region": "international",
            "apiKey": "sk-china-key",
            "intlApiKey": "sk-intl-key",
        ]))

        XCTAssertEqual(config.region, .international)
        XCTAssertEqual(config.apiKey, "sk-intl-key")
        XCTAssertEqual(config.chinaApiKey, "sk-china-key")
        XCTAssertEqual(config.intlApiKey, "sk-intl-key")
    }

    func testInit_rejectsMissingActiveKeyForRegion() {
        // China region missing China key
        XCTAssertNil(BailianASRConfig(credentials: [
            "region": "china",
            "intlApiKey": "sk-intl-key",
        ]))

        // International region missing Intl key
        XCTAssertNil(BailianASRConfig(credentials: [
            "region": "international",
            "apiKey": "sk-china-key",
        ]))
    }

    func testDisplayedCredentialFields_scopesKeyByRegion() {
        let chinaFields = BailianASRConfig.displayedCredentialFields(for: ["region": "china"])
        XCTAssertTrue(chinaFields.contains { $0.key == "apiKey" })
        XCTAssertFalse(chinaFields.contains { $0.key == "intlApiKey" })

        let intlFields = BailianASRConfig.displayedCredentialFields(for: ["region": "international"])
        XCTAssertFalse(intlFields.contains { $0.key == "apiKey" })
        XCTAssertTrue(intlFields.contains { $0.key == "intlApiKey" })
    }

    func testToCredentials_preservesBothTokensAcrossRegions() throws {
        let config = try XCTUnwrap(BailianASRConfig(credentials: [
            "region": "international",
            "apiKey": "sk-china-key",
            "intlApiKey": "sk-intl-key",
        ]))

        let saved = config.toCredentials()
        XCTAssertEqual(saved["region"], "international")
        XCTAssertEqual(saved["apiKey"], "sk-china-key")
        XCTAssertEqual(saved["intlApiKey"], "sk-intl-key")
    }

    func testEndpoints_resolveByRegionByDefault() throws {
        let chinaConfig = try XCTUnwrap(BailianASRConfig(credentials: ["apiKey": "sk-china"]))
        XCTAssertEqual(BailianProtocol.endpoint(for: chinaConfig).absoluteString, "wss://dashscope.aliyuncs.com/api-ws/v1/inference")
        XCTAssertEqual(BailianBatchTranscriber.endpoint(for: chinaConfig).absoluteString, "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")

        let intlConfig = try XCTUnwrap(BailianASRConfig(credentials: [
            "region": "international",
            "intlApiKey": "sk-intl",
        ]))
        XCTAssertEqual(BailianProtocol.endpoint(for: intlConfig).absoluteString, "wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference")
        XCTAssertEqual(BailianBatchTranscriber.endpoint(for: intlConfig).absoluteString, "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")
    }

    func testRegistry_exposesAliyunProvider() {
        let entry = ASRProviderRegistry.entry(for: .bailian)

        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isAvailable ?? false)
        XCTAssertTrue(ASRProviderRegistry.configType(for: .bailian) == BailianASRConfig.self)
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .bailian))
    }
}
