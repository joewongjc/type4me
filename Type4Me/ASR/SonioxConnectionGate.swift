import Foundation

actor SonioxConnectionGate {

    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var hasOpened = false
    private var failure: Error?

    func waitUntilOpen(timeout: Duration) async throws {
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            self.markFailure(SonioxASRError.handshakeTimedOut)
        }

        defer { timeoutTask.cancel() }
        try await wait()
    }

    func waitForValidationWindow(timeout: Duration) async throws {
        if let failure {
            throw failure
        }
        try? await Task.sleep(for: timeout)
        if let failure {
            throw failure
        }
    }

    func markOpen() {
        guard !hasOpened else { return }
        hasOpened = true
        continuation?.resume()
        continuation = nil
    }

    func markFailure(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func wait() async throws {
        if hasOpened { return }
        if let failure {
            throw failure
        }

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }
}
