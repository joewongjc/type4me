import XCTest
@testable import Type4Me

final class AssemblyAIProtocolTests: XCTestCase {

    func testBuildWebSocketURL_usesExpectedQueryItemsForUniversalStreaming() throws {
        let config = try XCTUnwrap(AssemblyAIASRConfig(credentials: [
            "apiKey": "aa_test_key",
            "model": "universal-streaming-multilingual",
        ]))

        let url = try AssemblyAIProtocol.buildWebSocketURL(
            config: config,
            options: ASRRequestOptions(
                enablePunc: true,
                hotwords: [" Type4Me ", String(repeating: "a", count: 70), "keep-me"],
                boostingTableID: "ignored"
            )
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "streaming.assemblyai.com")
        XCTAssertEqual(components.path, "/v3/ws")
        XCTAssertEqual(items.value(for: "sample_rate"), "16000")
        XCTAssertEqual(items.value(for: "encoding"), "pcm_s16le")
        XCTAssertEqual(items.value(for: "speech_model"), "universal-streaming-multilingual")
        XCTAssertEqual(items.value(for: "format_turns"), "true")
        XCTAssertNil(items.value(for: "keyterms_prompt"))

        let hotwords = [" Type4Me ", String(repeating: "a", count: 70), "keep-me"]
        let updateJSON = try XCTUnwrap(AssemblyAIProtocol.updateConfigurationMessage(hotwords: hotwords))
        let updateObj = try JSONSerialization.jsonObject(with: Data(updateJSON.utf8)) as? [String: Any]
        XCTAssertEqual(updateObj?["type"] as? String, "UpdateConfiguration")
        let terms = try XCTUnwrap(updateObj?["keyterms_prompt"] as? [String])
        XCTAssertEqual(terms, ["Type4Me", String(repeating: "a", count: 50), "keep-me"])
    }

