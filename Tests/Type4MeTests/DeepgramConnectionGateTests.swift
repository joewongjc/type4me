import XCTest
@testable import Type4Me

final class DeepgramConnectionGateTests: XCTestCase {

    func testWaitUntilOpen_returnsWhenHandshakeOpens() async throws {
        let gate = DeepgramConnectionGate()

        Task {
            try? await Task.sleep(for: .milliseconds(20))
            await gate.markOpen()
        }

        try await gate.waitUntilOpen(timeout: Duration.milliseconds(200))
    }

    func testWaitUntilOpen_throwsStoredFailure() async {
        let gate = DeepgramConnectionGate()
        let expected = URLError(.userAuthenticationRequired)

        await gate.markFailure(expected)

        do {
            try await gate.waitUntilOpen(timeout: Duration.milliseconds(200))
            XCTFail("Expected waitUntilOpen to throw")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, expected.code)
        }
    }

    func testMarkFailure_ignoredAfterMarkOpen() async throws {
        let gate = DeepgramConnectionGate()

        await gate.markOpen()
        await gate.markFailure(URLError(.cancelled))

        // Should still succeed since markOpen was called first
        try await gate.waitUntilOpen(timeout: Duration.milliseconds(50))
        let opened = await gate.hasOpened
        XCTAssertTrue(opened)
    }

    func testWaitUntilOpen_timesOutWhenNoHandshakeEventArrives() async {
        let gate = DeepgramConnectionGate()

        do {
            try await gate.waitUntilOpen(timeout: Duration.milliseconds(30))
            XCTFail("Expected waitUntilOpen to time out")
        } catch {
            guard case DeepgramASRError.handshakeTimedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
