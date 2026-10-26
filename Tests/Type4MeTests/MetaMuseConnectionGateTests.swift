import XCTest
@testable import Type4Me

final class MetaMuseConnectionGateTests: XCTestCase {

    func testWaitUntilOpen_succeedsWhenMarkedOpen() async throws {
        let gate = MetaMuseConnectionGate()

        Task {
            try? await Task.sleep(for: .milliseconds(15))
            await gate.markOpen()
        }

        try await gate.waitUntilOpen(timeout: .milliseconds(200))
        let isOpen = await gate.isOpen
        XCTAssertTrue(isOpen)
    }

    func testWaitUntilOpen_failsOnTimeout() async {
        let gate = MetaMuseConnectionGate()

        do {
            try await gate.waitUntilOpen(timeout: .milliseconds(20))
            XCTFail("Expected timeout")
        } catch {
            guard case MetaMuseASRError.handshakeTimedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testWaitUntilOpen_throwsMarkedFailure() async {
        let gate = MetaMuseConnectionGate()
        let failure = MetaMuseASRError.authenticationFailed("Invalid key")

        await gate.markFailure(failure)

        do {
            try await gate.waitUntilOpen(timeout: .milliseconds(100))
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? MetaMuseASRError, failure)
        }
    }

    func testWaitUntilReady_succeedsWhenMarkedReady() async throws {
        let gate = MetaMuseConnectionGate()

        Task {
            try? await Task.sleep(for: .milliseconds(15))
            await gate.markReady(sessionId: "test_session_xyz")
        }

        try await gate.waitUntilReady(timeout: .milliseconds(200))
        let isReady = await gate.isReady
        let sessionId = await gate.sessionId
        XCTAssertTrue(isReady)
        XCTAssertEqual(sessionId, "test_session_xyz")
    }

    func testCloseTracker_recordsNonNormalClose() async {
        let tracker = MetaMuseCloseTracker()

        await tracker.recordClose(code: .abnormalClosure, reason: "Connection dropped")
        let error = await tracker.consumeCloseError()

        XCTAssertNotNil(error)
        guard let museError = error as? MetaMuseASRError,
              case .closed(let code, let reason) = museError
        else {
            return XCTFail("Unexpected error: \(String(describing: error))")
        }
        XCTAssertEqual(code, URLSessionWebSocketTask.CloseCode.abnormalClosure.rawValue)
        XCTAssertEqual(reason, "Connection dropped")

        // Subsequent consume returns nil
        let secondConsume = await tracker.consumeCloseError()
        XCTAssertNil(secondConsume)
    }

    func testCloseTracker_ignoresNormalClosure() async {
        let tracker = MetaMuseCloseTracker()

        await tracker.recordClose(code: .normalClosure, reason: nil)
        let error = await tracker.consumeCloseError()
        XCTAssertNil(error)
    }
}