    func testBuildWebSocketURL_omitsFormatTurnsForU3() throws {
        let config = try XCTUnwrap(AssemblyAIASRConfig(credentials: [
            "apiKey": "aa_test_key",
            "model": "u3-rt-pro",
        ]))

        let url = try AssemblyAIProtocol.buildWebSocketURL(
            config: config,
            options: ASRRequestOptions(enablePunc: false, hotwords: ["alpha"])
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []

        XCTAssertNil(items.value(for: "format_turns"))
        XCTAssertNil(items.value(for: "keyterms_prompt"))

        let u3Update = try XCTUnwrap(AssemblyAIProtocol.updateConfigurationMessage(hotwords: ["alpha"]))
        let u3Obj = try JSONSerialization.jsonObject(with: Data(u3Update.utf8)) as? [String: Any]
        XCTAssertEqual(u3Obj?["keyterms_prompt"] as? [String], ["alpha"])
    }

    func testParseServerEvent_parsesBegin() throws {
        let message = """
        {
          "type": "Begin",
          "id": "session-123",
          "expires_at": 1759796682
        }
        """

        let event = try XCTUnwrap(AssemblyAIProtocol.parseServerEvent(from: Data(message.utf8)))
        XCTAssertEqual(event, .begin(id: "session-123", expiresAt: 1759796682))
    }

    func testParseServerEvent_buildsPartialTranscriptForUniversalStreaming() throws {
        let message = """
        {
          "type": "Turn",
          "turn_order": 0,
          "turn_is_formatted": true,
          "end_of_turn": false,
          "transcript": "Hello",
          "words": [
            { "text": "Hello", "word_is_final": true },
            { "text": "world", "word_is_final": false }
          ]
        }
        """

        let event = try XCTUnwrap(AssemblyAIProtocol.parseServerEvent(from: Data(message.utf8)))
        guard case .turn(let update) = event else {
            return XCTFail("Expected turn event")
        }

        XCTAssertEqual(update.turnOrder, 0)
        XCTAssertEqual(update.finalizedText, "Hello")
        XCTAssertEqual(update.displayText, "Hello world")
        XCTAssertFalse(update.isFinal)
        XCTAssertTrue(update.isFormatted)
    }

    func testParseServerEvent_buildsFinalTranscript() throws {
        let message = """
        {
          "type": "Turn",
          "turn_order": 0,
          "turn_is_formatted": true,
          "end_of_turn": true,
          "transcript": "Hello world.",
          "words": [
            { "text": "Hello", "word_is_final": true },
            { "text": "world.", "word_is_final": true }
          ]
        }
        """

        let event = try XCTUnwrap(AssemblyAIProtocol.parseServerEvent(from: Data(message.utf8)))
        guard case .turn(let update) = event else {
            return XCTFail("Expected turn event")
        }

        XCTAssertEqual(update.finalizedText, "Hello world.")
        XCTAssertEqual(update.displayText, "Hello world.")
        XCTAssertTrue(update.isFinal)
    }

    func testParseServerEvent_supportsU3StylePartialWithoutFinalWords() throws {
        let message = """
        {
          "type": "Turn",
          "turn_order": 2,
          "turn_is_formatted": false,
          "end_of_turn": false,
          "transcript": "Its 8888-8888",
          "words": [
            { "text": "Its", "word_is_final": false },
            { "text": "8888-8888", "word_is_final": false }
          ]
        }
        """

        let event = try XCTUnwrap(AssemblyAIProtocol.parseServerEvent(from: Data(message.utf8)))
        guard case .turn(let update) = event else {
            return XCTFail("Expected turn event")
        }

        XCTAssertEqual(update.finalizedText, "")
        XCTAssertEqual(update.displayText, "Its 8888-8888")
        XCTAssertFalse(update.isFinal)
    }

    func testParseServerEvent_parsesTermination() throws {
        let message = """
        {
          "type": "Termination",
          "audio_duration_seconds": 3.2
        }
        """

        let event = try XCTUnwrap(AssemblyAIProtocol.parseServerEvent(from: Data(message.utf8)))
        XCTAssertEqual(event, .termination(audioDurationSeconds: 3.2))
    }

    func testParseServerEvent_throwsForInvalidJSON() {
        XCTAssertThrowsError(
            try AssemblyAIProtocol.parseServerEvent(from: Data("{".utf8))
        )
    }

    func testMakeCloseError_mapsCommonCodes() {
        let unauthorized = AssemblyAIProtocol.makeCloseError(code: 1008, reason: "Missing Authorization header")
        let cancelled = AssemblyAIProtocol.makeCloseError(code: 3005, reason: "An error occurred")
        let generic = AssemblyAIProtocol.makeCloseError(code: 3007, reason: "Input duration violation")

        XCTAssertEqual(
            unauthorized.errorDescription,
            "AssemblyAI unauthorized connection: Missing Authorization header"
        )
        XCTAssertEqual(
            cancelled.errorDescription,
            "AssemblyAI session cancelled: An error occurred"
        )
        XCTAssertEqual(
            generic.errorDescription,
            "AssemblyAI session closed (3007): Input duration violation"
        )
    }

    func testTurnUpdates_canModelFormattedOverwriteForSameTurn() throws {
        let partial = try XCTUnwrap(
            AssemblyAIProtocol.makeTurnUpdate(
                from: .init(
                    type: "Turn",
                    turnOrder: 0,
                    turnIsFormatted: false,
                    endOfTurn: true,
                    transcript: "hello world",
                    words: [
                        .init(text: "hello", wordIsFinal: true),
                        .init(text: "world", wordIsFinal: true),
                    ]
                )
            )
        )
        let formatted = try XCTUnwrap(
            AssemblyAIProtocol.makeTurnUpdate(
                from: .init(
                    type: "Turn",
                    turnOrder: 0,
                    turnIsFormatted: true,
                    endOfTurn: true,
                    transcript: "Hello world.",
                    words: [
                        .init(text: "Hello", wordIsFinal: true),
                        .init(text: "world.", wordIsFinal: true),
                    ]
                )
            )
        )

        XCTAssertEqual(partial.displayText, "hello world")
        XCTAssertEqual(formatted.displayText, "Hello world.")
    }
}

private extension [URLQueryItem] {
    func value(for name: String) -> String? {
        first(where: { $0.name == name })?.value
    }
}
