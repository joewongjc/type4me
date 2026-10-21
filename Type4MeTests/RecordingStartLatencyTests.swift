import XCTest
import Type4MeIntelliSenseCore
@testable import Type4Me
final class MockAudioCaptureEngine: NSObject, AudioCapturing, @unchecked Sendable {
    var selectedDeviceUID: String?
    var onAudioChunk: ((Data) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onFirstSample: (@Sendable (ContinuousClock.Instant) -> Void)?

    var lastStartInfo = AudioCaptureStartInfo(preparedStatus: "hit", deviceCategory: "builtIn")

    var startCallCount = 0
    var stopCallCount = 0

    func start() throws {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }

    func getRecordedAudio() -> Data {
        Data()
    }
}

private actor MockSpeechRecognizer: SpeechRecognizer {
    var events: AsyncStream<RecognitionEvent> {
        AsyncStream { _ in }
    }
    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {}
    func sendAudio(_ pcmData: Data) async throws {}
    func endAudio() async throws {}
    func disconnect() async {}
}

final class RecordingStartLatencyTests: XCTestCase {
    func testUnsupportedTranslationTargetReleasesEarlyCapture() async {
        let mockAudio = MockAudioCaptureEngine()
        let session = RecognitionSession(audioEngine: mockAudio)

        // Invalid translation language code triggers unsupportedTarget error in step 5
        var invalidMode = ProcessingMode.translation()
        invalidMode.translationTargetLanguageCode = "invalid-lang-code"
        await session.startRecording(mode: invalidMode)

        // Early capture was started...
        XCTAssertEqual(mockAudio.startCallCount, 1)
        // ...and defer { releaseEarlyCapture } released the microphone on error exit
        XCTAssertEqual(mockAudio.stopCallCount, 1)
        let state = await session.state
        XCTAssertEqual(state, RecognitionSession.SessionState.idle)
    }

    func testCancelRecordingWhileStartingReleasesCapture() async {
        let mockAudio = MockAudioCaptureEngine()
        let session = RecognitionSession(audioEngine: mockAudio)

        let task = Task {
            await session.startRecording(mode: .direct)
        }

        // Cancel quickly while starting
        await session.cancelRecording()
        _ = await task.value

        XCTAssertEqual(mockAudio.startCallCount, 1)
        XCTAssertGreaterThanOrEqual(mockAudio.stopCallCount, 1)
        let state = await session.state
        XCTAssertEqual(state, RecognitionSession.SessionState.idle)
    }

    func testSuspendedIntelliSenseLoadCancelledDoesNotMutateStateWhenResumed() async throws {
        let mockAudio = MockAudioCaptureEngine()
        var continuation: CheckedContinuation<IntelliSenseSettings, Never>?

        let session = RecognitionSession(
            audioEngine: mockAudio,
            intelliSenseSettingsLoader: {
                await withCheckedContinuation { cont in
                    continuation = cont
                }
            }
        )

        let startTask = Task {
            await session.startRecording(mode: .intelliSense)
        }

        // Wait until continuation is captured (suspended in loader)
        for _ in 0..<50 {
            if continuation != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(continuation)

        // User releases hotkey before settings finish loading
        await session.cancelRecording()
        let stateAfterCancel = await session.state
        XCTAssertEqual(stateAfterCancel, RecognitionSession.SessionState.idle)
        let initialStopCalls = mockAudio.stopCallCount

        // Now resume the old settings loader
        continuation?.resume(returning: IntelliSenseSettings())
        _ = await startTask.value

        // State remains idle, old call did not overwrite state or stop new things
        let stateFinal = await session.state
        XCTAssertEqual(stateFinal, RecognitionSession.SessionState.idle)
        XCTAssertEqual(mockAudio.stopCallCount, initialStopCalls)
    }

    func testSuspendedIntelliSenseLoadDoesNotInterruptNewRecordingRound() async throws {
        let mockAudio = MockAudioCaptureEngine()
        var continuation: CheckedContinuation<IntelliSenseSettings, Never>?

        let session = RecognitionSession(
            audioEngine: mockAudio,
            intelliSenseSettingsLoader: {
                await withCheckedContinuation { cont in
                    continuation = cont
                }
            }
        )
        await session.setInjectedASRClientForTesting(MockSpeechRecognizer())
        // Round 1: IntelliSense
        let round1Task = Task {
            await session.startRecording(mode: .intelliSense)
        }

        for _ in 0..<50 {
            if continuation != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(continuation)

        // Cancel Round 1
        await session.cancelRecording()
        XCTAssertEqual(mockAudio.stopCallCount, 1)

        // Round 2: Normal Direct recording begins and starts early capture
        let round2Task = Task {
            await session.startRecording(mode: .direct)
        }

        for _ in 0..<50 {
            if mockAudio.startCallCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(mockAudio.startCallCount, 2)

        // Now resume Round 1's old loader
        continuation?.resume(returning: IntelliSenseSettings())
        _ = await round1Task.value

        // Assert: Round 2 is NOT stopped by Round 1's resume
        XCTAssertEqual(mockAudio.stopCallCount, 1)
        // Round 2 still owns the capture callbacks; the stale round must not clear them.
        XCTAssertNotNil(mockAudio.onAudioChunk)
        XCTAssertNotNil(mockAudio.onAudioLevel)
        XCTAssertNotNil(mockAudio.onFirstSample)
        _ = await round2Task.value
        XCTAssertNotNil(mockAudio.onAudioChunk)
        XCTAssertNotNil(mockAudio.onAudioLevel)
        XCTAssertNotNil(mockAudio.onFirstSample)
    }
}
