import XCTest
@testable import Type4Me

final class TencentASRConfigTests: XCTestCase {

    func testConfigTrimsFields() throws {
        let config = try XCTUnwrap(TencentASRConfig(credentials: [
            "secretId": "  my_secret_id  ",
            "secretKey": "  my_secret_key  ",
            "appId": "  1251234567  ",
        ]))
        XCTAssertEqual(config.secretId, "my_secret_id")
        XCTAssertEqual(config.secretKey, "my_secret_key")
        XCTAssertEqual(config.appId, "1251234567")
        XCTAssertEqual(config.recognitionMode, .streaming)
        XCTAssertTrue(config.isValid)
    }

    func testConfigRejectsNonNumericAppID() {
        XCTAssertNil(TencentASRConfig(credentials: [
            "secretId": "sid",
            "secretKey": "key",
            "appId": "125abc",
        ]))
    }

    func testConfigRejectsMissingOrEmptyFields() {
        XCTAssertNil(TencentASRConfig(credentials: ["secretId": "", "secretKey": "key", "appId": "123"]))
        XCTAssertNil(TencentASRConfig(credentials: ["secretId": "sid", "secretKey": "", "appId": "123"]))
        XCTAssertNil(TencentASRConfig(credentials: ["secretId": "sid", "secretKey": "key", "appId": ""]))
    }

    func testRecognitionModeRoundtrip() throws {
        let batchConfig = try XCTUnwrap(TencentASRConfig(credentials: [
            "secretId": "sid",
            "secretKey": "key",
            "appId": "1250000000",
            "recognitionMode": "batch",
        ]))
        XCTAssertEqual(batchConfig.recognitionMode, .batch)
        let creds = batchConfig.toCredentials()
        XCTAssertEqual(creds["recognitionMode"], "batch")
        XCTAssertEqual(creds["secretId"], "sid")
    }

    func testCredentialFieldsLayout() {
        let fields = TencentASRConfig.credentialFields
        let keys = fields.map(\.key)
        XCTAssertEqual(keys, ["recognitionMode", "secretId", "secretKey", "appId"])
        XCTAssertTrue(fields.first(where: { $0.key == "secretKey" })?.isSecure ?? false)
    }
}
