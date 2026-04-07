import Foundation
import XCTest
@testable import Type4Me

final class DeepgramWebSocketDelegateTests: XCTestCase {

    func testDidCloseWith_beforeHandshakeMarksClosedBeforeHandshakeFailure() async {
        let gate = DeepgramConnectionGate()
        let delegate = DeepgramWebSocketDelegate(connectionGate: gate)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "wss://example.com/socket")!)

        delegate.urlSession(
            session,
            webSocketTask: task,
            didCloseWith: .goingAway,
            reason: Data("bye".utf8)
        )

        do {
            try await gate.waitUntilOpen(timeout: .milliseconds(50))
            XCTFail("Expected handshake wait to fail")
        } catch {
            guard case let DeepgramASRError.closedBeforeHandshake(code, reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }

            XCTAssertEqual(code, Int(URLSessionWebSocketTask.CloseCode.goingAway.rawValue))
            XCTAssertEqual(reason, "bye")
        }
    }

    func testDidCloseWith_afterHandshakeOpens_doesNotOverrideOpenState() async throws {
        let gate = DeepgramConnectionGate()
        let delegate = DeepgramWebSocketDelegate(connectionGate: gate)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "wss://example.com/socket")!)

        delegate.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
        try await Task.sleep(for: .milliseconds(20))

        delegate.urlSession(
            session,
            webSocketTask: task,
            didCloseWith: .normalClosure,
            reason: Data("normal".utf8)
        )
        try await Task.sleep(for: .milliseconds(20))

        try await gate.waitUntilOpen(timeout: .milliseconds(50))
        let opened = await gate.hasOpened
        XCTAssertTrue(opened)
    }

    func testDidCloseWith_afterHandshakeRecordsUnexpectedCloseError() async throws {
        let gate = DeepgramConnectionGate()
        let closeTracker = DeepgramCloseTracker()
        let delegate = DeepgramWebSocketDelegate(connectionGate: gate, closeTracker: closeTracker)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "wss://example.com/socket")!)

        delegate.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
        try await Task.sleep(for: .milliseconds(20))

        delegate.urlSession(
            session,
            webSocketTask: task,
            didCloseWith: .policyViolation,
            reason: Data("bad payload".utf8)
        )
        try await Task.sleep(for: .milliseconds(20))

        let error = await closeTracker.consumeCloseError()
        guard let error,
              case let DeepgramASRError.closed(code, reason) = error
        else {
            return XCTFail("Expected tracked post-handshake close error, got \(String(describing: error))")
        }

        XCTAssertEqual(code, Int(URLSessionWebSocketTask.CloseCode.policyViolation.rawValue))
        XCTAssertEqual(reason, "bad payload")
    }

    func testDidCloseWith_afterHandshakeIgnoresNormalClosure() async throws {
        let gate = DeepgramConnectionGate()
        let closeTracker = DeepgramCloseTracker()
        let delegate = DeepgramWebSocketDelegate(connectionGate: gate, closeTracker: closeTracker)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "wss://example.com/socket")!)

        delegate.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
        try await Task.sleep(for: .milliseconds(20))

        delegate.urlSession(
            session,
            webSocketTask: task,
            didCloseWith: .normalClosure,
            reason: Data("ok".utf8)
        )
        try await Task.sleep(for: .milliseconds(20))

        let error = await closeTracker.consumeCloseError()
        XCTAssertNil(error)
    }
}
