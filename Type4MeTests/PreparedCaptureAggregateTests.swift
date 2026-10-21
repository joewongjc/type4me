import XCTest
@testable import Type4Me

final class PreparedCaptureAggregateTests: XCTestCase {
    func testTopologyObserverTriggerCallsOnChange() {
        let exp = expectation(description: "Topology change called")
        let queue = DispatchQueue(label: "test.topology.queue")
        let observer = AggregateTopologyObserver(testAggregateUID: "TestAggUID", queue: queue) {
            exp.fulfill()
        }

        observer.triggerChangeForTesting()
        wait(for: [exp], timeout: 1.0)
    }

    func testTopologyObserverInvalidatePreventsSubsequentCallbacks() {
        let exp = expectation(description: "Should not be called")
        exp.isInverted = true

        let queue = DispatchQueue(label: "test.topology.queue")
        let observer = AggregateTopologyObserver(testAggregateUID: "TestAggUID", queue: queue) {
            exp.fulfill()
        }

        observer.invalidate()
        observer.triggerChangeForTesting()

        wait(for: [exp], timeout: 0.2)
    }

    func testAggregatePolicyDisallowsWhenBluetoothPresent() {
        // When aggregate contains bluetooth, policy strictly disallows preparation
        XCTAssertFalse(
            AudioCapturePreparationPolicy.allowsPreparedSession(
                for: .virtual,
                isAggregateWithBluetooth: true
            )
        )

        // When aggregate has NO bluetooth, policy allows preparation
        XCTAssertTrue(
            AudioCapturePreparationPolicy.allowsPreparedSession(
                for: .virtual,
                isAggregateWithBluetooth: false
            )
        )
    }
}
