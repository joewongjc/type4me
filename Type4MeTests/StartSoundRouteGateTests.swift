import XCTest
import CoreAudio
import AVFoundation
@testable import Type4Me

final class MockAudioOutputRouteMonitor: AudioOutputRouteMonitor, @unchecked Sendable {
    var rateToReturn: Double?
    var onChangeHandler: (@Sendable (Double) -> Void)?

    func currentNominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        rateToReturn
    }

    func addRouteChangeListener(
        for deviceID: AudioDeviceID,
        queue: DispatchQueue,
        onChange: @escaping @Sendable (Double) -> Void
    ) -> (any Sendable)? {
        self.onChangeHandler = onChange
        return "mock-token"
    }

    func removeRouteChangeListener(_ token: any Sendable) {
        self.onChangeHandler = nil
    }
}

final class StartSoundRouteGateTests: XCTestCase {
    func testUnarmedGenerationReturnsCancelledImmediately() async {
        let gate = StartSoundRouteGate(routeMonitor: MockAudioOutputRouteMonitor())
        let outcome = await gate.waitUntilSettled(generation: 1)
        XCTAssertEqual(outcome, .cancelled)
    }

    func testAlreadySettledWhenSampleRateIsLow() async {
        let monitor = MockAudioOutputRouteMonitor()
        monitor.rateToReturn = 16000.0 // Low HFP sample rate
        let gate = StartSoundRouteGate(routeMonitor: monitor)

        // For non-nil input device, arm with nil inputDevice simulates fallback to notRequired
        gate.arm(generation: 1, inputDevice: nil)
        let outcome = await gate.waitUntilSettled(generation: 1)
        XCTAssertEqual(outcome, .notRequired)
    }

    func testDisarmReturnsCancelledToWaiters() async {
        let gate = StartSoundRouteGate(routeMonitor: MockAudioOutputRouteMonitor())
        gate.arm(generation: 1, inputDevice: nil)

        gate.disarm(generation: 1)
        let outcome = await gate.waitUntilSettled(generation: 1)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(gate.isCurrent(generation: 1))
    }

    func testArmingNextGenerationCancelsPreviousWaiters() async {
        let gate = StartSoundRouteGate(routeMonitor: MockAudioOutputRouteMonitor())
        gate.arm(generation: 1, inputDevice: nil)

        // Arm generation 2
        gate.arm(generation: 2, inputDevice: nil)

        XCTAssertFalse(gate.isCurrent(generation: 1))
        XCTAssertTrue(gate.isCurrent(generation: 2))

        let outcome1 = await gate.waitUntilSettled(generation: 1)
        XCTAssertEqual(outcome1, .cancelled)

        let outcome2 = await gate.waitUntilSettled(generation: 2)
        XCTAssertEqual(outcome2, .notRequired)
    }

    func testDisarmingStaleGenerationDoesNotCancelCurrent() async {
        let gate = StartSoundRouteGate(routeMonitor: MockAudioOutputRouteMonitor())
        gate.arm(generation: 2, inputDevice: nil)

        gate.disarm(generation: 1) // Stale generation
        XCTAssertTrue(gate.isCurrent(generation: 2))

        let outcome = await gate.waitUntilSettled(generation: 2)
        XCTAssertEqual(outcome, .notRequired)
    }
}
