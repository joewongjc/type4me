import XCTest
@testable import Type4Me

final class MiMoASRConfigTests: XCTestCase {

    func testInit_acceptsAPIKeyAndDefaultsToAutoLanguage() throws {
        let config = try XCTUnwrap(MiMoASRConfig(credentials: [
            "apiKey": "  mimo-api-key-test  ",
        ]))

        XCTAssertEqual(config.apiKey, "mimo-api-key-test")
        XCTAssertEqual(config.language, .auto)
        XCTAssertTrue(config.isValid)
    }

    func testInit_acceptsSpecificLanguages() throws {
        let zhConfig = try XCTUnwrap(MiMoASRConfig(credentials: [
            "apiKey": "key",
            "language": "zh",
        ]))
        XCTAssertEqual(zhConfig.language, .zh)

        let enConfig = try XCTUnwrap(MiMoASRConfig(credentials: [
            "apiKey": "key",
            "language": "en",
        ]))
        XCTAssertEqual(enConfig.language, .en)
    }

    func testInit_defaultsUnknownLanguageToAuto() throws {
        let config = try XCTUnwrap(MiMoASRConfig(credentials: [
            "apiKey": "key",
            "language": "yue",
        ]))

        XCTAssertEqual(config.language, .auto)
    }

    func testInit_rejectsMissingOrBlankAPIKey() {
        XCTAssertNil(MiMoASRConfig(credentials: [:]))
        XCTAssertNil(MiMoASRConfig(credentials: ["apiKey": "   "]))
    }

    func testToCredentials_roundTripsAPIKeyAndLanguage() throws {
        let config = try XCTUnwrap(MiMoASRConfig(credentials: [
            "apiKey": "mimo-key-123",
            "language": "zh",
        ]))

        XCTAssertEqual(config.toCredentials(), [
            "apiKey": "mimo-key-123",
            "language": "zh",
        ])
    }

    func testCredentialFieldsExposeLanguagePicker() throws {
        let fields = MiMoASRConfig.credentialFields
        XCTAssertEqual(fields.map(\.key), ["apiKey", "language"])
        XCTAssertFalse(try XCTUnwrap(fields.first).isOptional)
        XCTAssertTrue(try XCTUnwrap(fields.first).isSecure)

        let languageField = try XCTUnwrap(fields.first { $0.key == "language" })
        XCTAssertFalse(languageField.isSecure)
        XCTAssertTrue(languageField.isOptional)
        XCTAssertEqual(languageField.defaultValue, "auto")
        XCTAssertEqual(languageField.options.map(\.value), ["auto", "zh", "en"])
    }

    func testRegistry_exposesBatchMiMoProvider() {
        let entry = ASRProviderRegistry.entry(for: .mimo)

        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isAvailable ?? false)
        XCTAssertTrue(ASRProviderRegistry.configType(for: .mimo) == MiMoASRConfig.self)
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .mimo))
        XCTAssertEqual(ASRProviderRegistry.capabilities(for: .mimo), .batch())
    }
}
