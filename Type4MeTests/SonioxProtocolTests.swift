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

        // Language hints
        let hints = try XCTUnwrap(payload["language_hints"] as? [String])
        XCTAssertEqual(hints, ["zh", "en"])
        XCTAssertEqual(payload["language_hints_strict"] as? Bool, true)

        let context = try XCTUnwrap(payload["context"] as? [String: Any])
        let terms = try XCTUnwrap(context["terms"] as? [String])
        XCTAssertEqual(terms, ["Type4Me", "soniox"])
    }

    func testParseServerMessage_buildsTranscriptUpdateAndIgnoresMarkers() throws {
        let json = """
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

        let result = try SonioxProtocol.parseServerMessage(from: Data(json.utf8))

        XCTAssertEqual(result.transcript?.finalizedText, "Hello world")
        XCTAssertEqual(result.transcript?.partialText, " again")
        XCTAssertFalse(result.isFinished)
        XCTAssertNil(result.error)
    }

    func testParseServerMessage_parsesFinishedResponse() throws {
        let json = """
        {
          "tokens": [],
          "final_audio_proc_ms": 1560,
          "total_audio_proc_ms": 1680,
          "finished": true
        }
        """

        let result = try SonioxProtocol.parseServerMessage(from: Data(json.utf8))

        XCTAssertNil(result.transcript)
        XCTAssertTrue(result.isFinished)
        XCTAssertNil(result.error)
    }

    func testParseServerMessage_returnsTranscriptAndFinishedTogether() throws {
        let json = """
        {
          "tokens": [
            { "text": "done", "is_final": true }
          ],
          "finished": true
        }
        """

        let result = try SonioxProtocol.parseServerMessage(from: Data(json.utf8))

        XCTAssertEqual(result.transcript?.finalizedText, "done")
        XCTAssertEqual(result.transcript?.partialText, "")
        XCTAssertTrue(result.isFinished)
        XCTAssertNil(result.error)
    }

    func testParseServerMessage_parsesErrorResponse() throws {
        let json = """
        {
          "tokens": [],
          "error_code": 401,
          "error_message": "Invalid API key."
        }
        """

        let result = try SonioxProtocol.parseServerMessage(from: Data(json.utf8))

        XCTAssertNil(result.transcript)
        XCTAssertFalse(result.isFinished)
        XCTAssertEqual(result.error, SonioxServerError(code: 401, message: "Invalid API key."))
    }

    func testParseServerMessage_throwsForInvalidJSON() {
        XCTAssertThrowsError(
            try SonioxProtocol.parseServerMessage(from: Data("{".utf8))
        )
    }
}
