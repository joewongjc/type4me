import XCTest
@testable import Type4Me

final class BaiduASRConfigTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "tf_asrUID")
        super.tearDown()
    }

    func testInit_usesDefaultsWhenOptionalValuesMissing() throws {
        let config = try XCTUnwrap(BaiduASRConfig(credentials: [
            "appID": "123456",
            "apiKey": "baidu_test_key",
        ]))

        XCTAssertEqual(config.appID, 123456)
        XCTAssertEqual(config.apiKey, "baidu_test_key")
        XCTAssertEqual(config.devPID, 15372)
        XCTAssertFalse(config.cuid.isEmpty)
        XCTAssertEqual(config.lmID, "")
        XCTAssertTrue(config.isValid)
    }

    func testInit_rejectsMissingOrInvalidRequiredFields() {
        XCTAssertNil(BaiduASRConfig(credentials: [:]))
        XCTAssertNil(BaiduASRConfig(credentials: [
            "appID": "not-a-number",
            "apiKey": "baidu_test_key",
        ]))
        XCTAssertNil(BaiduASRConfig(credentials: [
            "appID": "123456",
            "apiKey": "   ",
        ]))
        XCTAssertNil(BaiduASRConfig(credentials: [
            "appID": "123456",
            "apiKey": "baidu_test_key",
            "devPID": "invalid",
        ]))
    }

    func testToCredentials_roundTrips() throws {
        let config = try XCTUnwrap(BaiduASRConfig(credentials: [
            "appID": "987654",
            "apiKey": "baidu_test_key",
            "devPID": "17372",
            "cuid": "device-123",
            "lmId": "model-001",
        ]))

        XCTAssertEqual(
            config.toCredentials(),
            [
                "appID": "987654",
                "apiKey": "baidu_test_key",
                "devPID": "17372",
                "cuid": "device-123",
                "lmId": "model-001",
            ]
        )
    }
}
