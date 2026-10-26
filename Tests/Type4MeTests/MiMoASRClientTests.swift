import XCTest
@testable import Type4Me

final class MiMoASRClientTests: XCTestCase {

    private final class MockURLProtocol: URLProtocol {
        static let lock = NSLock()
        static var handlers: [String: (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

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

        override class func canInit(with request: URLRequest) -> Bool {
            return true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            return request
        }

        override func startLoading() {
            let testID = request.allHTTPHeaderFields?["X-Test-ID"] ?? ""
            MockURLProtocol.lock.lock()
            let handler = MockURLProtocol.handlers[testID]
            MockURLProtocol.lock.unlock()

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

    private func createTestOptions(testID: String) -> ASRRequestOptions {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        sessionConfig.httpAdditionalHeaders = ["X-Test-ID": testID]
        var options = ASRRequestOptions()
        options.customURLSessionConfiguration = sessionConfig
        return options
    }

    func testEndAudio_successEmitsPartialAndFinalTranscripts() async throws {
        let testID = UUID().uuidString
        let sseBody = """
        data: {"choices":[{"delta":{"content":"你好"},"finish_reason":null}]}

        data: {"choices":[{"delta":{"content":"，世界"},"finish_reason":null}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]
        """
        MockURLProtocol.setHandler(for: testID) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, sseBody.data(using: .utf8)!)
        }
        defer { MockURLProtocol.removeHandler(for: testID) }

        let config = try XCTUnwrap(MiMoASRConfig(credentials: ["apiKey": "test-key"]))
        let client = MiMoASRClient()

        var collectedEvents: [RecognitionEvent] = []
        let collectTask = Task {
            for await event in await client.events {
                collectedEvents.append(event)
            }
        }

        try await client.connect(config: config, options: createTestOptions(testID: testID))
        try await client.sendAudio(Data(repeating: 0x01, count: 3200))
        try await client.endAudio()

        await collectTask.value

        let transcripts = collectedEvents.compactMap { event -> RecognitionTranscript? in
            if case .transcript(let t) = event { return t }
            return nil
        }

        // 1 placeholder + 2 partials + 1 final = 4 transcripts
        XCTAssertEqual(transcripts.count, 4)
        XCTAssertFalse(transcripts[0].isFinal) // placeholder
        XCTAssertEqual(transcripts[1].partialText, "你好")
        XCTAssertFalse(transcripts[1].isFinal)
        XCTAssertEqual(transcripts[2].partialText, "你好，世界")
        XCTAssertFalse(transcripts[2].isFinal)

        let finalTranscript = try XCTUnwrap(transcripts.last)
        XCTAssertTrue(finalTranscript.isFinal)
        XCTAssertEqual(finalTranscript.authoritativeText, "你好，世界")
        XCTAssertEqual(finalTranscript.confirmedSegments, ["你好，世界"])

        guard case .completed = collectedEvents.last else {
            XCTFail("Expected .completed event at end")
            return
        }
    }

    func testEndAudio_streamEOFWithoutStopThrowsInvalidResponseAndNeverEmitsFinalTranscript() async throws {
        let testID = UUID().uuidString
        // Stream cuts off after partial delta without finish_reason "stop"
        let sseBody = """
        data: {"choices":[{"delta":{"content":"半截识别文本"},"finish_reason":null}]}
        """
        MockURLProtocol.setHandler(for: testID) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, sseBody.data(using: .utf8)!)
        }
        defer { MockURLProtocol.removeHandler(for: testID) }

        let config = try XCTUnwrap(MiMoASRConfig(credentials: ["apiKey": "test-key"]))
        let client = MiMoASRClient()

        var collectedEvents: [RecognitionEvent] = []
        let collectTask = Task {
            for await event in await client.events {
                collectedEvents.append(event)
            }
        }

        try await client.connect(config: config, options: createTestOptions(testID: testID))
        try await client.sendAudio(Data(repeating: 0x01, count: 3200))

        do {
            try await client.endAudio()
            XCTFail("Expected endAudio() to throw invalidResponse on abrupt EOF")
        } catch {
            XCTAssertEqual(error as? MiMoASRError, .invalidResponse)
        }

        await collectTask.value

        let transcripts = collectedEvents.compactMap { event -> RecognitionTranscript? in
            if case .transcript(let t) = event { return t }
            return nil
        }

        // Must NEVER emit a final transcript for truncated audio
        XCTAssertFalse(transcripts.contains(where: { $0.isFinal }))

