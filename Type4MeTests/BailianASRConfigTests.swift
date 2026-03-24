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
        XCTAssertTrue(config.deviceId.hasPrefix("type4me-"))
        XCTAssertEqual(config.languageHint, "")
        XCTAssertEqual(config.vocabularyId, "")
        XCTAssertTrue(config.isValid)
    }

    func testInit_rejectsMissingAPIKey() {
        XCTAssertNil(BailianASRConfig(credentials: [:]))
    }

    func testToCredentials_roundTripsConfiguredValues() throws {
        let config = try XCTUnwrap(BailianASRConfig(credentials: [
            "apiKey": "sk-test-key",
            "model": "fun-asr-realtime-2025-11-07",
            "deviceId": "custom-device",
            "languageHint": "ja",
            "vocabularyId": "vocab-123",
        ]))

        XCTAssertEqual(config.toCredentials()["apiKey"], "sk-test-key")
        XCTAssertEqual(config.toCredentials()["model"], "fun-asr-realtime-2025-11-07")
        XCTAssertEqual(config.toCredentials()["deviceId"], "custom-device")
        XCTAssertEqual(config.toCredentials()["languageHint"], "ja")
        XCTAssertEqual(config.toCredentials()["vocabularyId"], "vocab-123")
    }

    func testRegistry_exposesAliyunProvider() {
        let entry = ASRProviderRegistry.entry(for: .bailian)

        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isAvailable ?? false)
        XCTAssertTrue(ASRProviderRegistry.configType(for: .bailian) == BailianASRConfig.self)
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .bailian))
    }
}
