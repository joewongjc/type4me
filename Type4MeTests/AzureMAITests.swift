import XCTest
@testable import Type4Me

final class AzureMAITests: XCTestCase {

    private func config(_ values: [String: String] = [:]) throws -> AzureASRConfig {
        var credentials = ["resource": "my-res", "apiKey": "secret"]
        credentials.merge(values) { _, new in new }
        return try XCTUnwrap(AzureASRConfig(credentials: credentials))
    }

    private func object(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    private func event(_ string: String) throws -> AzureMAIRealtimeEvent {
        try AzureMAIProtocol.parseEvent(Data(string.utf8))
    }

    // MARK: - Config

    func testResourceAcceptsNameHostnameOrURL() throws {
        for resource in [
            "my-res",
            "My-Res",
            "my-res.services.ai.azure.com",
            "https://my-res.services.ai.azure.com/",
            "https://my-res.cognitiveservices.azure.com/speechtotext",
            "my-res.openai.azure.com",
        ] {
            let config = try config(["resource": resource])
            XCTAssertEqual(config.foundryHost, "my-res.services.ai.azure.com", resource)
            XCTAssertEqual(config.speechHost, "my-res.cognitiveservices.azure.com", resource)
        }
    }

    func testCustomDomainIsUsedAsIsForBothServices() throws {
        let config = try config(["resource": "https://speech.example.com"])
        XCTAssertEqual(config.foundryHost, "speech.example.com")
        XCTAssertEqual(config.speechHost, "speech.example.com")
    }

    func testConfigRequiresKeyAndValidResource() {
        XCTAssertNil(AzureASRConfig(credentials: ["resource": "my-res"]))
        XCTAssertNil(AzureASRConfig(credentials: ["apiKey": "secret"]))
        XCTAssertNil(AzureASRConfig(credentials: ["resource": "my res", "apiKey": "secret"]))
        XCTAssertNil(AzureASRConfig(credentials: ["resource": ".services.ai.azure.com", "apiKey": "secret"]))
    }

    func testConfigDefaults() throws {
        let config = try config()
        XCTAssertEqual(config.recognitionMode, .streaming)
        XCTAssertEqual(config.deployment, "MAI-Transcribe-2-Streaming")
        XCTAssertEqual(config.transcribeStyle, "clean")
        XCTAssertEqual(config.language, "")

        XCTAssertEqual(try self.config(["transcribeStyle": "verbatim"]).transcribeStyle, "verbatim")
        XCTAssertEqual(try self.config(["transcribeStyle": "bogus"]).transcribeStyle, "clean")
        XCTAssertEqual(try self.config(["deployment": "  "]).deployment, "MAI-Transcribe-2-Streaming")

        let restored = AzureASRConfig(credentials: try self.config(["recognitionMode": "batch"]).toCredentials())
        XCTAssertEqual(restored?.recognitionMode, .batch)
    }

    func testDisplayedFieldsFollowRecognitionMode() {
        func keys(_ mode: ASRRecognitionMode) -> [String] {
            AzureASRConfig.displayedCredentialFields(for: ["recognitionMode": mode.rawValue]).map(\.key)
        }
        XCTAssertEqual(keys(.streaming), ["recognitionMode", "resource", "apiKey", "deployment", "language"])
        XCTAssertEqual(keys(.batch), ["recognitionMode", "resource", "apiKey", "transcribeStyle", "language"])
    }

    // MARK: - Registry & labels

    func testRegistryOffersBothModes() {
        XCTAssertTrue(ASRProviderRegistry.entry(for: .azure)?.isAvailable ?? false)
        XCTAssertTrue(ASRProviderRegistry.supportsRecognitionModeSelection(for: .azure))
        XCTAssertTrue(ASRProviderRegistry.capabilities(for: .azure, mode: .streaming).isStreaming)
        XCTAssertFalse(ASRProviderRegistry.capabilities(for: .azure, mode: .batch).isStreaming)
    }

    func testHistoryModelLabelFollowsRecognitionMode() throws {
        let name = ASRProvider.azure.displayName
        XCTAssertEqual(
            RecognitionSession.asrModelLabel(for: .azure, config: try config()),
            "\(name) · MAI-Transcribe-2-Streaming"
        )
        XCTAssertEqual(
            RecognitionSession.asrModelLabel(for: .azure, config: try config(["deployment": "mai-stream"])),
            "\(name) · mai-stream"
        )
        XCTAssertEqual(
            RecognitionSession.asrModelLabel(for: .azure, config: try config(["recognitionMode": "batch"])),
            "\(name) · MAI-Transcribe-2"
        )
    }

    // MARK: - Realtime protocol

    func testRealtimeRequest() throws {
        let request = try AzureMAIProtocol.makeRequest(config: config())
        XCTAssertEqual(
            request.url?.absoluteString,
            "wss://my-res.services.ai.azure.com/mai/v1/realtime?intent=transcription"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "secret")
    }

    func testSessionUpdateMessage() throws {
        let message = try object(AzureMAIProtocol.sessionUpdateMessage(config: config()))
        XCTAssertEqual(message["type"] as? String, "session.update")
        let session = try XCTUnwrap(message["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")
        let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 16_000)
        XCTAssertTrue(input["turn_detection"] is NSNull)
        XCTAssertTrue(input["noise_reduction"] is NSNull)
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "MAI-Transcribe-2-Streaming")
        XCTAssertTrue(transcription["language"] is NSNull)

        let zh = try object(AzureMAIProtocol.sessionUpdateMessage(config: config(["language": "zh"])))
        let zhTranscription = ((((zh["session"] as? [String: Any])?["audio"] as? [String: Any])?["input"]
            as? [String: Any])?["transcription"] as? [String: Any])
        XCTAssertEqual(zhTranscription?["language"] as? String, "zh")
    }

