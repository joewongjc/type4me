import XCTest
@testable import Type4Me

final class StepFunASRClientTests: XCTestCase {

    func testStreamingLifecycleEmitsPartialThenSingleFinalCompletion() async throws {
        let socket = MockStepFunWebSocket()
        let client = makeClient(socket: socket)
        try await connect(client, socket: socket)
        let eventsTask = collectUntilCompleted(from: client)

        let pcm = Data([0x00, 0x01, 0x02])
        try await client.sendAudio(pcm)
        await socket.push(#"{"type":"conversation.item.input_audio_transcription.delta","text":"你好，","stash":"世"}"#)
        await socket.push(#"{"type":"conversation.item.input_audio_transcription.delta","text":"你好，","stash":"世界"}"#)
        try await client.endAudio()
        try await client.endAudio()
        await socket.push(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"你好，世界"}"#)

        let events = await eventsTask.value
        let transcripts = events.compactMap { event -> RecognitionTranscript? in
            guard case .transcript(let transcript) = event else { return nil }
            return transcript
        }
        XCTAssertEqual(transcripts.map(\.authoritativeText), ["你好，世", "你好，世界", "你好，世界"])
        XCTAssertEqual(transcripts.map(\.isFinal), [false, false, true])
        XCTAssertEqual(completedCount(in: events), 1)

        let sent = await socket.waitForSentMessages(count: 3)
        XCTAssertEqual(messageTypes(in: sent), [
            "session.update",
            "input_audio_buffer.append",
            "input_audio_buffer.commit",
        ])
        XCTAssertEqual(audioPayload(in: sent[1]), pcm.base64EncodedString())

        await client.disconnect()
    }

    func testFailedCommitCanBeRetried() async throws {
        let socket = MockStepFunWebSocket()
        let client = makeClient(socket: socket)
        try await connect(client, socket: socket)

        await socket.failNextSend(with: URLError(.networkConnectionLost))
        do {
            try await client.endAudio()
            XCTFail("Expected commit send failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }

        try await client.endAudio()
        let sent = await socket.waitForSentMessages(count: 2)
        XCTAssertEqual(messageTypes(in: sent), [
            "session.update",
            "input_audio_buffer.commit",
        ])

        await client.disconnect()
    }

    func testServerErrorAfterReadyEmitsErrorAndCompletes() async throws {
        let socket = MockStepFunWebSocket()
        let client = makeClient(socket: socket)
        try await connect(client, socket: socket)
        let eventsTask = collectUntilCompleted(from: client)

        await socket.push(#"{"type":"error","error":{"code":"invalid_value","message":"bad audio"}}"#)
        let events = await eventsTask.value

        let errors = events.compactMap { event -> StepFunASRError? in
            guard case .error(let error) = event else { return nil }
            return error as? StepFunASRError
        }
        XCTAssertEqual(errors, [.serverError(code: "invalid_value", message: "bad audio")])
        XCTAssertEqual(completedCount(in: events), 1)

        await client.disconnect()
    }

    func testDuplicateFinalMessageEmitsCompletionOnlyOnce() async throws {
        let socket = MockStepFunWebSocket()
        let client = makeClient(socket: socket)
        try await connect(client, socket: socket)
        let eventsTask = Task {
            var events: [RecognitionEvent] = []
            for await event in await client.events {
                events.append(event)
            }
            return events
        }

        let finalMessage = #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"你好，世界"}"#
        await socket.push(finalMessage)
        await socket.push(finalMessage)
        try await Task.sleep(for: .milliseconds(30))
        await client.disconnect()

        let events = await eventsTask.value
        XCTAssertEqual(completedCount(in: events), 1)
        XCTAssertEqual(events.compactMap { event -> RecognitionTranscript? in
            guard case .transcript(let transcript) = event else { return nil }
            return transcript
        }.filter(\.isFinal).count, 1)
    }

    func testTransportFailureBeforeReadyFailsConnect() async throws {
        let socket = MockStepFunWebSocket()
        let client = makeClient(socket: socket)
        let config = try makeConfig()

        let connectTask = Task {
            try await client.connect(config: config, options: ASRRequestOptions())
        }
        _ = await socket.waitForSentMessages(count: 1)
        await socket.failReceive(with: URLError(.networkConnectionLost))

        do {
            try await connectTask.value
            XCTFail("Expected transport failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }

        await client.disconnect()
    }

    func testDisconnectWhileConnectingCancelsReadinessWait() async throws {
        let socket = MockStepFunWebSocket()
        let client = makeClient(socket: socket)
        let config = try makeConfig()

        let connectTask = Task {
            try await client.connect(config: config, options: ASRRequestOptions())
        }
        _ = await socket.waitForSentMessages(count: 1)

        await client.disconnect()

        do {
            try await connectTask.value
            XCTFail("Expected connect to be cancelled")
        } catch is CancellationError {
            // Expected: disconnect must wake the pending readiness wait.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let closeCount = await socket.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    func testDisconnectIsIdempotentAndClosesTransportOnce() async throws {
        let socket = MockStepFunWebSocket()
        let client = makeClient(socket: socket)
        try await connect(client, socket: socket)

        await client.disconnect()
        await client.disconnect()

        let closeCount = await socket.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    func testCallsBeforeConnectAreSafe() async throws {
        let client = StepFunASRClient()
        try await client.sendAudio(Data())
        try await client.sendAudio(Data([0x01]))
        try await client.endAudio()
        await client.disconnect()
        await client.disconnect()
    }

    private func makeClient(socket: MockStepFunWebSocket) -> StepFunASRClient {
        StepFunASRClient { _, _, _ in socket }
    }

    private func makeConfig() throws -> StepFunASRConfig {
        try XCTUnwrap(StepFunASRConfig(credentials: ["apiKey": "sk-test"]))
    }

    private func connect(_ client: StepFunASRClient, socket: MockStepFunWebSocket) async throws {
        let config = try makeConfig()
        let connectTask = Task {
            try await client.connect(config: config, options: ASRRequestOptions())
        }
        _ = await socket.waitForSentMessages(count: 1)
        await socket.push(#"{"type":"session.updated"}"#)
        try await connectTask.value
    }

    private func collectUntilCompleted(from client: StepFunASRClient) -> Task<[RecognitionEvent], Never> {
        Task {
            var events: [RecognitionEvent] = []
            for await event in await client.events {
                events.append(event)
                if case .completed = event { break }
            }
            return events
        }
    }

    private func completedCount(in events: [RecognitionEvent]) -> Int {
        events.reduce(into: 0) { count, event in
            if case .completed = event { count += 1 }
        }
    }

    private func messageTypes(in messages: [String]) -> [String] {
        messages.compactMap { message in
            guard let data = message.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return json["type"] as? String
        }
    }

    private func audioPayload(in message: String) -> String? {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["audio"] as? String
    }
}

private actor MockStepFunWebSocket: StepFunWebSocketTransport {

    private enum Incoming {
        case data(Data)
        case failure(Error)
    }

    private struct SendWaiter {
        let count: Int
        let continuation: CheckedContinuation<[String], Never>
    }

    private var incoming: [Incoming] = []
    private var receiveContinuation: CheckedContinuation<Data, Error>?
    private var sentMessages: [String] = []
    private var sendWaiters: [SendWaiter] = []
    private var nextSendFailure: Error?
    private var isClosed = false
    private(set) var closeCount = 0

    func start() async {}

    func send(_ message: String) async throws {
        if let failure = nextSendFailure {
            nextSendFailure = nil
            throw failure
        }
        sentMessages.append(message)
        resumeSatisfiedSendWaiters()
    }

    func receive() async throws -> Data {
        if !incoming.isEmpty {
            return try resolve(incoming.removeFirst())
        }
        if isClosed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            receiveContinuation = continuation
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        closeCount += 1
        receiveContinuation?.resume(throwing: CancellationError())
        receiveContinuation = nil
    }

    func push(_ json: String) {
        enqueue(.data(Data(json.utf8)))
    }

    func failReceive(with error: Error) {
        enqueue(.failure(error))
    }

    func failNextSend(with error: Error) {
        nextSendFailure = error
    }

    func waitForSentMessages(count: Int) async -> [String] {
        if sentMessages.count >= count { return sentMessages }
        return await withCheckedContinuation { continuation in
            sendWaiters.append(SendWaiter(count: count, continuation: continuation))
        }
    }

    private func enqueue(_ message: Incoming) {
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            switch message {
            case .data(let data): continuation.resume(returning: data)
            case .failure(let error): continuation.resume(throwing: error)
            }
        } else {
            incoming.append(message)
        }
    }

    private func resolve(_ message: Incoming) throws -> Data {
        switch message {
        case .data(let data): return data
        case .failure(let error): throw error
        }
    }

    private func resumeSatisfiedSendWaiters() {
        var remaining: [SendWaiter] = []
        for waiter in sendWaiters {
            if sentMessages.count >= waiter.count {
                waiter.continuation.resume(returning: sentMessages)
            } else {
                remaining.append(waiter)
            }
        }
        sendWaiters = remaining
    }
}
