import Foundation

actor DeepgramConnectionGate {

    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var isOpen = false
    private var failure: Error?

    var hasOpened: Bool { isOpen }

    func waitUntilOpen(timeout: Duration) async throws {
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            self.markFailure(DeepgramASRError.handshakeTimedOut)
        }

        defer { timeoutTask.cancel() }
        try await wait()
    }

    func markOpen() {
        guard !isOpen else { return }
        isOpen = true
        continuation?.resume()
        continuation = nil
    }

    func markFailure(_ error: Error) {
        guard !isOpen, failure == nil else { return }
        failure = error
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func wait() async throws {
        if isOpen { return }
        if let failure { throw failure }

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }
}
