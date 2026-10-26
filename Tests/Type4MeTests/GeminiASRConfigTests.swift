import XCTest
@testable import Type4Me

final class GeminiASRConfigTests: XCTestCase {

    func testInit_acceptsValidAPIKeyAndAppliesDefaults() throws {
        let config = try XCTUnwrap(GeminiASRConfig(credentials: [
            "apiKey": "test-gemini-key"
        ]))

        XCTAssertEqual(config.apiKey, "test-gemini-key")
        XCTAssertEqual(config.model, GeminiASRConfig.defaultModel)
        XCTAssertEqual(config.mode, .smart)
        XCTAssertEqual(config.languageCode, "auto")
        XCTAssertTrue(config.isValid)
    }

    func testInit_rejectsMissingOrEmptyAPIKey() {
        XCTAssertNil(GeminiASRConfig(credentials: [:]))
        XCTAssertNil(GeminiASRConfig(credentials: ["apiKey": ""]))
        XCTAssertNil(GeminiASRConfig(credentials: ["apiKey": "   \n\t "]))
    }

    func testInit_parsesModeAndLanguage() throws {
        let config = try XCTUnwrap(GeminiASRConfig(credentials: [
            "apiKey": "test-key",
            "mode": "VERBATIM",
            "languageCode": "cmn-Hans-CN"
        ]))

        XCTAssertEqual(config.mode, .verbatim)
        XCTAssertEqual(config.languageCode, "cmn-Hans-CN")
    }

    func testInit_fallsBackOnInvalidMode() throws {
        let config = try XCTUnwrap(GeminiASRConfig(credentials: [
            "apiKey": "test-key",
            "mode": "NON_EXISTENT_MODE"
        ]))

        XCTAssertEqual(config.mode, .smart)
    }

    func testToCredentials_roundTripsValues() throws {
        let config = try XCTUnwrap(GeminiASRConfig(credentials: [
            "apiKey": "test-key",
            "mode": "VERBATIM",
            "languageCode": "en-US"
        ]))

        let creds = config.toCredentials()
        XCTAssertEqual(creds["apiKey"], "test-key")
        XCTAssertEqual(creds["mode"], "VERBATIM")
        XCTAssertEqual(creds["languageCode"], "en-US")
    }

    func testCredentialFieldsMetadata() {
        let fields = GeminiASRConfig.credentialFields
        let apiKeyField = fields.first { $0.key == "apiKey" }
        XCTAssertNotNil(apiKeyField)
        XCTAssertTrue(apiKeyField?.isSecure ?? false)
        XCTAssertFalse(apiKeyField?.isOptional ?? true)

        let modeField = fields.first { $0.key == "mode" }
        XCTAssertNotNil(modeField)
        XCTAssertFalse(modeField?.isSecure ?? true)
        XCTAssertTrue(modeField?.isOptional ?? false)
        XCTAssertEqual(modeField?.defaultValue, "SMART")
        XCTAssertEqual(modeField?.options.map(\.value), ["SMART", "VERBATIM"])

        let langField = fields.first { $0.key == "languageCode" }
        XCTAssertNotNil(langField)
        XCTAssertFalse(langField?.isSecure ?? true)
        XCTAssertTrue(langField?.isOptional ?? false)
        XCTAssertTrue(langField?.allowCustomInput ?? false)
    }

    // MARK: - Model selection (provider "Gemini" → model underneath)

    func testInit_usesDefaultModelWhenMissingOrBlank() throws {
        let missing = try XCTUnwrap(GeminiASRConfig(credentials: ["apiKey": "k"]))
        XCTAssertEqual(missing.model, "gemini-3.5-transcribe-live")

        let blank = try XCTUnwrap(GeminiASRConfig(credentials: ["apiKey": "k", "model": "  \n "]))
        XCTAssertEqual(blank.model, "gemini-3.5-transcribe-live")
    }

    func testInit_acceptsExplicitModel() throws {
        let config = try XCTUnwrap(GeminiASRConfig(credentials: [
            "apiKey": "k",
            "model": "gemini-4-transcribe-live"
        ]))
        XCTAssertEqual(config.model, "gemini-4-transcribe-live")
        XCTAssertEqual(config.toCredentials()["model"], "gemini-4-transcribe-live")
    }

    func testCredentialFields_exposeModelPickerWithCustomInput() throws {
        let field = try XCTUnwrap(GeminiASRConfig.credentialFields.first { $0.key == "model" })
        XCTAssertFalse(field.isSecure)
        XCTAssertTrue(field.isOptional)
        XCTAssertTrue(field.allowCustomInput)
        XCTAssertEqual(field.defaultValue, GeminiASRConfig.defaultModel)
        XCTAssertEqual(
            field.options.map(\.value),
            GeminiASRConfig.supportedModels.map(\.id)
        )
    }

    func testCredentialFields_apiKeyPrecedesModel() throws {
        let keys = GeminiASRConfig.credentialFields.map(\.key)
        let apiKeyIndex = try XCTUnwrap(keys.firstIndex(of: "apiKey"))
        let modelIndex = try XCTUnwrap(keys.firstIndex(of: "model"))
        XCTAssertLessThan(apiKeyIndex, modelIndex)
    }
}
