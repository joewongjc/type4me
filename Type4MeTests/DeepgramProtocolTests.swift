import XCTest
@testable import Type4Me

final class DeepgramProtocolTests: XCTestCase {

    func testUsesStandardAuthorizationForDirectDeepgramEndpoints() {
        XCTAssertTrue(DeepgramProtocol.usesStandardAuthorization(for: DeepgramASRConfig.defaultBaseURL))
        XCTAssertTrue(DeepgramProtocol.usesStandardAuthorization(for: "wss://asr.autoloops.ai/v1/listen"))
    }

    func testUsesProxyAPIKeyForDevProxyEndpoints() {
        XCTAssertFalse(DeepgramProtocol.usesStandardAuthorization(for: "wss://dev-proxy.example.com/proxy/deepgram/v1/listen"))
        XCTAssertFalse(DeepgramProtocol.usesStandardAuthorization(for: "wss://asr.autoloops.ai.example.com/v1/listen"))
    }

    func testBuildWebSocketURL_usesExpectedQueryItems() throws {
        let config = try XCTUnwrap(DeepgramASRConfig(credentials: [
            "apiKey": "dg_test_key",
            "model": "nova-2",
        ]))
        let url = try DeepgramProtocol.buildWebSocketURL(
            config: config,
            options: ASRRequestOptions(
                enablePunc: true,
                hotwords: ["Type4Me", "Deepgram"],
                boostingTableID: "ignored",
                contextHistoryLength: 8
            )
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.deepgram.com")
        XCTAssertEqual(components.path, "/v1/listen")
        XCTAssertEqual(items.value(for: "model"), "nova-2")
        XCTAssertEqual(items.value(for: "language"), DeepgramASRConfig.defaultLanguage)
        XCTAssertEqual(items.value(for: "encoding"), "linear16")
        XCTAssertEqual(items.value(for: "sample_rate"), "16000")
        XCTAssertEqual(items.value(for: "channels"), "1")
        XCTAssertEqual(items.value(for: "interim_results"), "true")
        XCTAssertEqual(items.value(for: "punctuate"), "true")
        XCTAssertEqual(items.value(for: "smart_format"), "true")
        XCTAssertEqual(items.values(for: "keywords"), ["Type4Me:2", "Deepgram:2"])
        XCTAssertNil(items.value(for: "keyterm"))
    }

    func testBuildWebSocketURL_usesCustomEndpoint() throws {
        let endpoint = "wss://example.test/proxy/deepgram/v1/listen"
        let config = try XCTUnwrap(DeepgramASRConfig(credentials: ["apiKey": "proxy-token", "baseURL": endpoint]))
        let url = try DeepgramProtocol.buildWebSocketURL(config: config, options: ASRRequestOptions())
        XCTAssertEqual(url.absoluteString.components(separatedBy: "?").first, endpoint)
    }

    func testBuildWebSocketURL_usesKeytermForNova3Models() throws {
        let config = try XCTUnwrap(DeepgramASRConfig(credentials: [
            "apiKey": "dg_test_key",
            "model": "nova-3",
        ]))
        let url = try DeepgramProtocol.buildWebSocketURL(
            config: config,
            options: ASRRequestOptions(
                enablePunc: false,
                hotwords: ["Type4Me", "Hangzhou"]
            )
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []

        XCTAssertEqual(items.value(for: "punctuate"), "false")
        XCTAssertEqual(items.values(for: "keyterm"), ["Type4Me", "Hangzhou"])
        XCTAssertNil(items.value(for: "keywords"))
    }

    func testUpdateTranscript_buildsPartialTextAgainstConfirmedSegments() throws {
        let message = """
        {
          "type": "Results",
          "is_final": false,
          "speech_final": false,
          "channel": {
            "alternatives": [
              { "transcript": "world" }
            ]
          }
        }
        """

        let update = try XCTUnwrap(
            DeepgramProtocol.makeTranscriptUpdate(
                from: Data(message.utf8),
                confirmedSegments: ["Hello"]
            )
        )

        XCTAssertEqual(update.confirmedSegments, ["Hello"])
        XCTAssertEqual(update.transcript.partialText, " world")
        XCTAssertEqual(update.transcript.authoritativeText, "Hello world")
        XCTAssertFalse(update.transcript.isFinal)
    }

    func testUpdateTranscript_promotesFinalResultsToConfirmedSegments() throws {
        let message = """
        {
          "type": "Results",
          "is_final": true,
          "speech_final": true,
          "channel": {
            "alternatives": [
              { "transcript": "world" }
            ]
          }
        }
        """

        let update = try XCTUnwrap(
            DeepgramProtocol.makeTranscriptUpdate(
                from: Data(message.utf8),
                confirmedSegments: ["Hello"]
            )
        )

        XCTAssertEqual(update.confirmedSegments, ["Hello", " world"])
        XCTAssertEqual(update.transcript.partialText, "")
        XCTAssertEqual(update.transcript.authoritativeText, "Hello world")
        XCTAssertTrue(update.transcript.isFinal)
    }

    func testUpdateTranscript_ignoresNonTranscriptMessages() throws {
        let message = """
        {
          "type": "Metadata",
          "request_id": "abc123"
        }
        """

        let update = try DeepgramProtocol.makeTranscriptUpdate(
            from: Data(message.utf8),
            confirmedSegments: []
        )

        XCTAssertNil(update)
    }
}

private extension [URLQueryItem] {
    func value(for name: String) -> String? {
        first(where: { $0.name == name })?.value
    }

    func values(for name: String) -> [String] {
        filter { $0.name == name }.compactMap(\.value)
    }
}