        let errors = collectedEvents.compactMap { event -> Error? in
            if case .error(let err) = event { return err }
            return nil
        }
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first as? MiMoASRError, .invalidResponse)
    }

    func testEndAudio_finishReasonLengthThrowsErrorAndNeverEmitsFinalTranscript() async throws {
        let testID = UUID().uuidString
        let sseBody = """
        data: {"choices":[{"delta":{"content":"前面的一部分"},"finish_reason":null}]}

        data: {"choices":[{"delta":{},"finish_reason":"length"}]}

        data: [DONE]
        """
        MockURLProtocol.setHandler(for: testID) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, sseBody.data(using: .utf8)!)
        }
        defer { MockURLProtocol.removeHandler(for: testID) }

        let config = try XCTUnwrap(MiMoASRConfig(credentials: ["apiKey": "test-key"]))
        let client = MiMoASRClient()

        var collectedEvents: [RecognitionEvent] = []
        let collectTask = Task {
            for await event in await client.events {
                collectedEvents.append(event)
            }
        }

        try await client.connect(config: config, options: createTestOptions(testID: testID))
        try await client.sendAudio(Data(repeating: 0x01, count: 3200))

        do {
            try await client.endAudio()
            XCTFail("Expected endAudio() to throw serverError on length finish reason")
        } catch {
            guard case MiMoASRError.serverError = error else {
                XCTFail("Expected serverError, got \(error)")
                return
            }
        }

        await collectTask.value

        let transcripts = collectedEvents.compactMap { event -> RecognitionTranscript? in
            if case .transcript(let t) = event { return t }
            return nil
        }

        XCTAssertFalse(transcripts.contains(where: { $0.isFinal }))
    }

    func testEndAudio_finishReasonContentFilterThrowsErrorAndNeverEmitsFinalTranscript() async throws {
        let testID = UUID().uuidString
        let sseBody = """
        data: {"choices":[{"delta":{"content":"前段文本"},"finish_reason":null}]}

        data: {"choices":[{"delta":{},"finish_reason":"content_filter"}]}

        data: [DONE]
        """
        MockURLProtocol.setHandler(for: testID) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, sseBody.data(using: .utf8)!)
        }
        defer { MockURLProtocol.removeHandler(for: testID) }

        let config = try XCTUnwrap(MiMoASRConfig(credentials: ["apiKey": "test-key"]))
        let client = MiMoASRClient()

        var collectedEvents: [RecognitionEvent] = []
        let collectTask = Task {
            for await event in await client.events {
                collectedEvents.append(event)
            }
        }

        try await client.connect(config: config, options: createTestOptions(testID: testID))
        try await client.sendAudio(Data(repeating: 0x01, count: 3200))

        do {
            try await client.endAudio()
            XCTFail("Expected endAudio() to throw serverError on content_filter finish reason")
        } catch {
            guard case MiMoASRError.serverError = error else {
                XCTFail("Expected serverError, got \(error)")
                return
            }
        }

        await collectTask.value

        let transcripts = collectedEvents.compactMap { event -> RecognitionTranscript? in
            if case .transcript(let t) = event { return t }
            return nil
        }

        XCTAssertFalse(transcripts.contains(where: { $0.isFinal }))
    }

    func testEndAudio_emptyTextWithStopThrowsInvalidResponse() async throws {
        let testID = UUID().uuidString
        let sseBody = """
        data: {"choices":[{"delta":{"content":""},"finish_reason":"stop"}]}

        data: [DONE]
        """
        MockURLProtocol.setHandler(for: testID) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, sseBody.data(using: .utf8)!)
        }
        defer { MockURLProtocol.removeHandler(for: testID) }

        let config = try XCTUnwrap(MiMoASRConfig(credentials: ["apiKey": "test-key"]))
        let client = MiMoASRClient()

        var collectedEvents: [RecognitionEvent] = []
        let collectTask = Task {
            for await event in await client.events {
                collectedEvents.append(event)
            }
        }

        try await client.connect(config: config, options: createTestOptions(testID: testID))
        try await client.sendAudio(Data(repeating: 0x01, count: 3200))

        do {
            try await client.endAudio()
            XCTFail("Expected endAudio() to throw invalidResponse on empty transcription")
        } catch {
            XCTAssertEqual(error as? MiMoASRError, .invalidResponse)
        }

        await collectTask.value

        let transcripts = collectedEvents.compactMap { event -> RecognitionTranscript? in
            if case .transcript(let t) = event { return t }
            return nil
        }

        XCTAssertFalse(transcripts.contains(where: { $0.isFinal }))
    }

    func testEndAudio_http401ThrowsRequestFailed() async throws {
        let testID = UUID().uuidString
        let errorBody = """
        {"error":{"message":"Invalid API key provided","type":"invalid_request_error","code":"invalid_api_key"}}
        """
        MockURLProtocol.setHandler(for: testID) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, errorBody.data(using: .utf8)!)
        }
        defer { MockURLProtocol.removeHandler(for: testID) }

        let config = try XCTUnwrap(MiMoASRConfig(credentials: ["apiKey": "bad-key"]))
        let client = MiMoASRClient()

        var collectedEvents: [RecognitionEvent] = []
        let collectTask = Task {
            for await event in await client.events {
                collectedEvents.append(event)
            }
        }

        try await client.connect(config: config, options: createTestOptions(testID: testID))
        try await client.sendAudio(Data(repeating: 0x01, count: 3200))

        do {
            try await client.endAudio()
            XCTFail("Expected endAudio() to throw on HTTP 401")
        } catch {
            guard case MiMoASRError.requestFailed(let code, let msg) = error else {
                XCTFail("Expected requestFailed error, got \(error)")
                return
            }
            XCTAssertEqual(code, 401)
            XCTAssertEqual(msg, "Invalid API key provided")
        }

        await collectTask.value
    }
}
