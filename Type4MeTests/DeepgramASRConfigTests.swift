import XCTest
@testable import Type4Me

final class DeepgramASRConfigTests: XCTestCase {

    func testInit_acceptsAPIKeyAndDefaultsModel() throws {
        let config = try XCTUnwrap(DeepgramASRConfig(credentials: [
            "apiKey": "dg_test_key"
        ]))

        XCTAssertEqual(config.apiKey, "dg_test_key")
        XCTAssertEqual(config.model, DeepgramASRConfig.defaultModel)
        XCTAssertEqual(config.language, DeepgramASRConfig.defaultLanguage)
        XCTAssertEqual(config.baseURL, DeepgramASRConfig.defaultBaseURL)
        XCTAssertTrue(config.isValid)
    }

    func testSupportedModelsExposeCurrentNova3Options() {
        XCTAssertEqual(DeepgramASRConfig.supportedModels.first, "nova-3")
        XCTAssertTrue(DeepgramASRConfig.supportedModels.contains("nova-3-general"))
        XCTAssertTrue(DeepgramASRConfig.supportedModels.contains("nova-3-medical"))
        XCTAssertFalse(DeepgramASRConfig.supportedModels.contains("flux-general-multi"))
    }

    func testModelFieldAllowsCustomInput() {
        let modelField = DeepgramASRConfig.credentialFields.first { $0.key == "model" }

        XCTAssertTrue(modelField?.allowCustomInput ?? false)
    }

    func testInit_rejectsMissingAPIKey() {
        XCTAssertNil(DeepgramASRConfig(credentials: [:]))
    }

    func testToCredentials_roundTripsConfiguredValues() throws {
        let config = try XCTUnwrap(DeepgramASRConfig(credentials: [
            "apiKey": "dg_test_key",
            "model": "nova-2",
        ]))

        XCTAssertEqual(config.toCredentials()["apiKey"], "dg_test_key")
        XCTAssertEqual(config.toCredentials()["model"], "nova-2")
        XCTAssertEqual(config.toCredentials()["language"], DeepgramASRConfig.defaultLanguage)
        XCTAssertEqual(config.toCredentials()["baseURL"], DeepgramASRConfig.defaultBaseURL)
    }

    func testCustomBaseURL_roundTrips() throws {
        let endpoint = "wss://example.test/proxy/deepgram/v1/listen"
        let config = try XCTUnwrap(DeepgramASRConfig(credentials: ["apiKey": "proxy-token", "baseURL": endpoint]))
        XCTAssertEqual(config.baseURL, endpoint)
        XCTAssertEqual(config.toCredentials()["baseURL"], endpoint)
    }

    func testRegistry_exposesDeepgramProvider() {
        let entry = ASRProviderRegistry.entry(for: .deepgram)

        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isAvailable ?? false)
        XCTAssertTrue(ASRProviderRegistry.configType(for: .deepgram) == DeepgramASRConfig.self)
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .deepgram))
    }
}
