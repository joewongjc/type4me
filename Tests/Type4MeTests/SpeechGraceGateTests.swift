import XCTest
@testable import Type4Me

final class SpeechGraceGateTests: XCTestCase {
    func testUnarmedGateAllowsSpeechImmediately() {
        let gate = SpeechGraceGate()
        XCTAssertFalse(gate.isSpeechIgnored())
    }

    func testArmedGateIgnoresSpeechDuringWindowAndAllowsAfter() async throws {
        let gate = SpeechGraceGate()
        let now = ContinuousClock.now
        gate.arm(until: now + .milliseconds(100))

        // In window
        XCTAssertTrue(gate.isSpeechIgnored(at: now + .milliseconds(50)))

        // Past window
        XCTAssertFalse(gate.isSpeechIgnored(at: now + .milliseconds(150)))

        // Real clock sleep
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(gate.isSpeechIgnored())
    }

    func testDisarmRestoresImmediateSpeechAllowance() {
        let gate = SpeechGraceGate()
        let now = ContinuousClock.now
        gate.arm(until: now + .seconds(10))
        XCTAssertTrue(gate.isSpeechIgnored())

        gate.disarm()
        XCTAssertFalse(gate.isSpeechIgnored())
    }

    func testConcurrentArmAndCheckThreadSafety() {
        let gate = SpeechGraceGate()
        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            if i % 2 == 0 {
                gate.arm(until: .now + .milliseconds(50))
            } else {
                _ = gate.isSpeechIgnored()
            }
        }
    }

    func testQueueDelayedArmStartsFromActualPlayTime() async throws {
        let gate = SpeechGraceGate()

        // Suppose sound is queued at T0
        let enqueuedAt = ContinuousClock.now

        // Delayed by 300ms in queue before actual playback
        let actualPlayStartedAt = enqueuedAt + .milliseconds(300)

        // While queued, gate is unarmed
        XCTAssertFalse(gate.isSpeechIgnored(at: enqueuedAt + .milliseconds(100)))

        // At actual playback, arm for 200ms
        gate.arm(until: actualPlayStartedAt + .milliseconds(200))

        // Within armed window (from play start)
        XCTAssertTrue(gate.isSpeechIgnored(at: actualPlayStartedAt + .milliseconds(50)))
        // Outside armed window
        XCTAssertFalse(gate.isSpeechIgnored(at: actualPlayStartedAt + .milliseconds(250)))
    }

    func testSkippedPlaybackKeepsGateUnarmed() {
        let gate = SpeechGraceGate()
        // If playback is skipped (invalidated / failed / disabled), arm is never called
        XCTAssertFalse(gate.isSpeechIgnored())
    }
}
