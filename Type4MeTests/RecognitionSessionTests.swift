import XCTest
@testable import Type4Me

final class RecognitionSessionTests: XCTestCase {
    override func tearDown() {
        KeychainService.selectedASRProvider = .volcano
    }

    func testInitialStateIsIdle() async {
        let session = RecognitionSession()
        let state = await session.state
        XCTAssertEqual(state, .idle)
    }

    func testSetState() async {
        let session = RecognitionSession()
        await session.setState(.recording)
        let state = await session.state
        XCTAssertEqual(state, .recording)
        await session.setState(.idle)
    }

    func testCanStartRecordingOnlyWhenIdle() async {
        let session = RecognitionSession()
        var canStart = await session.canStartRecording
        XCTAssertTrue(canStart)

        await session.setState(.recording)
        canStart = await session.canStartRecording
        XCTAssertFalse(canStart)
        await session.setState(.idle)
    }

    func testSwitchModeAppliesToDirect() async {
        KeychainService.selectedASRProvider = .volcano
        let session = RecognitionSession()

        await session.switchMode(to: .direct)

        let mode = await session.currentModeForTesting()
        XCTAssertEqual(mode.id, ProcessingMode.directId)
    }

    func testSwitchModeDirectWorksForSoniox() async {
        KeychainService.selectedASRProvider = .soniox
        let session = RecognitionSession()

        await session.switchMode(to: .direct)

        let mode = await session.currentModeForTesting()
        XCTAssertEqual(mode.id, ProcessingMode.directId)
    }

    func testStopRecordingWaitsForTailChunkBeforeEndAudio() async throws {
        KeychainService.selectedASRProvider = .volcano

        let tempDB = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        let audioEngine = FakeAudioEngine(tailChunk: Data([1, 2, 3, 4]))
        let recognizer = FakeSpeechRecognizer()
        let session = RecognitionSession(
            audioEngine: audioEngine,
            historyStore: HistoryStore(path: tempDB.path)
        )

        await session.prepareForStopTesting(client: recognizer)

        let stopTask = Task {
            await session.stopRecording()
        }

        try await Task.sleep(for: .milliseconds(100))
        let didCallEndAudio = await recognizer.didCallEndAudio
        let sentAudioBeforeResume = await recognizer.sentAudio
        XCTAssertFalse(didCallEndAudio)
        XCTAssertEqual(sentAudioBeforeResume, [])

        await recognizer.resumeSendAudio()
        await stopTask.value

        let sentAudioAfterResume = await recognizer.sentAudio
        let callOrder = await recognizer.callOrder
        XCTAssertEqual(sentAudioAfterResume, [Data([1, 2, 3, 4])])
        XCTAssertEqual(callOrder, ["sendAudio", "endAudio", "disconnect"])
    }
}

private final class FakeAudioEngine: AudioCapturing, @unchecked Sendable {
    var onAudioChunk: ((Data) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    private let tailChunk: Data

    init(tailChunk: Data) {
        self.tailChunk = tailChunk
    }

    func warmUp() {}
    func start() throws {}

    func stop() {
        onAudioChunk?(tailChunk)
    }
}

private actor FakeSpeechRecognizer: SpeechRecognizer {
    private var sendContinuation: CheckedContinuation<Void, Never>?
    private var shouldResumeImmediately = false
    private(set) var sentAudio: [Data] = []
    private(set) var callOrder: [String] = []

    var didCallEndAudio: Bool {
        callOrder.contains("endAudio")
    }

    var events: AsyncStream<RecognitionEvent> {
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        continuation.finish()
        return stream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {}

    func sendAudio(_ data: Data) async throws {
        callOrder.append("sendAudio")
        if shouldResumeImmediately {
            shouldResumeImmediately = false
            sentAudio.append(data)
            return
        }
        await withCheckedContinuation { continuation in
            sendContinuation = continuation
        }
        sentAudio.append(data)
    }

    func endAudio() async throws {
        callOrder.append("endAudio")
    }

    func disconnect() async {
        callOrder.append("disconnect")
    }

    func resumeSendAudio() {
        if let sendContinuation {
            sendContinuation.resume()
            self.sendContinuation = nil
        } else {
            shouldResumeImmediately = true
        }
    }
}
