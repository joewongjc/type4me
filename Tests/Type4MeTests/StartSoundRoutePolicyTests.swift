import XCTest
@testable import Type4Me

final class StartSoundRoutePolicyTests: XCTestCase {
    func testDisabledStartSoundRequiresNoSettle() {
        let requires = StartSoundRoutePolicy.requiresRouteSettle(
            startSoundEnabled: false,
            inputCategory: .bluetooth,
            input: (uid: "airpods-in", name: "AirPods Pro"),
            output: (uid: "airpods-in", name: "AirPods Pro", isBluetooth: true)
        )
        XCTAssertFalse(requires)
    }

    func testNonBluetoothInputRequiresNoSettle() {
        let requires = StartSoundRoutePolicy.requiresRouteSettle(
            startSoundEnabled: true,
            inputCategory: .builtIn,
            input: (uid: "builtin-mic", name: "MacBook Pro Microphone"),
            output: (uid: "airpods-out", name: "AirPods Pro", isBluetooth: true)
        )
        XCTAssertFalse(requires)
    }

    func testOutputIsSpeakerRequiresNoSettle() {
        let requires = StartSoundRoutePolicy.requiresRouteSettle(
            startSoundEnabled: true,
            inputCategory: .bluetooth,
            input: (uid: "airpods-in", name: "AirPods Pro"),
            output: (uid: "builtin-speaker", name: "MacBook Pro Speakers", isBluetooth: false)
        )
        XCTAssertFalse(requires)
    }

    func testSameUIDRequiresSettle() {
        let requires = StartSoundRoutePolicy.requiresRouteSettle(
            startSoundEnabled: true,
            inputCategory: .bluetooth,
            input: (uid: "airpods-uid-123", name: "AirPods Pro"),
            output: (uid: "airpods-uid-123", name: "AirPods Pro", isBluetooth: true)
        )
        XCTAssertTrue(requires)
    }

    func testDifferentUIDButSameNameAndBothBluetoothRequiresSettle() {
        let requires = StartSoundRoutePolicy.requiresRouteSettle(
            startSoundEnabled: true,
            inputCategory: .bluetooth,
            input: (uid: "airpods-in-uid", name: "Quentin's AirPods Pro"),
            output: (uid: "airpods-out-uid", name: "Quentin's AirPods Pro", isBluetooth: true)
        )
        XCTAssertTrue(requires)
    }

    func testDifferentUIDAndDifferentNameRequiresNoSettle() {
        let requires = StartSoundRoutePolicy.requiresRouteSettle(
            startSoundEnabled: true,
            inputCategory: .bluetooth,
            input: (uid: "headset-1", name: "Bluetooth Mic"),
            output: (uid: "speaker-2", name: "Bluetooth Boombox", isBluetooth: true)
        )
        XCTAssertFalse(requires)
    }

    func testMissingOutputRequiresNoSettle() {
        let requires = StartSoundRoutePolicy.requiresRouteSettle(
            startSoundEnabled: true,
            inputCategory: .bluetooth,
            input: (uid: "airpods-in", name: "AirPods Pro"),
            output: nil
        )
        XCTAssertFalse(requires)
    }
}
