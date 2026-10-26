import XCTest
@testable import Type4Me

final class CrossModeFinishRouterTests: XCTestCase {
    func testPreparingPhaseAlwaysCancels() {
        let decision = CrossModeFinishRouter.decide(
            phase: .preparing,
            startingMode: .direct,
            newMode: .translation(),
            resolvedMode: nil,
            allowsModeSwitch: true
        )
        XCTAssertEqual(decision, CrossModeFinishDecision.cancel)
    }

    func testRecordingPhaseProceedsToFinish() {
        let decision = CrossModeFinishRouter.decide(
            phase: .recording,
            startingMode: .direct,
            newMode: .translation(),
            resolvedMode: nil,
            allowsModeSwitch: false
        )
        XCTAssertEqual(decision, CrossModeFinishDecision.finish(processingMode: .direct, allowsModeSwitch: false))
    }

    func testRecordingPhaseWithModeSwitchAllowed() {
        let targetMode = ProcessingMode.translation()
        let decision = CrossModeFinishRouter.decide(
            phase: .recording,
            startingMode: .direct,
            newMode: targetMode,
            resolvedMode: targetMode,
            allowsModeSwitch: true
        )
        XCTAssertEqual(decision, CrossModeFinishDecision.finish(processingMode: targetMode, allowsModeSwitch: true))
    }

    func testRecoveringPhaseReturnsRecover() {
        let decision = CrossModeFinishRouter.decide(
            phase: .recovering,
            startingMode: .direct,
            newMode: .translation(),
            resolvedMode: nil,
            allowsModeSwitch: true
        )
        XCTAssertEqual(decision, CrossModeFinishDecision.recover)
    }

    func testOtherPhaseIgnored() {
        let decision = CrossModeFinishRouter.decide(
            phase: .hidden,
            startingMode: .direct,
            newMode: .translation(),
            resolvedMode: nil,
            allowsModeSwitch: true
        )
        XCTAssertEqual(decision, CrossModeFinishDecision.ignore)
    }
}
