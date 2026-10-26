import XCTest
@testable import Type4Me

final class AudioCapturePreparationPolicyTests: XCTestCase {
    func testBuiltInAndExternalAlwaysAllowPreparation() {
        XCTAssertTrue(AudioCapturePreparationPolicy.allowsPreparedSession(for: .builtIn, isAggregateWithBluetooth: false))
        XCTAssertTrue(AudioCapturePreparationPolicy.allowsPreparedSession(for: .builtIn, isAggregateWithBluetooth: true))
        XCTAssertTrue(AudioCapturePreparationPolicy.allowsPreparedSession(for: .external, isAggregateWithBluetooth: false))
        XCTAssertTrue(AudioCapturePreparationPolicy.allowsPreparedSession(for: .external, isAggregateWithBluetooth: true))
    }

    func testVirtualDeviceOnlyAllowsWhenNoBluetooth() {
        XCTAssertTrue(AudioCapturePreparationPolicy.allowsPreparedSession(for: .virtual, isAggregateWithBluetooth: false))
        XCTAssertFalse(AudioCapturePreparationPolicy.allowsPreparedSession(for: .virtual, isAggregateWithBluetooth: true))
    }

    func testBluetoothAndOtherNeverAllowPreparation() {
        XCTAssertFalse(AudioCapturePreparationPolicy.allowsPreparedSession(for: .bluetooth, isAggregateWithBluetooth: false))
        XCTAssertFalse(AudioCapturePreparationPolicy.allowsPreparedSession(for: .bluetooth, isAggregateWithBluetooth: true))
        XCTAssertFalse(AudioCapturePreparationPolicy.allowsPreparedSession(for: .other, isAggregateWithBluetooth: false))
        XCTAssertFalse(AudioCapturePreparationPolicy.allowsPreparedSession(for: .other, isAggregateWithBluetooth: true))
    }

    private func retain(
        enabled: Bool = true,
        pending: Bool = false,
        captured: String? = "BuiltInMicrophoneDevice",
        category: AudioInputDeviceCategory = .builtIn,
        aggregateWithBluetooth: Bool = false,
        target: String? = "BuiltInMicrophoneDevice"
    ) -> Bool {
        AudioCapturePreparationPolicy.shouldRetainAfterStop(
            isEnabled: enabled,
            pendingInvalidate: pending,
            capturedDeviceUID: captured,
            capturedCategory: category,
            capturedIsAggregateWithBluetooth: aggregateWithBluetooth,
            targetDeviceUID: target
        )
    }

    func testRetainsEligibleGraphWhenCapturedDeviceIsStillTheTarget() {
        XCTAssertTrue(retain())
        XCTAssertTrue(retain(captured: "USB", category: .external, target: "USB"))
    }

    func testBluetoothGraphIsDetachedEvenWhenTargetMovedToBuiltIn() {
        // Recording started on AirPods, system default moved to the built-in mic mid-recording.
        XCTAssertFalse(retain(captured: "AirPods", category: .bluetooth, target: "BuiltInMicrophoneDevice"))
        XCTAssertFalse(retain(captured: "AirPods", category: .bluetooth, target: "AirPods"))
    }

    func testEligibleGraphIsDetachedWhenTargetMoved() {
        XCTAssertFalse(retain(target: "USB"))
        XCTAssertFalse(retain(target: nil))
        XCTAssertFalse(retain(captured: nil))
    }

    func testPendingInvalidateOrDisabledAlwaysDetaches() {
        XCTAssertFalse(retain(pending: true))
        XCTAssertFalse(retain(enabled: false))
    }

    func testAggregateWithBluetoothSubDeviceIsDetached() {
        XCTAssertFalse(retain(captured: "Agg", category: .virtual, aggregateWithBluetooth: true, target: "Agg"))
        XCTAssertTrue(retain(captured: "Agg", category: .virtual, aggregateWithBluetooth: false, target: "Agg"))
    }
}
