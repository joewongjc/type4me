import XCTest
@testable import Type4Me

final class OpenAIASRConfigTests: XCTestCase {

    func testCredentialFieldsExposeConfigurableBaseURL() throws {
        let field = try XCTUnwrap(
            OpenAIASRConfig.credentialFields.first { $0.key == "baseURL" }
        )

        XCTAssertEqual(field.defaultValue, OpenAIASRConfig.defaultBaseURL)
        XCTAssertEqual(field.placeholder, OpenAIASRConfig.defaultBaseURL)
        XCTAssertTrue(field.isOptional)
        XCTAssertFalse(field.isSecure)
    }

    func testInitDefaultsToOfficialBaseURL() throws {
        let config = try XCTUnwrap(OpenAIASRConfig(credentials: [
            "apiKey": "sk-test-key",
        ]))

        XCTAssertEqual(config.baseURL, OpenAIASRConfig.defaultBaseURL)
    }

    func testInitAcceptsAndRoundTripsCustomBaseURL() throws {
        let customBaseURL = "http://localhost:8000/v1"
        let config = try XCTUnwrap(OpenAIASRConfig(credentials: [
            "apiKey": "sk-test-key",
            "model": "whisper-local",
            "baseURL": "  \(customBaseURL)/\n",
        ]))

        XCTAssertEqual(config.baseURL, customBaseURL)
        XCTAssertEqual(config.toCredentials()["baseURL"], customBaseURL)
    }

    func testInitFallsBackForBlankBaseURL() throws {
        let config = try XCTUnwrap(OpenAIASRConfig(credentials: [
            "apiKey": "sk-test-key",
            "baseURL": "  \n",
        ]))

        XCTAssertEqual(config.baseURL, OpenAIASRConfig.defaultBaseURL)
    }
}
