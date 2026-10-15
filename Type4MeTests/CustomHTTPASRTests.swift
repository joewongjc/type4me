import XCTest
@testable import Type4Me

final class CustomHTTPASRTests: XCTestCase {

    private let pcm = Data((0..<3_200).map { UInt8($0 % 251) })
    private let transcriber = CustomHTTPBatchTranscriber()

    private func config(_ values: [String: String]) throws -> CustomASRConfig {
        try XCTUnwrap(CustomASRConfig(credentials: values))
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    // MARK: - Request Building

    /// Gateway flash-ASR shape verified against a live gateway: X-API-Key header, base64 WAV in `audio_data`.
    func testJSONTemplateBuildsGatewayRequestWithBase64Recording() throws {
        let config = try config([
            "endpointURL": "https://gateway.example.com/asr/transcriptions",
            "apiKey": "sk-test",
            "headers": "X-API-Key: {{api_key}}",
            "bodyTemplate": #"{"model":"volc.bigasr.auc_turbo","audio_data":"{{audio_base64}}","enable_punc":true,"enable_itn":true}"#,
        ])
        let request = try transcriber.makeRequest(pcmData: pcm, config: config, options: ASRRequestOptions())

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://gateway.example.com/asr/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "sk-test")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try jsonBody(request)
        XCTAssertEqual(body["model"] as? String, "volc.bigasr.auc_turbo")
        XCTAssertEqual(body["enable_punc"] as? Bool, true)
        let audio = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(body["audio_data"] as? String)))
        XCTAssertEqual(audio, WAVEncoder.encode(pcmData: pcm))
    }

    func testEmptyHeadersFallBackToBearerAuthorization() throws {
        let config = try config([
            "endpointURL": "https://asr.example.com/v1/transcribe",
            "apiKey": "sk-test",
            "bodyTemplate": #"{"audio":"{{audio_base64}}"}"#,
        ])
        let request = try transcriber.makeRequest(pcmData: pcm, config: config, options: ASRRequestOptions())
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    /// OpenAI-compatible `audio/transcriptions` style upload.
    func testMultipartTemplateUploadsRecordingAsWAVFilePart() throws {
        let config = try config([
            "endpointURL": "https://api.example.com/v1/audio/transcriptions",
            "apiKey": "sk-test",
            "uploadFormat": "multipart",
            "bodyTemplate": #"{"model":"whisper-1","file":"{{audio_file}}","temperature":0,"stream":false}"#,
        ])
        let request = try transcriber.makeRequest(pcmData: pcm, config: config, options: ASRRequestOptions())

        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = try XCTUnwrap(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"))
        XCTAssertTrue(text.contains("name=\"temperature\"\r\n\r\n0\r\n"))
        XCTAssertTrue(text.contains("name=\"stream\"\r\n\r\nfalse\r\n"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"))
        XCTAssertNotNil(body.range(of: WAVEncoder.encode(pcmData: pcm)))
    }

    func testCurlyQuotesFromRichTextAreAccepted() throws {
        let config = try config([
            "endpointURL": "https://asr.example.com/v1/transcribe",
            "bodyTemplate": "{\u{201C}audio\u{201D}: \u{201C}{{audio_base64}}\u{201D}}",
        ])
        let request = try transcriber.makeRequest(pcmData: pcm, config: config, options: ASRRequestOptions())
        XCTAssertNotNil(try jsonBody(request)["audio"] as? String)
    }

    func testConfigurationMistakesExplainWhatToFix() throws {
        let cases: [([String: String], CustomASRError)] = [
            (["endpointURL": "gateway.example.com/asr", "bodyTemplate": #"{"a":"{{audio_base64}}"}"#],
             .invalidEndpoint),
            (["endpointURL": "https://x.example.com", "headers": "X-API-Key: k\nBearer token",
              "bodyTemplate": #"{"a":"{{audio_base64}}"}"#],
             .invalidHeader(line: 2)),
            (["endpointURL": "https://x.example.com", "bodyTemplate": #"{"a": }"#],
             .invalidTemplate),
            (["endpointURL": "https://x.example.com", "bodyTemplate": #"{"audio_url":"https://x"}"#],
             .missingAudioPlaceholder("{{audio_base64}}")),
            (["endpointURL": "https://x.example.com", "uploadFormat": "multipart",
              "bodyTemplate": #"{"file":"{{audio_base64}}"}"#],
             .missingAudioPlaceholder("{{audio_file}}")),
        ]
        for (values, expected) in cases {
            let config = try config(values)
            XCTAssertThrowsError(try transcriber.makeRequest(pcmData: pcm, config: config, options: ASRRequestOptions())) {
                XCTAssertEqual($0 as? CustomASRError, expected)
            }
        }
    }

    func testConfigRequiresEndpointAndTemplateAndAppliesDefaults() throws {
        XCTAssertNil(CustomASRConfig(credentials: ["endpointURL": "https://x.example.com"]))
        XCTAssertNil(CustomASRConfig(credentials: ["bodyTemplate": #"{"a":"{{audio_base64}}"}"#]))

        let config = try config(["endpointURL": "https://x.example.com", "bodyTemplate": #"{"a":"{{audio_base64}}"}"#])
        XCTAssertEqual(config.uploadFormat, .json)
        XCTAssertEqual(config.resultPath, "text")
    }

    // MARK: - Response Handling

    func testResultPathReadsNestedTranscript() throws {
        let data = Data(#"{"results":{"channels":[{"alternatives":[{"transcript":" 你好，世界 "}]}]}}"#.utf8)
        XCTAssertEqual(
            try transcriber.parseTranscript(from: data, resultPath: "results.channels[0].alternatives[0].transcript"),
            "你好，世界"
        )
        XCTAssertThrowsError(try transcriber.parseTranscript(from: data, resultPath: "text")) {
            guard case .resultFieldNotFound(let path, let preview) = $0 as? CustomASRError else {
                return XCTFail("unexpected \($0)")
            }
            XCTAssertEqual(path, "text")
            XCTAssertTrue(preview.hasPrefix(#"{"results""#))
        }
    }

    func testUploadUsesConfiguredResultField() async throws {
        let testID = UUID().uuidString
        MockCustomASRURLProtocol.setHandler(for: testID) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"result":{"text":"今天下午3点开会。"}}"#.utf8))
        }
        defer { MockCustomASRURLProtocol.removeHandler(for: testID) }

        let config = try config([
            "endpointURL": "https://x.example.com/asr",
            "bodyTemplate": #"{"audio":"{{audio_base64}}"}"#,
            "resultPath": "result.text",
        ])
        let text = try await transcribe(config: config, testID: testID)
        XCTAssertEqual(text, "今天下午3点开会。")
    }

    /// A gateway relaying Volcano answers one second of silence (the connection test) with HTTP 502 and code 20000003.
    func testNoSpeechGatewayErrorYieldsEmptyTranscript() async throws {
        let testID = UUID().uuidString
        MockCustomASRURLProtocol.setHandler(for: testID) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!
            let body = #"{"error":{"message":"volcengine flash failed: 20000003 {\"result\":{\"text\":\"\"}}","type":"api_error"}}"#
            return (response, Data(body.utf8))
        }
        defer { MockCustomASRURLProtocol.removeHandler(for: testID) }

        let config = try config(["endpointURL": "https://x.example.com/asr", "bodyTemplate": #"{"audio":"{{audio_base64}}"}"#])
        let text = try await transcribe(config: config, testID: testID)
        XCTAssertEqual(text, "")
    }

    func testServerErrorMessageIsSurfaced() async throws {
        let testID = UUID().uuidString
        MockCustomASRURLProtocol.setHandler(for: testID) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":{"message":"invalid api key"}}"#.utf8))
        }
        defer { MockCustomASRURLProtocol.removeHandler(for: testID) }

        let config = try config(["endpointURL": "https://x.example.com/asr", "bodyTemplate": #"{"audio":"{{audio_base64}}"}"#])
        do {
            _ = try await transcribe(config: config, testID: testID)
            XCTFail("Expected HTTP failure")
        } catch let error as BatchASRError {
            XCTAssertEqual(error, .requestFailed(provider: transcriber.providerName, code: 401, message: "invalid api key"))
        }
    }

    private func transcribe(config: CustomASRConfig, testID: String) async throws -> String {
        let options = MockCustomASRURLProtocol.options(testID: testID)
        let session = URLSession(configuration: options.urlSessionConfiguration)
        defer { session.finishTasksAndInvalidate() }
        return try await BatchASRHTTP.transcribe(
            pcmData: Data(count: BatchASRHTTP.bytesPerSecond),
            with: transcriber,
            config: config,
            options: options,
            session: session
        )
    }

    // MARK: - Localization

    func testFieldLabelsAndErrorsFollowLanguageSetting() {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: "tf_language")
        defer {
            if let original {
                defaults.set(original, forKey: "tf_language")
            } else {
                defaults.removeObject(forKey: "tf_language")
            }
        }
        defaults.set("zh", forKey: "tf_language")
        XCTAssertEqual(CustomASRConfig.credentialFields.map(\.label),
                       ["请求地址", "API Key", "请求头", "上传方式", "请求体模板", "结果字段"])
        XCTAssertEqual(CustomASRError.invalidHeader(line: 2).errorDescription, "请求头第 2 行格式不对，应为「名称: 值」")

        defaults.set("en", forKey: "tf_language")
        XCTAssertEqual(CustomASRConfig.credentialFields.map(\.label),
                       ["Endpoint URL", "API Key", "Headers", "Upload Format", "Body Template", "Result Field"])
        XCTAssertEqual(CustomASRError.invalidHeader(line: 2).errorDescription, "Header line 2 must look like \"Name: value\"")
    }

    // MARK: - Registration

    func testCustomProviderIsSelectableAsBatchEngine() {
        let entry = ASRProviderRegistry.entry(for: .custom)
        XCTAssertTrue(entry?.isAvailable ?? false)
        let caps = ASRProviderRegistry.capabilities(for: .custom, mode: .default)
        XCTAssertFalse(caps.isStreaming)
        XCTAssertFalse(caps.supportsRealtimeRecognition)
        XCTAssertTrue(ModelSettingsHelpers.availableASRProviders().contains(.custom))
    }
}

private final class MockCustomASRURLProtocol: URLProtocol {
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
        sessionConfig.protocolClasses = [MockCustomASRURLProtocol.self]
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
