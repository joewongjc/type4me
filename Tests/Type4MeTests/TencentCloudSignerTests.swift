import XCTest
@testable import Type4Me

final class TencentCloudSignerTests: XCTestCase {

    func testSignedWebSocketURL_sortsKeysAndEncodesSignature() throws {
        let url = try TencentCloudSigner.signedWebSocketURL(
            appId: "1250000000",
            secretId: "test_secret_id",
            secretKey: "test_secret_key",
            parameters: [
                "engine_model_type": "16k_zh_en_2.0",
                "voice_format": "1",
            ],
            timestamp: 1700000000,
            expiresIn: 86400,
            nonce: 123456,
            voiceId: "test-voice-uuid"
        )

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.scheme, "wss")
        XCTAssertEqual(components?.host, "asr.cloud.tencent.com")
        XCTAssertEqual(components?.path, "/asr/v2/1250000000")

        let items = components?.queryItems ?? []
        let itemKeys = items.map(\.name)

        XCTAssertTrue(itemKeys.contains("secretid"))
        XCTAssertTrue(itemKeys.contains("timestamp"))
        XCTAssertTrue(itemKeys.contains("expired"))
        XCTAssertTrue(itemKeys.contains("nonce"))
        XCTAssertTrue(itemKeys.contains("voice_id"))
        XCTAssertTrue(itemKeys.contains("signature"))

        let sig = items.first(where: { $0.name == "signature" })?.value
        XCTAssertNotNil(sig)
        XCTAssertFalse(sig!.isEmpty)
    }

    func testSignedAPIRequest_buildsTC3AuthorizationHeader() {
        let payload = Data("{\"Action\":\"CreateRecTask\"}".utf8)
        let request = TencentCloudSigner.signedAPIRequest(
            action: "CreateRecTask",
            payload: payload,
            secretId: "AKIDtest123",
            secretKey: "SecretKeyTest456",
            timestamp: 1700000000 // 2023-11-14 22:13:20 UTC
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Host"), "asr.tencentcloudapi.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Action"), "CreateRecTask")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Version"), "2019-06-14")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Timestamp"), "1700000000")

        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(auth.hasPrefix("TC3-HMAC-SHA256 Credential=AKIDtest123/2023-11-14/asr/tc3_request"))
        XCTAssertTrue(auth.contains("SignedHeaders=content-type;host"))
        XCTAssertTrue(auth.contains("Signature="))
    }

    func testSignedAPIRequest_usesUTCDateAcrossMidnight() {
        // Timestamp at 23:59 UTC: 2023-11-14 23:59:00 UTC = 1700006340
        let req1 = TencentCloudSigner.signedAPIRequest(
            action: "DescribeTaskStatus",
            payload: Data(),
            secretId: "AKID",
            secretKey: "KEY",
            timestamp: 1700006340
        )
        let auth1 = req1.value(forHTTPHeaderField: "Authorization")!
        XCTAssertTrue(auth1.contains("2023-11-14/asr/tc3_request"))

        // Timestamp at 00:01 UTC next day: 2023-11-15 00:01:00 UTC = 1700006460
        let req2 = TencentCloudSigner.signedAPIRequest(
            action: "DescribeTaskStatus",
            payload: Data(),
            secretId: "AKID",
            secretKey: "KEY",
            timestamp: 1700006460
        )
        let auth2 = req2.value(forHTTPHeaderField: "Authorization")!
        XCTAssertTrue(auth2.contains("2023-11-15/asr/tc3_request"))
    }

    func testPayloadChangeChangesSignature() {
        let req1 = TencentCloudSigner.signedAPIRequest(
            action: "CreateRecTask",
            payload: Data("payload1".utf8),
            secretId: "AKID",
            secretKey: "KEY",
            timestamp: 1700000000
        )
        let req2 = TencentCloudSigner.signedAPIRequest(
            action: "CreateRecTask",
            payload: Data("payload2".utf8),
            secretId: "AKID",
            secretKey: "KEY",
            timestamp: 1700000000
        )
        XCTAssertNotEqual(
            req1.value(forHTTPHeaderField: "Authorization"),
            req2.value(forHTTPHeaderField: "Authorization")
        )
    }
}
