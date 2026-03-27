import XCTest
@testable import Type4Me

final class SonioxProtocolTests: XCTestCase {

    func testBuildWebSocketURL_usesExpectedEndpoint() throws {
        let url = try SonioxProtocol.buildWebSocketURL()

        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "stt-rt.soniox.com")
        XCTAssertEqual(url.path, "/transcribe-websocket")
    }

    func testBuildStartMessage_includesPCMConfigAndContextTerms() throws {
        let config = try XCTUnwrap(SonioxASRConfig(credentials: [
            "apiKey": "soniox_test_key",
            "model": "stt-rt-v4",
        ]))

        let message = try SonioxProtocol.buildStartMessage(
            config: config,
            options: ASRRequestOptions(
                hotwords: [" Type4Me ", "soniox", ""],
                boostingTableID: "ignored"
            )
        )
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )

        XCTAssertEqual(payload["api_key"] as? String, "soniox_test_key")
        XCTAssertEqual(payload["model"] as? String, "stt-rt-v4")
        XCTAssertEqual(payload["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(payload["sample_rate"] as? Int, 16000)
        XCTAssertEqual(payload["num_channels"] as? Int, 1)
        XCTAssertEqual(payload["enable_endpoint_detection"] as? Bool, true)

        let context = try XCTUnwrap(payload["context"] as? [String: Any])
        let terms = try XCTUnwrap(context["terms"] as? [String])
        XCTAssertEqual(terms, ["Type4Me", "soniox"])
    }

    func testFinalizeMessage_canIncludeTrailingSilence() throws {
        let message = SonioxProtocol.finalizeMessage(trailingSilenceMs: 300)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )

        XCTAssertEqual(payload["type"] as? String, "finalize")
        XCTAssertEqual(payload["trailing_silence_ms"] as? Int, 300)
    }

    func testParseServerEvent_buildsTranscriptUpdateAndIgnoresMarkers() throws {
        let message = """
        {
          "tokens": [
            { "text": "Hello", "is_final": true },
            { "text": " ", "is_final": true },
            { "text": "world", "is_final": true },
            { "text": "<end>", "is_final": true },
            { "text": " ", "is_final": false },
            { "text": "aga", "is_final": false },
            { "text": "in", "is_final": false }
          ],
          "final_audio_proc_ms": 1100,
          "total_audio_proc_ms": 1450
        }
        """

        let event = try XCTUnwrap(SonioxProtocol.parseServerEvent(from: Data(message.utf8)))
        guard case .transcript(let update) = event else {
            return XCTFail("Expected transcript event")
        }

        XCTAssertEqual(update.finalizedText, "Hello world")
        XCTAssertEqual(update.partialText, " again")
    }

    func testParseServerEvent_parsesFinishedResponse() throws {
        let message = """
        {
          "tokens": [],
          "final_audio_proc_ms": 1560,
          "total_audio_proc_ms": 1680,
          "finished": true
        }
        """

        let event = try XCTUnwrap(SonioxProtocol.parseServerEvent(from: Data(message.utf8)))
        XCTAssertEqual(event, .finished)
    }

    func testParseServerEvent_prefersTranscriptOverFinishedWhenFinalTokensPresent() throws {
        let message = """
        {
          "tokens": [
            { "text": "done", "is_final": true }
          ],
          "finished": true
        }
        """

        let event = try XCTUnwrap(SonioxProtocol.parseServerEvent(from: Data(message.utf8)))
        XCTAssertEqual(event, .transcript(.init(finalizedText: "done", partialText: "")))
    }

    func testParseServerEvent_parsesErrorResponse() throws {
        let message = """
        {
          "tokens": [],
          "error_code": 401,
          "error_message": "Invalid API key."
        }
        """

        let event = try XCTUnwrap(SonioxProtocol.parseServerEvent(from: Data(message.utf8)))
        XCTAssertEqual(event, .error(code: 401, message: "Invalid API key."))
    }

    func testParseServerEvent_throwsForInvalidJSON() {
        XCTAssertThrowsError(
            try SonioxProtocol.parseServerEvent(from: Data("{".utf8))
        )
    }
}
