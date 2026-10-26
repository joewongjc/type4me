import XCTest
@testable import Type4Me

final class StartSoundVolumeScheduleTests: XCTestCase {
    func testPlayedSchedulesAfterSoundDuration() {
        let now = ContinuousClock.now
        let duration = Duration.milliseconds(250)
        let schedule = StartSoundPlaybackDecision.volumeSchedule(
            for: .played(startedAt: now),
            soundDuration: duration
        )
        XCTAssertEqual(schedule, .afterSound(now + duration))
    }

    func testDisabledSchedulesImmediately() {
        let schedule = StartSoundPlaybackDecision.volumeSchedule(
            for: .disabled,
            soundDuration: .milliseconds(250)
        )
        XCTAssertEqual(schedule, .immediately)
    }

    func testNoPlayerOrPlayFailedSchedulesImmediately() {
        let sched1 = StartSoundPlaybackDecision.volumeSchedule(
            for: .skipped(.noPlayer),
            soundDuration: .milliseconds(250)
        )
        XCTAssertEqual(sched1, .immediately)

        let sched2 = StartSoundPlaybackDecision.volumeSchedule(
            for: .skipped(.playFailed),
            soundDuration: .milliseconds(250)
        )
        XCTAssertEqual(sched2, .immediately)
    }

    func testInvalidatedDoesNotLowerVolume() {
        let schedule = StartSoundPlaybackDecision.volumeSchedule(
            for: .skipped(.invalidated),
            soundDuration: .milliseconds(250)
        )
        XCTAssertEqual(schedule, .none)
    }
}

final class StartSoundPlaybackDecisionTests: XCTestCase {
    func testCancelledOutcomeDoesNotPlay() {
        let shouldPlay = StartSoundPlaybackDecision.shouldPlayStartSound(
            outcome: .cancelled,
            barPhase: .recording,
            readyGeneration: 1,
            expectedGeneration: 1
        )
        XCTAssertFalse(shouldPlay)
    }

    func testNonRecordingPhaseDoesNotPlay() {
        let shouldPlay = StartSoundPlaybackDecision.shouldPlayStartSound(
            outcome: .switched,
            barPhase: .preparing,
            readyGeneration: 1,
            expectedGeneration: 1
        )
        XCTAssertFalse(shouldPlay)
    }

    func testGenerationMismatchDoesNotPlay() {
        let shouldPlay = StartSoundPlaybackDecision.shouldPlayStartSound(
            outcome: .switched,
            barPhase: .recording,
            readyGeneration: 2, // New generation already arrived
            expectedGeneration: 1
        )
        XCTAssertFalse(shouldPlay)
    }

    func testAllConditionsMetPlays() {
        let shouldPlay = StartSoundPlaybackDecision.shouldPlayStartSound(
            outcome: .switched,
            barPhase: .recording,
            readyGeneration: 1,
            expectedGeneration: 1
        )
        XCTAssertTrue(shouldPlay)
    }
}
