import XCTest
@testable import Type4Me

final class MockSoundPlayer: SoundPlaying, @unchecked Sendable {
    var volume: Float = 1.0
    var currentTime: TimeInterval = 0
    var playResult: Bool = true
    var playCount = 0
    var stopCount = 0

    func play() -> Bool {
        playCount += 1
        return playResult
    }

    func stop() {
        stopCount += 1
    }
}
final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    var get: Bool {
        lock.withLock { value }
    }

    func set(_ newValue: Bool) {
        lock.withLock { value = newValue }
    }
}

final class StartSoundQueueTests: XCTestCase {
    override func tearDown() {
        SoundFeedback.customSoundQueue = nil
        SoundFeedback.customPlayerFactory = nil
        super.tearDown()
    }

    func testEnqueuedRequestInvalidatedBeforeExecutionIsSkipped() async {
        let testQueue = DispatchQueue(label: "test.sound.queue")
        SoundFeedback.customSoundQueue = testQueue
        let mockPlayer = MockSoundPlayer()
        SoundFeedback.customPlayerFactory = { _ in mockPlayer }

        let blockSemaphore = DispatchSemaphore(value: 0)
        // Block the queue
        testQueue.async {
            blockSemaphore.wait()
        }

        let isValid = TestFlag(true)
        let willPlayCalled = TestFlag(false)

        let request = StartSoundRequest(
            generation: 1,
            isStillValid: { isValid.get },
            rebuildPlayer: false,
            willPlay: { _ in willPlayCalled.set(true) }
        )

        // Enqueue playStart in background task
        let playTask = Task {
            await SoundFeedback.playStart(request)
        }

        // Now invalidate before releasing queue
        isValid.set(false)
        blockSemaphore.signal()

        let result = await playTask.value
        XCTAssertEqual(result, .skipped(.invalidated))
        XCTAssertFalse(willPlayCalled.get)
        XCTAssertEqual(mockPlayer.playCount, 0)
    }

    func testValidRequestCallsWillPlayAndPlays() async {
        let testQueue = DispatchQueue(label: "test.sound.queue")
        SoundFeedback.customSoundQueue = testQueue
        let mockPlayer = MockSoundPlayer()
        SoundFeedback.customPlayerFactory = { _ in mockPlayer }

        let willPlayCalled = TestFlag(false)
        let request = StartSoundRequest(
            generation: 1,
            isStillValid: { true },
            rebuildPlayer: false,
            willPlay: { _ in willPlayCalled.set(true) }
        )

        let result = await SoundFeedback.playStart(request)
        if case .played = result {
            XCTAssertTrue(willPlayCalled.get)
            XCTAssertEqual(mockPlayer.playCount, 1)
        } else {
            XCTFail("Expected .played but got \(result)")
        }
    }

    func testPlayFailureRetriesOnce() async {
        let testQueue = DispatchQueue(label: "test.sound.queue")
        SoundFeedback.customSoundQueue = testQueue
        let mockPlayer = MockSoundPlayer()
        mockPlayer.playResult = false // Always fails
        SoundFeedback.customPlayerFactory = { _ in mockPlayer }

        let request = StartSoundRequest(
            generation: 1,
            isStillValid: { true },
            rebuildPlayer: false,
            willPlay: nil
        )

        let result = await SoundFeedback.playStart(request)
        XCTAssertEqual(result, .skipped(.playFailed))
        // Tried once, then rebuilt and tried again (2 times total)
        XCTAssertEqual(mockPlayer.playCount, 2)
    }
}
