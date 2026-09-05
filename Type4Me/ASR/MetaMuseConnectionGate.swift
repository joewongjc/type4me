import Foundation
import os

actor MetaMuseConnectionGate {

    private var openContinuation: CheckedContinuation<Void, Error>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private(set) var isOpen = false
    private(set) var isReady = false
    private(set) var sessionId: String?
    private var failure: Error?

    func waitUntilOpen(timeout: Duration = .seconds(5)) async throws {
        if isOpen { return }
        if let failure { throw failure }

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                self.markFailure(MetaMuseASRError.handshakeTimedOut)
            } catch {
                // Cancelled
            }
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { self.openContinuation = $0 }
    }

    func waitUntilReady(timeout: Duration = .seconds(5)) async throws {
        if isReady { return }
        if let failure { throw failure }

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                self.markFailure(MetaMuseASRError.handshakeTimedOut)
            } catch {
                // Cancelled
            }
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { self.readyContinuation = $0 }
    }

    func markOpen() {
        guard !isOpen else { return }
        isOpen = true
        openContinuation?.resume()
        openContinuation = nil
    }

    func markReady(sessionId: String) {
        self.sessionId = sessionId
        guard !isReady else { return }
        isReady = true
        readyContinuation?.resume()
        readyContinuation = nil
    }

    func markFailure(_ error: Error) {
        guard failure == nil else { return }
        failure = error

        if !isOpen {
            openContinuation?.resume(throwing: error)
            openContinuation = nil
        }
        if !isReady {
            readyContinuation?.resume(throwing: error)
            readyContinuation = nil
        }
    }
}

actor MetaMuseCloseTracker {

    private var closeError: Error?

    static func unexpectedClose(
        code: URLSessionWebSocketTask.CloseCode,
        reason: String?
    ) -> MetaMuseASRError? {
        switch code {
        case .normalClosure, .goingAway, .noStatusReceived:
            return nil
        default:
            let errorReason = reason?.isEmpty == false ? reason : nil
            return .closed(code: code.rawValue, reason: errorReason)
        }
    }

    func recordClose(
        code: URLSessionWebSocketTask.CloseCode,
        reason: String?
    ) {
        guard closeError == nil,
              let error = Self.unexpectedClose(code: code, reason: reason)
        else { return }
        closeError = error
    }

    func recordFailure(_ error: Error) {
        guard closeError == nil else { return }
        closeError = error
    }

    func consumeCloseError() -> Error? {
        defer { closeError = nil }
        return closeError
    }
}

final class MetaMuseWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {

    private let gate: MetaMuseConnectionGate
    private let closeTracker: MetaMuseCloseTracker

    init(gate: MetaMuseConnectionGate, closeTracker: MetaMuseCloseTracker) {
        self.gate = gate
        self.closeTracker = closeTracker
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { await gate.markOpen() }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) }
        Task {
            await closeTracker.recordClose(code: closeCode, reason: reasonString)
            if MetaMuseCloseTracker.unexpectedClose(code: closeCode, reason: reasonString) != nil {
                await gate.markFailure(MetaMuseASRError.closedBeforeReady(code: closeCode.rawValue, reason: reasonString))
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task {
            await gate.markFailure(error)
        }
    }
}
