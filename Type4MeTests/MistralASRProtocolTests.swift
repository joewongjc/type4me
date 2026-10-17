import XCTest
@testable import Type4Me

final class MistralASRProtocolTests: XCTestCase {

    private let pcm = Data(count: 3200)

    private func multipartFields(_ request: URLRequest) throws -> [(name: String, value: String)] {
        let body = try XCTUnwrap(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        let pattern = #"name="([^"]+)"(?:; filename="[^"]+"\r\nContent-Type: [^\r]+)?\r\n\r\n([^\r]*)\r\n"#
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (
                String(text[Range(match.range(at: 1), in: text)!]),
                String(text[Range(match.range(at: 2), in: text)!])
            )
        }
    }

    func testMiniTranscribe2_buildsMultipartRequest() throws {
        let config = try XCTUnwrap(MistralASRConfig(credentials: [
            "apiKey": "test-key",
            "model": "voxtral-mini-2602",
            "language": "en",
        ]))
        let transcriber = MistralBatchTranscriber()
        let request = try transcriber.makeRequest(
            pcmData: pcm,
            config: config,
            options: ASRRequestOptions(hotwords: ["Type4Me", "Claude Code"])
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.mistral.ai/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

        let fields = try multipartFields(request)
        let values = Dictionary(fields.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(values["model"], "voxtral-mini-2602")
        XCTAssertEqual(values["language"], "en")

        let biasTerms = fields.filter { $0.name == "context_bias" }.map(\.value)
        XCTAssertEqual(biasTerms, ["Type4Me", "Claude", "Code"])
        XCTAssertEqual(fields.last?.name, "file")
    }

    func testSmall_buildsChatCompletionsJSONRequest() throws {
        let config = try XCTUnwrap(MistralASRConfig(credentials: [
            "apiKey": "test-key",
            "model": "voxtral-small-2507",
            "language": "zh",
        ]))
        let transcriber = MistralBatchTranscriber()
        let request = try transcriber.makeRequest(
            pcmData: pcm,
            config: config,
            options: ASRRequestOptions(hotwords: ["Type4Me"])
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.mistral.ai/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "voxtral-small-2507")
        XCTAssertEqual(json["temperature"] as? Int, 0)

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "input_audio")
        XCTAssertNotNil(content[0]["input_audio"] as? String)
        XCTAssertEqual(content[1]["type"] as? String, "text")
        let instruction = try XCTUnwrap(content[1]["text"] as? String)
        XCTAssertTrue(instruction.contains("Transcribe the speech in the audio verbatim."))
    }

    func testMiniTranscribe2_parsesTranscript() throws {
        let transcriber = MistralBatchTranscriber()
        let config = try XCTUnwrap(MistralASRConfig(credentials: ["apiKey": "test-key", "model": "voxtral-mini-2602"]))
        let json = #"{"text": "Hello world from Mistral."}"#

        let text = try transcriber.parseTranscript(from: Data(json.utf8), config: config, options: ASRRequestOptions())
        XCTAssertEqual(text, "Hello world from Mistral.")
    }

    func testSmall_parsesStringContentAndStripsQuotesAndLabels() throws {
        let transcriber = MistralBatchTranscriber()
        let config = try XCTUnwrap(MistralASRConfig(credentials: ["apiKey": "test-key", "model": "voxtral-small-2507"]))
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "Transcript: \\"Hello world!\\""
                }
            }]
        }
        """

        let text = try transcriber.parseTranscript(from: Data(json.utf8), config: config, options: ASRRequestOptions())
        XCTAssertEqual(text, "Hello world!")
    }

    func testSmall_parsesChunkContent() throws {
        let transcriber = MistralBatchTranscriber()
        let config = try XCTUnwrap(MistralASRConfig(credentials: ["apiKey": "test-key", "model": "voxtral-small-2507"]))
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": [
                        {"type": "text", "text": "Part 1 "},
                        {"type": "text", "text": "Part 2"}
                    ]
                }
            }]
        }
        """

        let text = try transcriber.parseTranscript(from: Data(json.utf8), config: config, options: ASRRequestOptions())
        XCTAssertEqual(text, "Part 1 Part 2")
    }

    func testSmall_returnsEmptyForNoSpeechSentinel() throws {
        let transcriber = MistralBatchTranscriber()
        let config = try XCTUnwrap(MistralASRConfig(credentials: ["apiKey": "test-key", "model": "voxtral-small-2507"]))
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "<<NO_SPEECH>>"
                }
            }]
        }
        """

        let text = try transcriber.parseTranscript(from: Data(json.utf8), config: config, options: ASRRequestOptions())
        XCTAssertEqual(text, "")
    }
}
