import XCTest
@testable import Type4Me

final class StepFunBatchASRProtocolTests: XCTestCase {

    func testBuildRequest_usesStepPlanEndpointAndPCMBody() throws {
        let config = try XCTUnwrap(StepFunASRConfig(credentials: [
            "recognitionMode": "batch",
            "accessMode": "stepPlan",
            "apiKey": "sk-standard-test",
            "stepPlanApiKey": "sk-stepfun-test",
        ]))
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let request = try StepFunBatchASRProtocol.buildRequest(
            pcmData: pcm,
            config: config,
            options: ASRRequestOptions(hotwords: ["Type4Me", "阶跃星辰"])
        )

        XCTAssertEqual(request.url?.absoluteString, StepFunBatchAccessMode.stepPlanEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-stepfun-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        let audio = try XCTUnwrap(root["audio"] as? [String: Any])
        XCTAssertEqual(audio["data"] as? String, pcm.base64EncodedString())

        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "stepaudio-2.5-asr")
        XCTAssertEqual(transcription["enable_itn"] as? Bool, true)
        XCTAssertEqual(transcription["hotwords"] as? [String], ["Type4Me", "阶跃星辰"])
        XCTAssertNil(transcription["language"])

        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "pcm")
        XCTAssertEqual(format["codec"] as? String, "pcm_s16le")
        XCTAssertEqual(format["rate"] as? Int, 16_000)
        XCTAssertEqual(format["bits"] as? Int, 16)
        XCTAssertEqual(format["channel"] as? Int, 1)
    }

    func testBuildRequest_usesStandardEndpointWhenSelected() throws {
        let config = try XCTUnwrap(StepFunASRConfig(credentials: [
            "recognitionMode": "batch",
            "apiKey": "sk-stepfun-test",
            "accessMode": "standard",
        ]))
        let request = try StepFunBatchASRProtocol.buildRequest(
            pcmData: Data([0x00]),
            config: config,
            options: ASRRequestOptions()
        )

        XCTAssertEqual(request.url?.absoluteString, StepFunBatchAccessMode.standardEndpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-stepfun-test")
    }

    func testBuildRequest_omitsEmptyHotwordList() throws {
        let config = try XCTUnwrap(StepFunASRConfig(credentials: [
            "recognitionMode": "batch",
            "apiKey": "sk-stepfun-test",
        ]))
        let request = try StepFunBatchASRProtocol.buildRequest(
            pcmData: Data([0x00]),
            config: config,
            options: ASRRequestOptions()
        )

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        let audio = try XCTUnwrap(root["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertNil(transcription["hotwords"])
    }

    func testParseSSELine_decodesDeltaAndDoneEvents() throws {
        let delta = try StepFunBatchASRProtocol.parseSSELine(
            #"data: {"type":"transcript.text.delta","delta":"你好"}"#
        )
        let done = try StepFunBatchASRProtocol.parseSSELine(
            #"data:{"type":"transcript.text.done","text":"你好，Type4Me。"}"#
        )

        XCTAssertEqual(delta, .delta("你好"))
        XCTAssertEqual(done, .done("你好，Type4Me。"))
    }

    func testParseSSELine_decodesTopLevelAndNestedErrors() throws {
        XCTAssertEqual(
            try StepFunBatchASRProtocol.parseSSELine(
                #"data: {"type":"error","message":"invalid api key"}"#
            ),
            .error("invalid api key")
        )
        XCTAssertEqual(
            try StepFunBatchASRProtocol.parseSSELine(
                #"data: {"type":"error","error":{"message":"quota exceeded"}}"#
            ),
            .error("quota exceeded")
        )
    }

    func testParseSSELine_ignoresSSEMetadataAndUnknownEvents() throws {
        XCTAssertNil(try StepFunBatchASRProtocol.parseSSELine("event: transcript"))
        XCTAssertNil(try StepFunBatchASRProtocol.parseSSELine(""))
        XCTAssertNil(try StepFunBatchASRProtocol.parseSSELine("data: [DONE]"))
        XCTAssertNil(try StepFunBatchASRProtocol.parseSSELine(
            #"data: {"type":"session.created"}"#
        ))
    }

    func testParseSSELine_rejectsMalformedPayload() {
        XCTAssertThrowsError(
            try StepFunBatchASRProtocol.parseSSELine("data: not-json")
        ) { error in
            XCTAssertEqual(error as? StepFunBatchASRError, .invalidResponse)
        }
    }
}
