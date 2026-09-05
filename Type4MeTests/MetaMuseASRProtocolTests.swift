import XCTest
@testable import Type4Me

final class MetaMuseASRProtocolTests: XCTestCase {

    func testBuildWebSocketURL_defaultAndOverride() throws {
        let defaultURL = try MetaMuseASRProtocol.buildWebSocketURL()
        XCTAssertEqual(defaultURL.absoluteString, "wss://api.meta.ai/v1/asr/realtime")

        let overrideURL = try MetaMuseASRProtocol.buildWebSocketURL(override: "wss://custom.proxy/meta/asr")
        XCTAssertEqual(overrideURL.absoluteString, "wss://custom.proxy/meta/asr")
    }

    func testBuildWebSocketURL_appendsSessionId() throws {
        let url = try MetaMuseASRProtocol.buildWebSocketURL(sessionId: "sess_12345")
        XCTAssertEqual(url.absoluteString, "wss://api.meta.ai/v1/asr/realtime?sessionId=sess_12345")
    }

    func testSanitizedKeywords_deduplicatesAndLimits() {
        let hotwords = [
            "  Type4Me  ",
            "Type4Me",
            "",
            "   ",
            "Swift 6",
            "macOS",
        ]
        let sanitized = MetaMuseASRProtocol.sanitizedKeywords(from: hotwords)
        XCTAssertEqual(sanitized, ["Type4Me", "Swift 6", "macOS"])

        let longWord = String(repeating: "a", count: 150)
        let capped = MetaMuseASRProtocol.sanitizedKeywords(from: [longWord], maxLength: 50)
        XCTAssertEqual(capped.first?.count, 50)

        let manyWords = (0..<120).map { "term_\($0)" }
        let limited = MetaMuseASRProtocol.sanitizedKeywords(from: manyWords, maxCount: 100)
        XCTAssertEqual(limited.count, 100)
    }

    func testBuildHandshakeMessage_constructsValidPayload() throws {
        let config = try XCTUnwrap(MetaMuseASRConfig(credentials: [
            "apiKey": "test_api_key_abc",
            "languageBias": "Chinese",
        ]))
        let options = ASRRequestOptions(hotwords: ["Type4Me", "Gemini"])
        let jsonString = try MetaMuseASRProtocol.buildHandshakeMessage(config: config, options: options)
        let data = try XCTUnwrap(jsonString.data(using: .utf8))
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let auth = try XCTUnwrap(dict["authorization"] as? [String: Any])
        XCTAssertEqual(auth["accessToken"] as? String, "Bearer test_api_key_abc")
        XCTAssertEqual(dict["audioEncoding"] as? String, "PCM_16KHZ")
        XCTAssertEqual(dict["model"] as? String, "muse-voice-transcribe-1.0")
        XCTAssertEqual(dict["mode"] as? String, "PUSH_TO_TALK")
        XCTAssertEqual(dict["keywords"] as? [String], ["Type4Me", "Gemini"])
        XCTAssertEqual(dict["languageBias"] as? [String], ["Chinese"])
    }

    func testBuildHandshakeMessage_omitsKeywordsAndLanguageWhenEmpty() throws {
        let config = try XCTUnwrap(MetaMuseASRConfig(credentials: [
            "apiKey": "test_key",
        ]))
        let options = ASRRequestOptions(hotwords: [])
        let jsonString = try MetaMuseASRProtocol.buildHandshakeMessage(config: config, options: options)
        let data = try XCTUnwrap(jsonString.data(using: .utf8))
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(dict["keywords"])
        XCTAssertNil(dict["languageBias"])
        XCTAssertEqual(dict["audioEncoding"] as? String, "PCM_16KHZ")
    }

    func testBuildEndStreamMessage() {
        let msg = MetaMuseASRProtocol.buildEndStreamMessage()
        XCTAssertEqual(msg, #"{"type":"endStream"}"#)
    }

    func testParseServerEvent_handshakeResponseWithoutType() throws {
        let json = #"{"sessionId":"session_abc_123"}"#
        let event = try MetaMuseASRProtocol.parseServerEvent(from: Data(json.utf8))
        XCTAssertEqual(event, .sessionReady(sessionId: "session_abc_123"))

        let snakeJson = #"{"session_id":"session_snake_456"}"#
        let snakeEvent = try MetaMuseASRProtocol.parseServerEvent(from: Data(snakeJson.utf8))
        XCTAssertEqual(snakeEvent, .sessionReady(sessionId: "session_snake_456"))
    }

    func testParseServerEvent_transcriptPartialAndFinal() throws {
        let partialJson = """
        {
            "type": "transcript",
            "transcript": "Hello world",
            "final": false,
            "audioProcessedMs": 800
        }
        """
        let partialEvent = try MetaMuseASRProtocol.parseServerEvent(from: Data(partialJson.utf8))
        XCTAssertEqual(partialEvent, .transcript(text: "Hello world", isFinal: false, audioProcessedMs: 800))

        let finalJson = """
        {
            "type": "transcript",
            "transcript": "Hello world from Meta Muse.",
            "final": true,
            "audioProcessedMs": 1500
        }
        """
        let finalEvent = try MetaMuseASRProtocol.parseServerEvent(from: Data(finalJson.utf8))
        XCTAssertEqual(finalEvent, .transcript(text: "Hello world from Meta Muse.", isFinal: true, audioProcessedMs: 1500))
    }

    func testParseServerEvent_errorMapping() throws {
        let authErrorJson = #"{"type":"error","message":"Invalid API key provided"}"#
        let authEvent = try MetaMuseASRProtocol.parseServerEvent(from: Data(authErrorJson.utf8))
        XCTAssertEqual(authEvent, .error(.authenticationFailed("Invalid API key provided")))

        let rateLimitJson = #"{"type":"error","message":"Rate limit exceeded: 429 too many requests"}"#
        let rateEvent = try MetaMuseASRProtocol.parseServerEvent(from: Data(rateLimitJson.utf8))
        XCTAssertEqual(rateEvent, .error(.rateLimited("Rate limit exceeded: 429 too many requests")))

        let genericJson = #"{"type":"error","message":"Internal inference error"}"#
        let genericEvent = try MetaMuseASRProtocol.parseServerEvent(from: Data(genericJson.utf8))
        XCTAssertEqual(genericEvent, .error(.serverError(message: "Internal inference error")))
    }

    func testParseServerEvent_ignoredMetadata() throws {
        let speakerJson = #"{"type":"speaker","speakerId":"speaker_1","startMs":0,"endMs":500}"#
        let speakerEvent = try MetaMuseASRProtocol.parseServerEvent(from: Data(speakerJson.utf8))
        XCTAssertEqual(speakerEvent, .ignored(type: "speaker"))

        let progressJson = #"{"type":"progress","percent":50}"#
        let progressEvent = try MetaMuseASRProtocol.parseServerEvent(from: Data(progressJson.utf8))
        XCTAssertEqual(progressEvent, .ignored(type: "progress"))
    }

    func testParseServerEvent_invalidDataThrows() {
        let invalidJson = "not a valid json"
        XCTAssertThrowsError(try MetaMuseASRProtocol.parseServerEvent(from: Data(invalidJson.utf8)))

        let malformedTranscript = #"{"type":"transcript"}"#
        XCTAssertThrowsError(try MetaMuseASRProtocol.parseServerEvent(from: Data(malformedTranscript.utf8)))
    }
}
