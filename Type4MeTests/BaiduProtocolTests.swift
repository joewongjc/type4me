import XCTest
@testable import Type4Me

final class BaiduProtocolTests: XCTestCase {

    func testBuildWebSocketURL_addsRequiredSNQueryItem() throws {
        let url = BaiduProtocol.buildWebSocketURL(requestID: "request-123")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "vop.baidu.com")
        XCTAssertEqual(components.path, "/realtime_asr")
        XCTAssertEqual(components.queryItems?.first?.name, "sn")
        XCTAssertEqual(components.queryItems?.first?.value, "request-123")
    }

    func testBuildStartMessage_usesExpectedParameters() throws {
        let config = try XCTUnwrap(BaiduASRConfig(credentials: [
            "appID": "123456",
            "apiKey": "baidu_test_key",
            "devPID": "15372",
            "cuid": "device-123",
            "lmId": "model-001",
        ]))

        let message = BaiduProtocol.buildStartMessage(
            config: config,
            options: ASRRequestOptions(enablePunc: true)
        )
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )

        XCTAssertEqual(json["type"] as? String, "START")
        let data = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(data["appid"] as? Int, 123456)
        XCTAssertEqual(data["appkey"] as? String, "baidu_test_key")
        XCTAssertEqual(data["dev_pid"] as? Int, 15372)
        XCTAssertEqual(data["cuid"] as? String, "device-123")
        XCTAssertEqual(data["format"] as? String, "pcm")
        XCTAssertEqual(data["sample"] as? Int, 16000)
        XCTAssertEqual(data["lm_id"] as? String, "model-001")
    }

    func testBuildStartMessage_disablesPunctuationForKnownDevPIDPairs() throws {
        let config = try XCTUnwrap(BaiduASRConfig(credentials: [
            "appID": "123456",
            "apiKey": "baidu_test_key",
            "devPID": "15372",
        ]))

        let message = BaiduProtocol.buildStartMessage(
            config: config,
            options: ASRRequestOptions(enablePunc: false)
        )
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )
        let data = try XCTUnwrap(json["data"] as? [String: Any])

        XCTAssertEqual(data["dev_pid"] as? Int, 1537)
    }

    func testBuildFinishMessage_matchesDocumentation() throws {
        let message = BaiduProtocol.buildFinishMessage()
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )

        XCTAssertEqual(json["type"] as? String, "FINISH")
        XCTAssertEqual(json.count, 1)
    }

    func testParseServerEvent_buildsPartialTranscript() throws {
        let message = """
        {
          "type": "MID_TEXT",
          "result": "world",
          "err_no": 0,
          "err_msg": "success."
        }
        """

        let event = try XCTUnwrap(
            BaiduProtocol.parseServerEvent(
                from: Data(message.utf8),
                confirmedSegments: ["Hello"]
            )
        )

        guard case .transcript(let update) = event else {
            return XCTFail("Expected transcript event")
        }

        XCTAssertEqual(update.confirmedSegments, ["Hello"])
        XCTAssertEqual(update.transcript.partialText, " world")
        XCTAssertEqual(update.transcript.authoritativeText, "Hello world")
        XCTAssertFalse(update.transcript.isFinal)
    }

    func testParseServerEvent_promotesFinalResultsToConfirmedSegments() throws {
        let message = """
        {
          "type": "FIN_TEXT",
          "result": "world",
          "err_no": 0,
          "err_msg": "success."
        }
        """

        let event = try XCTUnwrap(
            BaiduProtocol.parseServerEvent(
                from: Data(message.utf8),
                confirmedSegments: ["Hello"]
            )
        )

        guard case .transcript(let update) = event else {
            return XCTFail("Expected transcript event")
        }

        XCTAssertEqual(update.confirmedSegments, ["Hello", " world"])
        XCTAssertEqual(update.transcript.partialText, "")
        XCTAssertEqual(update.transcript.authoritativeText, "Hello world")
        XCTAssertTrue(update.transcript.isFinal)
    }

    func testParseServerEvent_sentenceFailureClearsPartialText() throws {
        let message = """
        {
          "type": "FIN_TEXT",
          "result": "",
          "err_no": 3301,
          "err_msg": "Audio quality error."
        }
        """

        let event = try XCTUnwrap(
            BaiduProtocol.parseServerEvent(
                from: Data(message.utf8),
                confirmedSegments: ["Hello"]
            )
        )

        guard case .sentenceFailed(let code, let errorMessage, let update) = event else {
            return XCTFail("Expected sentenceFailed event")
        }

        XCTAssertEqual(code, 3301)
        XCTAssertEqual(errorMessage, "Audio quality error.")
        XCTAssertEqual(update.confirmedSegments, ["Hello"])
        XCTAssertEqual(update.transcript.partialText, "")
        XCTAssertEqual(update.transcript.authoritativeText, "Hello")
        XCTAssertTrue(update.transcript.isFinal)
    }

    func testParseServerEvent_mapsServerErrors() throws {
        let message = """
        {
          "type": "ERROR",
          "err_no": 3302,
          "err_msg": "Authentication failed."
        }
        """

        let event = try XCTUnwrap(
            BaiduProtocol.parseServerEvent(
                from: Data(message.utf8),
                confirmedSegments: []
            )
        )

        XCTAssertEqual(
            event,
            .serverError(code: 3302, message: "Authentication failed.")
        )
    }

    func testParseServerEvent_ignoresHeartbeatMessages() throws {
        let message = """
        {
          "type": "HEARTBEAT"
        }
        """

        let event = try BaiduProtocol.parseServerEvent(
            from: Data(message.utf8),
            confirmedSegments: []
        )

        XCTAssertNil(event)
    }
}
