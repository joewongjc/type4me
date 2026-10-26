import XCTest
@testable import Type4Me

final class TencentRecTaskProtocolTests: XCTestCase {

    private let pcm = Data(count: 3200)

    func testMakeRequest_buildsSignedCreateRecTask() throws {
        let config = try XCTUnwrap(TencentASRConfig(credentials: [
            "secretId": "test_id",
            "secretKey": "test_key",
            "appId": "1250000000",
            "recognitionMode": "batch",
        ]))

        let transcriber = TencentRecTaskTranscriber()
        let request = try transcriber.makeRequest(
            pcmData: pcm,
            config: config,
            options: ASRRequestOptions(hotwords: ["Type4Me"])
        )

        XCTAssertEqual(request.url?.absoluteString, "https://asr.tencentcloudapi.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Action"), "CreateRecTask")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Version"), "2019-06-14")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["EngineModelType"] as? String, "16k_zh_en_2.0")
        XCTAssertEqual(json["ChannelNum"] as? Int, 1)
        XCTAssertEqual(json["SourceType"] as? Int, 1)
        XCTAssertEqual(json["HotwordList"] as? String, "Type4Me|10")
        XCTAssertNotNil(json["Data"] as? String)
    }

    func testCleanResultText_stripsTimestampsAndJoins() {
        let rawZh = """
        [0:0.000,0:5.120]  这是第一句话。
        [0:5.120,0:9.800]  这是第二句话。
        """
        let cleanedZh = TencentRecTaskTranscriber.cleanResultText(rawZh)
        XCTAssertEqual(cleanedZh, "这是第一句话。这是第二句话。")

        let rawEn = """
        [0:0.000,0:2.100]  Hello world.
        [0:2.100,0:4.300]  Nice to meet you.
        """
        let cleanedEn = TencentRecTaskTranscriber.cleanResultText(rawEn)
        XCTAssertEqual(cleanedEn, "Hello world. Nice to meet you.")
    }

    func testApiErrorExtraction() {
        let errorJson = """
        {
            "Response": {
                "Error": {
                    "Code": "AuthFailure.SignatureFailure",
                    "Message": "The provided credentials could not be verified."
                },
                "RequestId": "req-12345"
            }
        }
        """
        let err = TencentRecTaskTranscriber.apiError(from: Data(errorJson.utf8))
        XCTAssertNotNil(err)
        XCTAssertEqual(err?.code, "AuthFailure.SignatureFailure")
        XCTAssertTrue(err?.message.contains("verified") ?? false)
    }
}
