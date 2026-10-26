import XCTest
@testable import Type4Me

/// Review follow-up on #290. Parsing the error frame was not enough: the client
/// emitted `.error`, and the session filed it as a generic streaming
/// interruption, entered recovery, and retried the same exhausted provider. The
/// user still saw a recording that stopped by itself.
final class TerminalASRErrorPresentationTests: XCTestCase {

    private let quotaError = VolcProtocolError.serverError(
        code: 45_000_292,
        message: "quota exceeded for types: audio_duration_lifetime"
    )

    // MARK: - Classification

    func testServerErrorsAreTerminalAndTransportErrorsAreNot() {
        XCTAssertTrue((quotaError as TerminalASRError).isTerminalServerError)

        // A malformed frame is a parsing problem, not a verdict about the
        // account, so it must still take the recovery path.
        XCTAssertFalse((VolcProtocolError.invalidPayload as TerminalASRError).isTerminalServerError)
        XCTAssertFalse((VolcProtocolError.decompressionFailed as TerminalASRError).isTerminalServerError)

        XCTAssertNil(URLError(.networkConnectionLost) as? TerminalASRError)
    }

    /// `Type4MeApp.userFacingMessage(for:)` reads `LocalizedError.errorDescription`,
    /// so this is what decides whether the user sees the server's wording or
    /// Foundation's generic fallback.
    func testServerErrorCarriesTheServerWordingAndCodeToTheUI() throws {
        let described = try XCTUnwrap((quotaError as LocalizedError).errorDescription)
        XCTAssertTrue(described.contains("quota exceeded for types: audio_duration_lifetime"),
                      "the server's own message must survive to the UI, got: \(described)")
        XCTAssertTrue(described.contains("45000292"),
                      "the code is what makes the error searchable, got: \(described)")
    }

    func testServerErrorWithoutAMessageStillDescribesItself() throws {
        let bare = VolcProtocolError.serverError(code: nil, message: nil)
        let described = try XCTUnwrap((bare as LocalizedError).errorDescription)
        XCTAssertFalse(described.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: - Runtime presentation

    /// The user-facing path, driven through the session rather than asserted on
    /// parser output: a terminal server error during recording must reach the
    /// `.error` handler the app renders from, and must end the session instead
    /// of retrying the provider that just rejected it.
    func testTerminalServerErrorDuringRecordingReachesTheUser() async throws {
        let session = RecognitionSession()
        let received = EventBox()
        await session.setOnASREvent { event in received.record(event) }
        await session.setState(.recording)

        await session.ingestASREventForTesting(.error(quotaError))

        try await waitUntil { received.errors.count == 1 }

        let surfaced = try XCTUnwrap(received.errors.first)
        let described = try XCTUnwrap((surfaced as? LocalizedError)?.errorDescription)
        XCTAssertTrue(described.contains("quota exceeded for types: audio_duration_lifetime"))

        try await waitUntil { await session.state == .idle }
        let finalState = await session.state
        XCTAssertEqual(finalState, .idle, "a terminal verdict must end the session, not retry it")
    }

    // MARK: - Helpers

    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Error] = []

        func record(_ event: RecognitionEvent) {
            guard case .error(let error) = event else { return }
            lock.lock(); defer { lock.unlock() }
            storage.append(error)
        }

        var errors: [Error] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition not met within \(timeout)")
    }
}
