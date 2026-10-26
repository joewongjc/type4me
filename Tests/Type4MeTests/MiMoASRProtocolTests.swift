import XCTest
@testable import Type4Me

final class MiMoASRProtocolTests: XCTestCase {

    func testBuildRequest_usesCorrectEndpointAndHeaders() throws {
        let config = try XCTUnwrap(MiMoASRConfig(credentials: [
            "apiKey": "test-mimo-key",
            "language": "zh",
        ]))
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let wav = WAVEncoder.encode(pcmData: pcm)

        let request = try MiMoASRProtocol.buildRequest(
            wavData: wav,
            config: config,
            options: ASRRequestOptions(
                enablePunc: true,
                hotwords: ["Type4Me", "小米"],
                boostingTableID: "test-table"
            )
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.xiaomimimo.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "test-mimo-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(root["model"] as? String, "mimo-v2.5-asr")
        XCTAssertEqual(root["stream"] as? Bool, true)

        // Hotwords and punc are NOT mapped to the request body
        XCTAssertNil(root["hotwords"])
        XCTAssertNil(root["enable_punc"])
        XCTAssertNil(root["boosting_table_id"])

        let asrOptions = try XCTUnwrap(root["asr_options"] as? [String: Any])
        XCTAssertEqual(asrOptions["language"] as? String, "zh")

        let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")

        let contentList = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(contentList.count, 1)
        XCTAssertEqual(contentList[0]["type"] as? String, "input_audio")

        let inputAudio = try XCTUnwrap(contentList[0]["input_audio"] as? [String: Any])
        let dataURL = try XCTUnwrap(inputAudio["data"] as? String)
        XCTAssertTrue(dataURL.hasPrefix("data:audio/wav;base64,"))

        let base64Part = String(dataURL.dropFirst("data:audio/wav;base64,".count))
        let decodedData = try XCTUnwrap(Data(base64Encoded: base64Part))
        XCTAssertEqual(decodedData, wav)
    }

    func testBuildRequest_throwsWhenAudioExceedsLimit() throws {
        let config = try XCTUnwrap(MiMoASRConfig(credentials: [
            "apiKey": "key",
        ]))
        // 8MB binary payload will expand to ~10.6MB Base64, exceeding 10MB limit
        let hugeData = Data(repeating: 0x41, count: 8 * 1024 * 1024)

        XCTAssertThrowsError(
            try MiMoASRProtocol.buildRequest(wavData: hugeData, config: config)
        ) { error in
            guard case MiMoASRError.audioTooLarge(let encodedBytes) = error else {
                XCTFail("Expected audioTooLarge error, got \(error)")
                return
            }
            XCTAssertGreaterThan(encodedBytes, 10 * 1024 * 1024)
        }
    }

    func testParseSSELine_parsesDeltaEvent() throws {
        let json = #"{"choices":[{"delta":{"content":"你好"},"finish_reason":null}]}"#
        let event = try MiMoASRProtocol.parseSSELine("data: \(json)")

        XCTAssertEqual(event, .delta("你好"))
    }

    func testParseSSELine_parsesFinishReasonStop() throws {
        let json = #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
        let event = try MiMoASRProtocol.parseSSELine("data: \(json)")

        XCTAssertEqual(event, .done)
    }

    func testParseSSELine_parsesFinishReasonLengthAsError() throws {
        let json = #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#
        let event = try MiMoASRProtocol.parseSSELine("data: \(json)")

        XCTAssertEqual(event, .error(L("识别结果超出最大生成长度", "Recognition output exceeded maximum token length")))
    }

    func testParseSSELine_parsesFinishReasonContentFilterAsError() throws {
        let json = #"{"choices":[{"delta":{},"finish_reason":"content_filter"}]}"#
        let event = try MiMoASRProtocol.parseSSELine("data: \(json)")

        XCTAssertEqual(event, .error(L("识别内容已被安全策略过滤", "Recognition content was filtered by safety policy")))
    }

    func testParseSSELine_ignoresDoneSentinelAsFraming() throws {
        let event = try MiMoASRProtocol.parseSSELine("data: [DONE]")
        XCTAssertNil(event)
    }

    func testParseSSELine_parsesServerError() throws {
        let json = #"{"error":{"message":"API key invalid","type":"invalid_request_error","code":"invalid_api_key"}}"#
        let event = try MiMoASRProtocol.parseSSELine("data: \(json)")

        XCTAssertEqual(event, .error("API key invalid"))
    }

    func testParseSSELine_ignoresMetadataAndEmptyLines() throws {
        XCTAssertNil(try MiMoASRProtocol.parseSSELine(""))
        XCTAssertNil(try MiMoASRProtocol.parseSSELine(": ping"))
        XCTAssertNil(try MiMoASRProtocol.parseSSELine("event: message"))
        XCTAssertNil(try MiMoASRProtocol.parseSSELine("data: "))
    }

    func testParseSSELine_throwsOnMalformedJSON() {
        XCTAssertThrowsError(
            try MiMoASRProtocol.parseSSELine("data: {invalid json}")
        ) { error in
            XCTAssertEqual(error as? MiMoASRError, .invalidResponse)
        }
    }
}
