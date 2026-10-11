import XCTest
@testable import Type4Me

final class BatchASRTranscribersTests: XCTestCase {

    private let pcm = Data(repeating: 0, count: 3_200)

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

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

    // MARK: - Bailian

    func testBailian_buildsDashScopeRequestWithWAVDataURI() throws {
        let config = try XCTUnwrap(BailianASRConfig(credentials: [
            "apiKey": "sk-bailian",
            "recognitionMode": "batch",
            "languageHint": "zh",
            "vocabularyId": "vocab-1",
        ]))
        let request = try BailianBatchTranscriber().makeRequest(pcmData: pcm, config: config, options: ASRRequestOptions())

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-bailian")

        let root = try json(request)
        XCTAssertEqual(root["model"] as? String, "qwen-audio-3.1-asr-flash")
        let parameters = try XCTUnwrap(root["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["format"] as? String, "wav")
        XCTAssertEqual(parameters["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(parameters["language_hints"] as? [String], ["zh"])
        XCTAssertEqual(parameters["vocabulary_id"] as? String, "vocab-1")

        let input = try XCTUnwrap(root["input"] as? [String: Any])
        let message = try XCTUnwrap((input["messages"] as? [[String: Any]])?.first)
        let content = try XCTUnwrap((message["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(content["type"] as? String, "input_audio")
        let data = try XCTUnwrap((content["input_audio"] as? [String: Any])?["data"] as? String)
        XCTAssertTrue(data.hasPrefix("data:audio/wav;base64,UklGR"), "expected a RIFF/WAV payload")
    }

    func testBailian_reusesCustomBaseURLHost() throws {
        let config = try XCTUnwrap(BailianASRConfig(credentials: [
            "apiKey": "sk",
            "baseURL": "wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference",
        ]))
        XCTAssertEqual(
            BailianBatchTranscriber.endpoint(for: config).absoluteString,
            "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
        )
    }

    func testBailian_parsesKnownResponseShapes() throws {
        let transcriber = BailianBatchTranscriber()
        let options = ASRRequestOptions()
        XCTAssertEqual(
            try transcriber.parseTranscript(from: Data(#"{"output":{"text":" 你好 "}}"#.utf8), options: options),
            "你好"
        )
        XCTAssertEqual(
            try transcriber.parseTranscript(
                from: Data(#"{"output":{"choices":[{"message":{"content":[{"text":"你好，世界"}]}}]}}"#.utf8),
                options: options
            ),
            "你好，世界"
        )
        XCTAssertThrowsError(try transcriber.parseTranscript(from: Data(#"{"code":"x"}"#.utf8), options: options))
    }

    func testBailian_noWordsResponseCountsAsEmptyTranscript() async throws {
        let testID = UUID().uuidString
        MockBatchURLProtocol.setHandler(for: testID) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"code":"InvalidParameter","message":"ASR_RESPONSE_HAVE_NO_WORDS"}"#.utf8))
        }
        defer { MockBatchURLProtocol.removeHandler(for: testID) }

        let config = try XCTUnwrap(BailianASRConfig(credentials: ["apiKey": "sk", "recognitionMode": "batch"]))
        let options = MockBatchURLProtocol.options(testID: testID)
        let text = try await BatchASRHTTP.transcribe(
            pcmData: Data(count: BatchASRHTTP.bytesPerSecond),
            with: BailianBatchTranscriber(),
            config: config,
            options: options,
            session: URLSession(configuration: options.urlSessionConfiguration)
        )
        XCTAssertEqual(text, "")

        // Other 400s are still reported.
        XCTAssertFalse(BailianBatchTranscriber().isNoSpeechResponse(
            statusCode: 400,
            data: Data(#"{"code":"InvalidApiKey","message":"Invalid API-key provided."}"#.utf8)
        ))
    }

    // MARK: - Gemini

    func testGemini_buildsGenerateContentRequestWithTranscriptionConfig() throws {
        let config = try XCTUnwrap(GeminiASRConfig(credentials: [
            "apiKey": "g-key",
            "recognitionMode": "batch",
            "mode": "VERBATIM",
            "languageCode": "cmn-Hans-CN",
        ]))
        let request = try GeminiBatchTranscriber().makeRequest(
            pcmData: pcm,
            config: config,
            options: ASRRequestOptions(hotwords: ["Type4Me", " ", "Type4Me"])
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-transcribe:generateContent"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "g-key")
        XCTAssertFalse(request.url?.absoluteString.contains("g-key") ?? true, "API key must not be in the URL")

        let root = try json(request)
        let generationConfig = try XCTUnwrap(root["generationConfig"] as? [String: Any])
        let transcription = try XCTUnwrap(generationConfig["audioTranscriptionConfig"] as? [String: Any])
        XCTAssertEqual(transcription["mode"] as? String, "VERBATIM")
        XCTAssertEqual(transcription["languageCodes"] as? [String], ["cmn-Hans-CN"])
        XCTAssertEqual(transcription["customVocabulary"] as? [String], ["Type4Me"])

        let content = try XCTUnwrap((root["contents"] as? [[String: Any]])?.first)
        let part = try XCTUnwrap((content["parts"] as? [[String: Any]])?.first)
        let inline = try XCTUnwrap(part["inlineData"] as? [String: Any])
        XCTAssertEqual(inline["mimeType"] as? String, "audio/wav")
    }

    func testGemini_autoLanguageOmitsLanguageCodes() throws {
        let config = try XCTUnwrap(GeminiASRConfig(credentials: ["apiKey": "k", "recognitionMode": "batch"]))
        let root = try json(GeminiBatchTranscriber().makeRequest(pcmData: pcm, config: config, options: ASRRequestOptions()))
        let transcription = try XCTUnwrap(
            (root["generationConfig"] as? [String: Any])?["audioTranscriptionConfig"] as? [String: Any]
        )
        XCTAssertEqual(transcription["mode"] as? String, "SMART")
        XCTAssertNil(transcription["languageCodes"])
        XCTAssertNil(transcription["customVocabulary"])
    }

    func testGemini_parsesCandidateTextAndTreatsMissingContentAsSilence() throws {
        let transcriber = GeminiBatchTranscriber()
        let options = ASRRequestOptions()
        XCTAssertEqual(
            try transcriber.parseTranscript(
                from: Data(#"{"candidates":[{"content":{"parts":[{"text":"Hello "},{"text":"world"}]}}]}"#.utf8),
                options: options
            ),
            "Hello world"
        )
        XCTAssertEqual(
            try transcriber.parseTranscript(from: Data(#"{"candidates":[{"finishReason":"STOP"}]}"#.utf8), options: options),
            ""
        )
    }

    func testGemini_abnormalFinishIsAnErrorNotSilence() {
        let transcriber = GeminiBatchTranscriber()
        let options = ASRRequestOptions()
        XCTAssertThrowsError(
            try transcriber.parseTranscript(from: Data(#"{"candidates":[{"finishReason":"SAFETY"}]}"#.utf8), options: options)
        ) { error in
            XCTAssertEqual(error as? BatchASRError, .blocked(provider: "Gemini", reason: "SAFETY"))
        }
        XCTAssertThrowsError(
            try transcriber.parseTranscript(
                from: Data(#"{"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"}}"#.utf8),
                options: options
            )
        ) { error in
            XCTAssertEqual(error as? BatchASRError, .blocked(provider: "Gemini", reason: "PROHIBITED_CONTENT"))
        }
        XCTAssertThrowsError(try transcriber.parseTranscript(from: Data(#"{"candidates":[]}"#.utf8), options: options))
    }

    func testBatchRequestsUseSharedTimeout() throws {
        let config = try XCTUnwrap(GrokASRConfig(credentials: ["apiKey": "k", "recognitionMode": "batch"]))
        let request = try GrokBatchTranscriber().makeRequest(pcmData: pcm, config: config, options: ASRRequestOptions())
        XCTAssertEqual(request.timeoutInterval, BatchASRHTTP.requestTimeout)
    }

    // MARK: - ElevenLabs

    func testElevenLabs_buildsMultipartWithRawPCMAndKeyterms() throws {
        let config = try XCTUnwrap(ElevenLabsASRConfig(credentials: [
            "apiKey": "el-key",
            "recognitionMode": "batch",
            "language": "zh",
        ]))
        let request = try ElevenLabsBatchTranscriber().makeRequest(
            pcmData: pcm,
            config: config,
            options: ASRRequestOptions(hotwords: ["Type4Me", String(repeating: "x", count: 30)])
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "el-key")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") ?? false)

        let fields = try multipartFields(request)
        let values = Dictionary(fields.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(values["model_id"], "scribe_v2")
        XCTAssertEqual(values["file_format"], "pcm_s16le_16")
        XCTAssertEqual(values["language_code"], "zh")
        XCTAssertEqual(fields.filter { $0.name == "keyterms" }.map(\.value), ["Type4Me"])
        XCTAssertEqual(fields.last?.name, "file")
    }

    // MARK: - Grok

    func testGrok_buildsMultipartWithFileLast() throws {
        let config = try XCTUnwrap(GrokASRConfig(credentials: [
            "apiKey": "xai-key",
            "recognitionMode": "batch",
            "language": "en",
        ]))
        let request = try GrokBatchTranscriber().makeRequest(
            pcmData: pcm,
            config: config,
            options: ASRRequestOptions(hotwords: ["Type4Me", "Claude"])
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.x.ai/v1/stt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer xai-key")

        let fields = try multipartFields(request)
        let values = Dictionary(fields.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(values["model"], "grok-voice-transcribe-2.0")
        XCTAssertEqual(values["audio_format"], "pcm")
        XCTAssertEqual(values["sample_rate"], "16000")
        XCTAssertEqual(values["language"], "en")
        XCTAssertEqual(fields.filter { $0.name == "keyterm" }.map(\.value), ["Type4Me", "Claude"])
        XCTAssertEqual(fields.last?.name, "file", "xAI requires the file part after every option")
    }

    // MARK: - Shared HTTP handling

    func testTranscribe_rejectsRecordingsAboveProviderLimitWithoutNetwork() async throws {
        let config = try XCTUnwrap(BailianASRConfig(credentials: ["apiKey": "sk", "recognitionMode": "batch"]))
        let fourMinutes = Data(count: BatchASRHTTP.bytesPerSecond * 240)
        do {
            _ = try await BatchASRHTTP.transcribe(
                pcmData: fourMinutes,
                with: BailianBatchTranscriber(),
                config: config,
                options: ASRRequestOptions(),
                session: URLSession(configuration: .ephemeral)
            )
            XCTFail("Expected recordingTooLong")
        } catch let error as BatchASRError {
            guard case .recordingTooLong(_, let maxSeconds) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(maxSeconds, 210)
        }
    }

    func testErrorMessage_extractsCommonShapes() {
        XCTAssertEqual(BatchASRHTTP.errorMessage(from: Data(#"{"error":{"message":"bad key"}}"#.utf8)), "bad key")
        XCTAssertEqual(BatchASRHTTP.errorMessage(from: Data(#"{"detail":{"message":"quota"}}"#.utf8)), "quota")
        XCTAssertEqual(BatchASRHTTP.errorMessage(from: Data(#"{"detail":[{"msg":"field required"}]}"#.utf8)), "field required")
        XCTAssertEqual(BatchASRHTTP.errorMessage(from: Data(#"{"code":"x","message":"Invalid"}"#.utf8)), "Invalid")
        XCTAssertEqual(BatchASRHTTP.errorMessage(from: Data("plain failure".utf8)), "plain failure")
    }

    // MARK: - Buffered client

    func testBufferedClient_uploadsOnEndAudioAndEmitsFinalTranscript() async throws {
        let testID = UUID().uuidString
        MockBatchURLProtocol.setHandler(for: testID) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.x.ai/v1/stt")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"text":"你好，世界","language":"zh"}"#.utf8))
        }
        defer { MockBatchURLProtocol.removeHandler(for: testID) }

        let config = try XCTUnwrap(GrokASRConfig(credentials: ["apiKey": "xai", "recognitionMode": "batch"]))
        let client = BufferedBatchASRClient(transcriber: GrokBatchTranscriber())
        try await client.connect(config: config, options: MockBatchURLProtocol.options(testID: testID))
        try await client.sendAudio(Data(count: BatchASRHTTP.bytesPerSecond))
        try await client.endAudio()

        var finals: [RecognitionTranscript] = []
        var completed = false
        for await event in await client.events {
            switch event {
            case .transcript(let transcript) where transcript.isFinal: finals.append(transcript)
            case .completed: completed = true
            default: break
            }
        }
        XCTAssertEqual(finals.map(\.authoritativeText), ["你好，世界"])
        XCTAssertEqual(finals.first?.confirmedSegments, ["你好，世界"])
        XCTAssertTrue(completed)
        await client.disconnect()
    }

    func testBufferedClient_reportsHTTPErrorWithServerMessage() async throws {
        let testID = UUID().uuidString
        MockBatchURLProtocol.setHandler(for: testID) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"detail":{"message":"Invalid API key"}}"#.utf8))
        }
        defer { MockBatchURLProtocol.removeHandler(for: testID) }

        let config = try XCTUnwrap(ElevenLabsASRConfig(credentials: ["apiKey": "bad", "recognitionMode": "batch"]))
        let client = BufferedBatchASRClient(transcriber: ElevenLabsBatchTranscriber())
        try await client.connect(config: config, options: MockBatchURLProtocol.options(testID: testID))
        try await client.sendAudio(Data(count: BatchASRHTTP.bytesPerSecond))

        do {
            try await client.endAudio()
            XCTFail("Expected HTTP failure")
        } catch let error as BatchASRError {
            XCTAssertEqual(error, .requestFailed(provider: "ElevenLabs", code: 401, message: "Invalid API key"))
        }
        await client.disconnect()
    }

    func testBufferedClient_skipsRequestForVeryShortRecording() async throws {
        let config = try XCTUnwrap(GrokASRConfig(credentials: ["apiKey": "xai", "recognitionMode": "batch"]))
        let client = BufferedBatchASRClient(transcriber: GrokBatchTranscriber())
        // No handler is registered: any network request would fail the test.
        try await client.connect(config: config, options: MockBatchURLProtocol.options(testID: UUID().uuidString))
        try await client.sendAudio(Data(count: 1_000))
        try await client.endAudio()

        var finalText: String?
        for await event in await client.events {
            if case .transcript(let transcript) = event, transcript.isFinal {
                finalText = transcript.authoritativeText
            }
        }
        XCTAssertEqual(finalText, "")
        await client.disconnect()
    }
}

private final class MockBatchURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

    static func setHandler(for testID: String, handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        defer { lock.unlock() }
        handlers[testID] = handler
    }

    static func removeHandler(for testID: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: testID)
    }

    static func options(testID: String) -> ASRRequestOptions {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockBatchURLProtocol.self]
        sessionConfig.httpAdditionalHeaders = ["X-Test-ID": testID]
        var options = ASRRequestOptions()
        options.customURLSessionConfiguration = sessionConfig
        return options
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let testID = request.allHTTPHeaderFields?["X-Test-ID"] ?? ""
        Self.lock.lock()
        let handler = Self.handlers[testID]
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
