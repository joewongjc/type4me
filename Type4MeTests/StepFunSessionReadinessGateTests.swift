import XCTest
@testable import Type4Me

final class StepFunSessionReadinessGateTests: XCTestCase {

    func testWaitUntilReadyReturnsAfterSessionUpdate() async throws {
        let gate = StepFunSessionReadinessGate()

        Task {
            try? await Task.sleep(for: .milliseconds(20))
            await gate.markReady()
        }

        try await gate.waitUntilReady(timeout: .milliseconds(200))
        let isReady = await gate.isReady
        XCTAssertTrue(isReady)
    }

    func testWaitUntilReadyThrowsStoredFailure() async {
        let gate = StepFunSessionReadinessGate()
        let expected = URLError(.userAuthenticationRequired)
        await gate.markFailure(expected)

        do {
            try await gate.waitUntilReady(timeout: .milliseconds(200))
            XCTFail("Expected stored failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, expected.code)
        }
    }

    func testFailureAfterReadyDoesNotInvalidateGate() async throws {
        let gate = StepFunSessionReadinessGate()
        await gate.markReady()
        await gate.markFailure(URLError(.networkConnectionLost))

        try await gate.waitUntilReady(timeout: .milliseconds(50))
        let isReady = await gate.isReady
        XCTAssertTrue(isReady)
    }

    func testWaitUntilReadyTimesOut() async {
        let gate = StepFunSessionReadinessGate()

        do {
            try await gate.waitUntilReady(timeout: .milliseconds(30))
            XCTFail("Expected handshake timeout")
        } catch {
            XCTAssertEqual(error as? StepFunASRError, .handshakeTimedOut)
        }
    }
}
