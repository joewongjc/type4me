import Foundation

actor GeminiConnectionGate {
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var setupContinuation: CheckedContinuation<Void, Error>?
    private(set) var isOpen = false
    private(set) var isSetupComplete = false
    private var failure: Error?

    var hasOpened: Bool { isOpen }
    var isReady: Bool { isSetupComplete }

    func waitUntilOpen(timeout: Duration = .seconds(5)) async throws {
        if isOpen { return }
        if let failure { throw failure }

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                self.markFailure(GeminiASRError.handshakeTimedOut)
            } catch {
                // Task was cancelled before timeout expired
            }
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { self.openContinuation = $0 }
    }

    func waitUntilSetupComplete(timeout: Duration = .seconds(5)) async throws {
        if isSetupComplete { return }
        if let failure { throw failure }

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                self.markFailure(GeminiASRError.setupTimedOut)
            } catch {
                // Task was cancelled before timeout expired
            }
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { self.setupContinuation = $0 }
    }

    func markOpen() {
        guard !isOpen else { return }
        isOpen = true
        openContinuation?.resume()
        openContinuation = nil
    }

    func markSetupComplete() {
        guard !isSetupComplete else { return }
        isSetupComplete = true
        setupContinuation?.resume()
        setupContinuation = nil
    }

    func markFailure(_ error: Error) {
        guard failure == nil else { return }
        failure = error

        if !isOpen {
            openContinuation?.resume(throwing: error)
            openContinuation = nil
        }
        if !isSetupComplete {
            setupContinuation?.resume(throwing: error)
            setupContinuation = nil
        }
    }
}

/// Records the first abnormal termination seen after the WebSocket is live so
/// the receive loop can report it instead of treating the stream as complete.
actor GeminiCloseTracker {

    private var closeError: Error?

    func recordClose(
        code: URLSessionWebSocketTask.CloseCode,
        reason: String?
    ) {
        guard closeError == nil,
              let error = GeminiASRError.unexpectedClose(code: code, reason: reason)
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

final class GeminiWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {

    private let gate: GeminiConnectionGate
    private let closeTracker: GeminiCloseTracker

    init(gate: GeminiConnectionGate, closeTracker: GeminiCloseTracker) {
        self.gate = gate
        self.closeTracker = closeTracker
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { await gate.markOpen() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task {
            await closeTracker.recordFailure(error)
            await gate.markFailure(error)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        Task {
            let isReady = await gate.isReady
            if isReady {
                // Post-setup closes must not be silently treated as a clean
                // end-of-stream: record them so the receive loop can report
                // the failure and let the session recover the audio.
                await closeTracker.recordClose(code: closeCode, reason: reasonText)
            } else {
                await gate.markFailure(
                    GeminiASRError.closedBeforeSetup(
                        code: Int(closeCode.rawValue),
                        reason: reasonText
                    )
                )
            }
        }
    }
}
