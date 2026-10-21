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
}
