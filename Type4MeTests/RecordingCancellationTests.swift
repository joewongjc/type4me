import XCTest
import os
@testable import Type4Me

final class RecordingCancellationTests: XCTestCase {
    func testCancelledEmptyStreamFinishesWithoutReplayingAudio() async throws {
        for policy in ClipboardOutputPolicy.allCases {
            try await assertCancelledEmptyStreamCompletes(policy: policy)
        }
    }

    private func assertCancelledEmptyStreamCompletes(policy: ClipboardOutputPolicy) async throws {
        let client = FinishingASRStub()
        let retryCount = OSAllocatedUnfairLock(initialState: 0)
        let completed = expectation(description: "empty cancellation completed")
        let cleared = expectation(description: "processing indicator cleared")
        let session = try await makeSession(client: client, retryCount: retryCount, policy: policy)
        await session.setOnASREvent { event in
            if case .completed = event { completed.fulfill() }
            if case .processingResult(let text) = event, text.isEmpty { cleared.fulfill() }
        }

        await session.abortInjection()
        await session.stopRecording()

        await fulfillment(of: [completed, cleared], timeout: 1)
        XCTAssertEqual(retryCount.withLock { $0 }, 0,
                       "An empty cancelled stream must not start a second 90-second recognition")
        let canStart = await session.canStartRecording
        let disconnects = await client.disconnectCount
        XCTAssertTrue(canStart)
        XCTAssertEqual(disconnects, 1)
    }

    func testNormalStopOfEmptyStreamStillRetriesAndRetainsRecoveredText() async throws {
        let retryCount = OSAllocatedUnfairLock(initialState: 0)
        let session = try await makeSession(
            client: FinishingASRStub(), retryCount: retryCount, retryResult: "recovered speech"
        )

        await session.stopRecording()

        XCTAssertEqual(retryCount.withLock { $0 }, 1)
        let text = await session.stoppedTextForTesting()
        XCTAssertEqual(text, "recovered speech")
    }

    func testCancellationDuringFinalizationAlsoSkipsEmptyRetry() async throws {
        let endAudioCalled = expectation(description: "original finalization started")
        let client = FinishingASRStub(onEndAudio: { endAudioCalled.fulfill() })
        let retryCount = OSAllocatedUnfairLock(initialState: 0)
        let session = try await makeSession(client: client, retryCount: retryCount)
        let stopTask = Task { await session.stopRecording() }
        await fulfillment(of: [endAudioCalled], timeout: 2)

        await session.abortInjection()
        await stopTask.value

        XCTAssertEqual(retryCount.withLock { $0 }, 0)
        let canStart = await session.canStartRecording
        XCTAssertTrue(canStart)
    }

    func testLateFinalTextDuringDrainIsStillRetainedAfterCancellation() async throws {
        // Deliberately arrive after the original 2-second final-result wait.
        let client = FinishingASRStub(finalText: "late speech", finalDelay: .milliseconds(2200))
        let retryCount = OSAllocatedUnfairLock(initialState: 0)
        let session = try await makeSession(client: client, retryCount: retryCount)

        await session.abortInjection()
        await session.stopRecording()

        XCTAssertEqual(retryCount.withLock { $0 }, 0)
        let text = await session.stoppedTextForTesting()
        XCTAssertEqual(text, "late speech")
    }

    func testEarlierTextIsNotForgottenWhenProviderClearsTranscript() async throws {
        let transcripts = [
            RecognitionTranscript(confirmedSegments: [], partialText: "partial speech", authoritativeText: "", isFinal: false),
            RecognitionTranscript(confirmedSegments: [], partialText: "", authoritativeText: "authoritative speech", isFinal: false),
            // A whitespace-only authoritative update must not mask composed text.
            RecognitionTranscript(confirmedSegments: [], partialText: "composed speech", authoritativeText: " ", isFinal: false),
        ]
        for transcript in transcripts {
            let retryCount = OSAllocatedUnfairLock(initialState: 0)
            let session = try await makeSession(
                client: FinishingASRStub(), retryCount: retryCount, retryResult: "recovered speech"
            )
            await session.ingestASREventForTesting(.transcript(transcript))
            await session.ingestASREventForTesting(.transcript(.empty))

            await session.abortInjection()
            await session.stopRecording()

            XCTAssertEqual(retryCount.withLock { $0 }, 1)
            let text = await session.stoppedTextForTesting()
            XCTAssertEqual(text, "recovered speech")
        }
    }

    func testWhitespaceOnlyUpdatesDoNotTriggerCancelledRetry() async throws {
        let retryCount = OSAllocatedUnfairLock(initialState: 0)
        let session = try await makeSession(client: FinishingASRStub(), retryCount: retryCount)
        await session.ingestASREventForTesting(.transcript(RecognitionTranscript(
            confirmedSegments: [], partialText: " \n", authoritativeText: "\t ", isFinal: false
        )))

        await session.abortInjection()
        await session.stopRecording()

        XCTAssertEqual(retryCount.withLock { $0 }, 0)
        let canStart = await session.canStartRecording
        XCTAssertTrue(canStart)
    }

