import XCTest
@testable import Type4Me

final class GrokASRConfigTests: XCTestCase {

    func testInit_acceptsAPIKeyAndDefaultsLanguage() throws {
        let config = try XCTUnwrap(GrokASRConfig(credentials: [
            "apiKey": "xai_test_key",
        ]))

        XCTAssertEqual(config.apiKey, "xai_test_key")
        XCTAssertEqual(config.language, "")
        XCTAssertTrue(config.isValid)
    }

    func testUsesCurrentStreamingModel() {
        XCTAssertEqual(GrokASRConfig.model, "grok-voice-transcribe-2.0")
    }

    func testInit_acceptsLanguage() throws {
        let config = try XCTUnwrap(GrokASRConfig(credentials: [
            "apiKey": "xai_test_key",
            "language": "en",
        ]))

        XCTAssertEqual(config.language, "en")
    }

    func testCredentialFieldsExposeAPIKeyAndLanguage() throws {
        let keys = GrokASRConfig.credentialFields.map(\.key)
        XCTAssertEqual(keys, ["apiKey", "language"])
    }

    func testAPIKeyPlaceholderMatchesProviderFormat() {
        let apiKeyField = GrokASRConfig.credentialFields.first { $0.key == "apiKey" }
        XCTAssertEqual(apiKeyField?.placeholder, "xai-...")
    }
}
