import XCTest
@testable import Type4Me

final class SonioxASRConfigTests: XCTestCase {

    func testInit_acceptsAPIKeyAndDefaultsModel() throws {
        let config = try XCTUnwrap(SonioxASRConfig(credentials: [
            "apiKey": "soniox_test_key"
        ]))

        XCTAssertEqual(config.apiKey, "soniox_test_key")
        XCTAssertEqual(config.model, SonioxASRConfig.defaultModel)
        XCTAssertEqual(config.endpointSensitivity, SonioxASRConfig.defaultEndpointSensitivity)
        XCTAssertTrue(config.isValid)
    }

    func testInit_rejectsMissingAPIKey() {
        XCTAssertNil(SonioxASRConfig(credentials: [:]))
    }

    func testToCredentials_roundTripsConfiguredValues() throws {
        let config = try XCTUnwrap(SonioxASRConfig(credentials: [
            "apiKey": "soniox_test_key",
            "model": "stt-rt-v5",
            "endpointSensitivity": "-0.5",
        ]))

        XCTAssertEqual(config.toCredentials()["apiKey"], "soniox_test_key")
        XCTAssertEqual(config.toCredentials()["model"], "stt-rt-v5")
        XCTAssertEqual(config.toCredentials()["endpointSensitivity"], "-0.5")
    }

    func testInit_invalidEndpointSensitivityFallsBackToDictationDefault() throws {
        for value in ["invalid", "1.1", "-1.1"] {
            let config = try XCTUnwrap(SonioxASRConfig(credentials: [
                "apiKey": "soniox_test_key",
                "endpointSensitivity": value,
            ]))

            XCTAssertEqual(config.endpointSensitivity, SonioxASRConfig.defaultEndpointSensitivity)
        }
    }

    func testInitMigratesLegacyRealtimeModelsToV5() throws {
        for legacyModel in ["stt-rt-v3", "stt-rt-v4"] {
            let config = try XCTUnwrap(SonioxASRConfig(credentials: [
                "apiKey": "soniox_test_key",
                "model": legacyModel,
            ]))

            XCTAssertEqual(config.model, "stt-rt-v5")
            XCTAssertTrue(config.isValid)
        }
    }

    func testRegistry_exposesSonioxProvider() {
        let entry = ASRProviderRegistry.entry(for: .soniox)

        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isAvailable ?? false)
        XCTAssertTrue(ASRProviderRegistry.configType(for: .soniox) == SonioxASRConfig.self)
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .soniox))
    }
}