    func testCancelledEmptyStreamStillRetriesWhenEndAudioFails() async throws {
        let retryCount = OSAllocatedUnfairLock(initialState: 0)
        let session = try await makeSession(
            client: FinishingASRStub(endAudioFails: true), retryCount: retryCount
        )

        await session.abortInjection()
        await session.stopRecording()

        XCTAssertEqual(retryCount.withLock { $0 }, 1)
    }

    func testCancelledEmptyStreamStillRetriesAfterExplicitStreamingError() async throws {
        let retryCount = OSAllocatedUnfairLock(initialState: 0)
        let session = try await makeSession(
            client: FinishingASRStub(emitsError: true), retryCount: retryCount
        )

        await session.abortInjection()
        await session.stopRecording()

        XCTAssertEqual(retryCount.withLock { $0 }, 1)
    }

    func testCancelledEmptyStreamStillRetriesAfterUploadFailure() async throws {
        let retryCount = OSAllocatedUnfairLock(initialState: 0)
        let session = try await makeSession(
            client: FinishingASRStub(), retryCount: retryCount, uploadFailed: true
        )

        await session.abortInjection()
        await session.stopRecording()

        XCTAssertEqual(retryCount.withLock { $0 }, 1)
    }

    func testCancelledEmptyStreamStillRetriesIfAudioUploadDidNotDrain() async throws {
        let sender = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        defer { sender.cancel() }
        let retryCount = OSAllocatedUnfairLock(initialState: 0)
        let session = try await makeSession(
            client: FinishingASRStub(), retryCount: retryCount, audioSender: sender
        )

        await session.abortInjection()
        await session.stopRecording()

        XCTAssertEqual(retryCount.withLock { $0 }, 1)
    }

    func testCancelledBatchProviderStillRetriesWithoutStreamingText() async throws {
        // Batch providers are not expected to return text during recording.
        let retryCount = OSAllocatedUnfairLock(initialState: 0)
        let session = try await makeSession(
            client: FinishingASRStub(), retryCount: retryCount, provider: .stepfunBatch
        )

        await session.abortInjection()
        await session.stopRecording()

        XCTAssertEqual(retryCount.withLock { $0 }, 1)
    }

    private func makeSession(
        client: FinishingASRStub,
        retryCount: OSAllocatedUnfairLock<Int>,
        provider: ASRProvider = .stepfun,
        policy: ClipboardOutputPolicy = .cancelProcessed,
        uploadFailed: Bool = false,
        audioSender: Task<Void, Never>? = nil,
        retryResult: String? = nil
    ) async throws -> RecognitionSession {
        let config = try XCTUnwrap(StepFunASRConfig(credentials: ["apiKey": "test-not-used"]))
        let session = RecognitionSession()
        await session.prepareRecordingStopForTesting(
            client: client, config: config, provider: provider, policy: policy,
            uploadFailed: uploadFailed, audioSender: audioSender
        ) {
            retryCount.withLock { $0 += 1 }
            return retryResult
        }
        return session
    }
}

/// A provider that accepts endAudio but may omit its final event, matching the
/// reported StepFun trace. No microphone, network, or credentials are used.
private actor FinishingASRStub: SpeechRecognizer {
    private enum StubError: Error { case transportFailure }
    private let stream: AsyncStream<RecognitionEvent>
    private let continuation: AsyncStream<RecognitionEvent>.Continuation
    private let endAudioFails: Bool
    private let emitsError: Bool
    private let finalText: String?
    private let finalDelay: Duration
    private let onEndAudio: @Sendable () -> Void
    private var finalTask: Task<Void, Never>?
    private(set) var disconnectCount = 0

    init(
        endAudioFails: Bool = false,
        emitsError: Bool = false,
        finalText: String? = nil,
        finalDelay: Duration = .zero,
        onEndAudio: @escaping @Sendable () -> Void = {}
    ) {
        (stream, continuation) = AsyncStream.makeStream()
        self.endAudioFails = endAudioFails
        self.emitsError = emitsError
        self.finalText = finalText
        self.finalDelay = finalDelay
        self.onEndAudio = onEndAudio
    }

    var events: AsyncStream<RecognitionEvent> { stream }
    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {}
    func sendAudio(_ data: Data) async throws {}
    func endAudio() async throws {
        onEndAudio()
        if endAudioFails { throw StubError.transportFailure }
        if emitsError {
            continuation.yield(.error(StubError.transportFailure))
            continuation.finish()
        }
        if let finalText {
            let continuation = continuation
            let delay = finalDelay
            finalTask = Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                continuation.yield(.transcript(RecognitionTranscript(
                    confirmedSegments: [], partialText: "", authoritativeText: finalText, isFinal: true
                )))
                continuation.yield(.completed)
                continuation.finish()
            }
        }
    }
    func disconnect() async {
        disconnectCount += 1
        finalTask?.cancel()
        finalTask = nil
        continuation.finish()
    }
}
