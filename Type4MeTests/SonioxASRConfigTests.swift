import XCTest
@testable import Type4Me

final class SonioxASRConfigTests: XCTestCase {

    func testInit_acceptsAPIKeyAndDefaultsModel() throws {
        let config = try XCTUnwrap(SonioxASRConfig(credentials: [
            "apiKey": "soniox_test_key"
        ]))

        XCTAssertEqual(config.apiKey, "soniox_test_key")
        XCTAssertEqual(config.model, SonioxASRConfig.defaultModel)
        XCTAssertTrue(config.isValid)
    }

    func testInit_rejectsMissingAPIKey() {
        XCTAssertNil(SonioxASRConfig(credentials: [:]))
    }

    func testToCredentials_roundTripsConfiguredValues() throws {
        let config = try XCTUnwrap(SonioxASRConfig(credentials: [
            "apiKey": "soniox_test_key",
            "model": "stt-rt-v3",
        ]))

        XCTAssertEqual(config.toCredentials()["apiKey"], "soniox_test_key")
        XCTAssertEqual(config.toCredentials()["model"], "stt-rt-v3")
    }

    func testRegistry_exposesSonioxProvider() {
        let entry = ASRProviderRegistry.entry(for: .soniox)

        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isAvailable ?? false)
        XCTAssertTrue(ASRProviderRegistry.configType(for: .soniox) == SonioxASRConfig.self)
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .soniox))
    }
}
