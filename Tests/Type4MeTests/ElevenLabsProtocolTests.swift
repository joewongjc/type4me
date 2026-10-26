import XCTest
@testable import Type4Me

final class ElevenLabsProtocolTests: XCTestCase {

    func testBuildWebSocketURL_includesNoVerbatimAndModel() throws {
        let config = try XCTUnwrap(ElevenLabsASRConfig(credentials: [
            "apiKey": "eleven_test_key",
            "model": "scribe_v2_realtime",
            "language": "en",
        ]))
        let url = try ElevenLabsProtocol.buildWebSocketURL(config: config, options: .init())
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []

        XCTAssertEqual(components.host, "api.elevenlabs.io")
        XCTAssertEqual(components.path, "/v1/speech-to-text/realtime")
        XCTAssertEqual(items.value(for: "model_id"), "scribe_v2_realtime")
        XCTAssertEqual(items.value(for: "audio_format"), "pcm_16000")
        XCTAssertEqual(items.value(for: "no_verbatim"), "true")
        XCTAssertEqual(items.value(for: "language_code"), "en")
    }

    func testMakeTranscriptUpdate_normalizesChinesePunctuationForEnglish() throws {
        let message = """
        {
          "message_type": "committed_transcript",
          "text": "Hello world。"
        }
        """

        let update = try XCTUnwrap(
            ElevenLabsProtocol.makeTranscriptUpdate(
                from: Data(message.utf8),
                confirmedSegments: [],
                isFinalCommit: true,
                languageCode: "en"
            )
        )

        XCTAssertEqual(update.confirmedSegments, ["Hello world."])
        XCTAssertEqual(update.transcript.authoritativeText, "Hello world.")
        XCTAssertTrue(update.transcript.isFinal)
    }

    func testMakeTranscriptUpdate_keepsChinesePunctuationForChinese() throws {
        let message = """
        {
          "message_type": "committed_transcript",
          "text": "你好世界。"
        }
        """

        let update = try XCTUnwrap(
            ElevenLabsProtocol.makeTranscriptUpdate(
                from: Data(message.utf8),
                confirmedSegments: [],
                isFinalCommit: true,
                languageCode: "zh"
            )
        )

        XCTAssertEqual(update.confirmedSegments, ["你好世界。"])
    }

    func testMakeTranscriptUpdate_autoDetectNormalizesLatinOnlyText() throws {
        let message = """
        {
          "message_type": "partial_transcript",
          "text": "This is a test，okay？"
        }
        """

        let update = try XCTUnwrap(
            ElevenLabsProtocol.makeTranscriptUpdate(
                from: Data(message.utf8),
                confirmedSegments: [],
                languageCode: ""
            )
        )

        XCTAssertEqual(update.transcript.partialText, "This is a test, okay?")
    }
}

private extension Array where Element == URLQueryItem {
    func value(for name: String) -> String? {
        first { $0.name == name }?.value
    }
}
