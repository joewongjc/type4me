import XCTest
@testable import Type4Me

final class BailianProtocolTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "tf_asrUID")
        super.tearDown()
    }

    func testBuildRunTaskMessage_usesExpectedParameters() throws {
        let config = try XCTUnwrap(BailianASRConfig(credentials: [
            "apiKey": "sk-test-key",
            "model": "fun-asr-realtime",
            "deviceId": "device-123",
            "languageHint": "zh",
            "vocabularyId": "vocab-from-config",
        ]))

        let message = BailianProtocol.buildRunTaskMessage(
            config: config,
            options: ASRRequestOptions(
                enablePunc: true,
                hotwords: ["Type4Me"],
                boostingTableID: "vocab-from-options",
                contextHistoryLength: 8
            ),
            taskID: "task-123"
        )
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )

        let header = try XCTUnwrap(json["header"] as? [String: Any])
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])

        XCTAssertEqual(header["action"] as? String, "run-task")
        XCTAssertEqual(header["task_id"] as? String, "task-123")
        XCTAssertEqual(header["streaming"] as? String, "duplex")
        XCTAssertEqual(payload["task_group"] as? String, "audio")
        XCTAssertEqual(payload["task"] as? String, "asr")
        XCTAssertEqual(payload["function"] as? String, "recognition")
        XCTAssertEqual(payload["model"] as? String, "fun-asr-realtime")
        XCTAssertEqual(parameters["format"] as? String, "pcm")
        XCTAssertEqual(parameters["sample_rate"] as? Int, 16000)
        XCTAssertEqual(parameters["semantic_punctuation_enabled"] as? Bool, false)
        XCTAssertEqual(parameters["max_sentence_silence"] as? Int, 800)
        XCTAssertEqual(parameters["multi_threshold_mode_enabled"] as? Bool, false)
        XCTAssertEqual(parameters["heartbeat"] as? Bool, false)
        XCTAssertEqual(parameters["vocabulary_id"] as? String, "vocab-from-options")
        XCTAssertEqual(parameters["language_hints"] as? [String], ["zh"])
    }

    func testBuildRunTaskMessage_omitsEmptyLanguageHints() throws {
        let config = try XCTUnwrap(BailianASRConfig(credentials: [
            "apiKey": "sk-test-key",
            "deviceId": "device-123",
        ]))

        let message = BailianProtocol.buildRunTaskMessage(
            config: config,
            options: ASRRequestOptions(),
            taskID: "task-123"
        )
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])

        XCTAssertNil(parameters["language_hints"])
        XCTAssertNil(parameters["vocabulary_id"])
    }

    func testParseServerEvent_buildsPartialTranscript() throws {
        let message = """
        {
          "header": {
            "task_id": "task-123",
            "event": "result-generated",
            "attributes": {}
          },
          "payload": {
            "output": {
              "sentence": {
                "text": "world",
                "heartbeat": false,
                "sentence_end": false
              }
            }
          }
        }
        """

        let event = try XCTUnwrap(
            BailianProtocol.parseServerEvent(
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

    func testParseServerEvent_promotesSentenceEndToConfirmedSegments() throws {
        let message = """
        {
          "header": {
            "task_id": "task-123",
            "event": "result-generated",
            "attributes": {}
          },
          "payload": {
            "output": {
              "sentence": {
                "text": "world",
                "heartbeat": false,
                "sentence_end": true
              }
            }
          }
        }
        """

        let event = try XCTUnwrap(
            BailianProtocol.parseServerEvent(
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

    func testParseServerEvent_ignoresHeartbeatResults() throws {
        let message = """
        {
          "header": {
            "task_id": "task-123",
            "event": "result-generated",
            "attributes": {}
          },
          "payload": {
            "output": {
              "sentence": {
                "text": "",
                "heartbeat": true,
                "sentence_end": false
              }
            }
          }
        }
        """

        let event = try BailianProtocol.parseServerEvent(
            from: Data(message.utf8),
            confirmedSegments: []
        )

        XCTAssertNil(event)
    }

    func testParseServerEvent_mapsTaskFailed() throws {
        let message = """
        {
          "header": {
            "task_id": "task-123",
            "event": "task-failed",
            "error_code": "CLIENT_ERROR",
            "error_message": "request timeout"
          },
          "payload": {}
        }
        """

        let event = try XCTUnwrap(
            BailianProtocol.parseServerEvent(
                from: Data(message.utf8),
                confirmedSegments: []
            )
        )

        XCTAssertEqual(
            event,
            .taskFailed(code: "CLIENT_ERROR", message: "request timeout")
        )
    }

    func testParseServerEvent_throwsForInvalidJSON() {
        XCTAssertThrowsError(
            try BailianProtocol.parseServerEvent(
                from: Data("{".utf8),
                confirmedSegments: []
            )
        )
    }
}