    func testAppendAndCommitMessages() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let append = try object(AzureMAIProtocol.appendMessage(pcmData: pcm))
        XCTAssertEqual(append["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(append["audio"] as? String, pcm.base64EncodedString())
        XCTAssertEqual(try object(AzureMAIProtocol.commitMessage)["type"] as? String, "input_audio_buffer.commit")
    }

    func testParsesTranscriptionEvents() throws {
        let prefix = "conversation.item.input_audio_transcription."
        XCTAssertEqual(try event(#"{"type":"session.created","session":{"id":"s"}}"#), .sessionCreated)
        XCTAssertEqual(try event(#"{"type":"session.updated"}"#), .sessionUpdated)
        XCTAssertEqual(try event(#"{"type":"\#(prefix)delta","delta":" there!"}"#), .delta(" there!"))
        XCTAssertEqual(try event(#"{"type":"\#(prefix)intermediate","intermediate":"你好"}"#), .intermediate("你好"))
        XCTAssertEqual(try event(#"{"type":"input_audio_buffer.committed"}"#), .committed)
        XCTAssertEqual(try event(#"{"type":"\#(prefix)completed","transcript":"Hello there!"}"#), .completed("Hello there!"))
        XCTAssertEqual(try event(#"{"type":"rate_limits.updated"}"#), .ignored)
        XCTAssertEqual(try event("not json"), .ignored)
    }

    func testParsesServerErrors() {
        XCTAssertThrowsError(try event(#"{"type":"error","error":{"code":"invalid_value","message":"Unknown deployment"}}"#)) {
            XCTAssertEqual($0 as? AzureMAIProtocolError, .serverError(code: "invalid_value", message: "Unknown deployment"))
        }
        XCTAssertThrowsError(try event(#"{"type":"conversation.item.input_audio_transcription.failed","error":{"message":"boom"}}"#)) {
            XCTAssertEqual($0 as? AzureMAIProtocolError, .serverError(code: nil, message: "boom"))
        }
    }

    func testAccountAndConfigurationErrorsSkipStreamRecovery() {
        func isTerminal(_ error: AzureMAIProtocolError) -> Bool {
            (error as Error as? TerminalASRError)?.isTerminalServerError == true
        }
        XCTAssertTrue(isTerminal(.handshakeFailed(statusCode: 401)))
        XCTAssertTrue(isTerminal(.handshakeFailed(statusCode: 403)))
        XCTAssertTrue(isTerminal(.handshakeFailed(statusCode: 404)))
        XCTAssertTrue(isTerminal(.handshakeFailed(statusCode: 429)))
        XCTAssertTrue(isTerminal(.serverError(code: "invalid_value", message: "Unknown deployment")))
        XCTAssertTrue(isTerminal(.serverError(code: nil, message: "Quota exceeded")))
        XCTAssertTrue(isTerminal(.invalidConfig))

        XCTAssertFalse(isTerminal(.handshakeFailed(statusCode: 502)))
        XCTAssertFalse(isTerminal(.serverError(code: "server_error", message: "Internal error")))
        XCTAssertFalse(isTerminal(.validationTimedOut))
    }

    // MARK: - Batch

    func testBatchRequest() throws {
        let transcriber = AzureMAIBatchTranscriber()
        let request = try transcriber.makeRequest(
            pcmData: Data(count: 3_200),
            config: config(["recognitionMode": "batch", "language": "zh", "transcribeStyle": "verbatim"]),
            options: ASRRequestOptions(hotwords: ["Type4Me", " Type4Me ", "", String(repeating: "x", count: 51)])
        )
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://my-res.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "secret")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") ?? false)

        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="audio"; filename="audio.wav""#))
        XCTAssertTrue(body.contains("RIFF"))

        let definition = AzureMAIBatchTranscriber.definition(
            config: try config(["language": "zh", "transcribeStyle": "verbatim"]),
            hotwords: ["Type4Me", " Type4Me ", "", String(repeating: "x", count: 51)]
        )
        let enhanced = try XCTUnwrap(definition["enhancedMode"] as? [String: Any])
        XCTAssertEqual(enhanced["enabled"] as? Bool, true)
        XCTAssertEqual(enhanced["model"] as? String, "MAI-Transcribe-2")
        XCTAssertEqual((enhanced["modelOptions"] as? [String: Any])?["transcribeStyle"] as? String, "verbatim")
        XCTAssertEqual(definition["locales"] as? [String], ["zh"])
        XCTAssertEqual((definition["phraseList"] as? [String: Any])?["phrases"] as? [String], ["Type4Me"])
        XCTAssertTrue(body.contains(#""model":"MAI-Transcribe-2""#))
    }

    func testBatchDefinitionOmitsAutoLanguageAndEmptyPhrases() throws {
        let definition = AzureMAIBatchTranscriber.definition(config: try config(), hotwords: [])
        XCTAssertNil(definition["locales"])
        XCTAssertNil(definition["phraseList"])
    }

    func testBatchParsesCombinedPhrases() throws {
        let transcriber = AzureMAIBatchTranscriber()
        let options = ASRRequestOptions()
        XCTAssertEqual(
            try transcriber.parseTranscript(
                from: Data(#"{"durationMilliseconds":1000,"combinedPhrases":[{"text":"你好，世界。"}],"phrases":[]}"#.utf8),
                options: options
            ),
            "你好，世界。"
        )
        XCTAssertEqual(
            try transcriber.parseTranscript(from: Data(#"{"combinedPhrases":[]}"#.utf8), options: options),
            ""
        )
        XCTAssertThrowsError(try transcriber.parseTranscript(from: Data(#"{"error":"x"}"#.utf8), options: options))
    }
}
