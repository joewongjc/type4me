import Foundation

actor AssemblyAIConnectionGate {

    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var isReady = false
    private var failure: Error?

    var hasBegun: Bool { isReady }

    func waitUntilReady(timeout: Duration) async throws {
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            self.markFailure(AssemblyAIASRError.handshakeTimedOut)
        }

        defer { timeoutTask.cancel() }
        try await wait()
    }

    func markReady() {
        guard !isReady else { return }
        isReady = true
        continuation?.resume()
        continuation = nil
    }

    func markFailure(_ error: Error) {
        guard !isReady, failure == nil else { return }
        failure = error
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func wait() async throws {
        if isReady { return }
        if let failure { throw failure }

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }
}
