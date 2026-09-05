import XCTest
@testable import Type4Me

final class MetaMuseASRConfigTests: XCTestCase {

    func testInit_acceptsValidCredentials() throws {
        let config = try XCTUnwrap(MetaMuseASRConfig(credentials: [
            "apiKey": "meta_model_api_key",
            "languageBias": "Chinese",
        ]))

        XCTAssertEqual(config.apiKey, "meta_model_api_key")
        XCTAssertEqual(config.languageBias, "Chinese")
        XCTAssertTrue(config.isValid)
    }

    func testInit_defaultsLanguageBiasToEmpty() throws {
        let config = try XCTUnwrap(MetaMuseASRConfig(credentials: [
            "apiKey": "meta_key"
        ]))

        XCTAssertEqual(config.apiKey, "meta_key")
        XCTAssertEqual(config.languageBias, "")
        XCTAssertTrue(config.isValid)
    }

    func testInit_rejectsMissingOrEmptyAPIKey() {
        XCTAssertNil(MetaMuseASRConfig(credentials: [:]))
        XCTAssertNil(MetaMuseASRConfig(credentials: ["apiKey": ""]))
        XCTAssertNil(MetaMuseASRConfig(credentials: ["apiKey": "   \n\t"]))
    }

    func testInit_sanitizesWhitespace() throws {
        let config = try XCTUnwrap(MetaMuseASRConfig(credentials: [
            "apiKey": "  meta_key_with_spaces  \n",
            "languageBias": "  English \t",
        ]))

        XCTAssertEqual(config.apiKey, "meta_key_with_spaces")
        XCTAssertEqual(config.languageBias, "English")
    }

    func testToCredentials_roundTrips() throws {
        let original: [String: String] = [
            "apiKey": "test_key_123",
            "languageBias": "Japanese",
        ]
        let config = try XCTUnwrap(MetaMuseASRConfig(credentials: original))
        let creds = config.toCredentials()

        XCTAssertEqual(creds["apiKey"], "test_key_123")
        XCTAssertEqual(creds["languageBias"], "Japanese")
    }

    func testCredentialFields_apiKeyIsSecure() {
        let fields = MetaMuseASRConfig.credentialFields
        let apiKeyField = fields.first { $0.key == "apiKey" }
        let langField = fields.first { $0.key == "languageBias" }

        XCTAssertNotNil(apiKeyField)
        XCTAssertTrue(apiKeyField?.isSecure ?? false)
        XCTAssertFalse(apiKeyField?.isOptional ?? true)

        XCTAssertNotNil(langField)
        XCTAssertFalse(langField?.isSecure ?? true)
        XCTAssertTrue(langField?.isOptional ?? false)
        XCTAssertFalse(langField?.options.isEmpty ?? true)
    }

    func testRegistry_exposesMetaMuseProvider() {
        let entry = ASRProviderRegistry.entry(for: .metaMuse)

        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isAvailable ?? false)
        XCTAssertTrue(entry?.capabilities.isStreaming ?? false)
        XCTAssertTrue(entry?.capabilities.supportsRealtimeRecognition ?? false)
        XCTAssertEqual(entry?.capabilities.audioInput, .pcmData)
        XCTAssertTrue(ASRProviderRegistry.configType(for: .metaMuse) == MetaMuseASRConfig.self)
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .metaMuse))
    }
}
