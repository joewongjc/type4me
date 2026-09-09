import XCTest
@testable import Type4Me

/// Review follow-up on #290: the parser fix alone did not restore the reported
/// product behaviour. Settings → Test could still report success for an
/// exhausted account, because the probe listened on an event stream that
/// `connect()` had already replaced.
final class VolcCredentialProbeTests: XCTestCase {

    private func quotaError() -> VolcProtocolError {
        .serverError(code: 45_000_292, message: "quota exceeded for types: audio_duration_lifetime")
    }

    // MARK: - The stale-stream bug

    /// `connect()` installs a fresh stream, so a handle taken beforehand stops
    /// receiving. This is the whole reason the probe missed the verdict: it read
    /// `events` first and then waited on a stream nothing would ever emit into.
    func testConnectingReplacesAnyEarlierEventStreamHandle() async {
        let client = VolcASRClient()
        let generationBefore = await client.eventStreamGeneration
        _ = await client.events

        await client.installFreshEventStream()

        let generationAfter = await client.eventStreamGeneration
        XCTAssertGreaterThan(
            generationAfter,
            generationBefore,
            "a handle taken before the reset is stale; the probe must read events after connecting"
        )
    }

    // MARK: - Verdict handling

    func testServerErrorAfterInitIsReported() async {
        let expected = quotaError()
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        continuation.yield(.error(expected))

        let found = await VolcASRClient.firstServerError(in: stream, within: .seconds(2))

        guard case .serverError(let code, let message)? = found as? VolcProtocolError else {
            return XCTFail("expected the server error to be reported, got \(String(describing: found))")
        }
        XCTAssertEqual(code, 45_000_292)
        XCTAssertEqual(message, "quota exceeded for types: audio_duration_lifetime")
    }

    /// An error arriving before iteration starts must still be seen — the stream
    /// buffers it, which is what makes reading `events` after `connect()` safe.
    func testErrorEmittedBeforeIterationIsNotLost() async {
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        continuation.yield(.ready)
        continuation.yield(.error(quotaError()))
        continuation.finish()

        let found = await VolcASRClient.firstServerError(in: stream, within: .seconds(2))
        XCTAssertNotNil(found, "a buffered error must not be dropped")
    }

    func testHealthyStreamReportsNoError() async {
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        continuation.yield(.ready)
        continuation.finish()

        let found = await VolcASRClient.firstServerError(in: stream, within: .seconds(2))
        XCTAssertNil(found)
    }

    /// Silence is success: a server that accepts the request says nothing.
    func testSilenceWithinTheWindowReportsNoError() async {
        let (stream, _) = AsyncStream<RecognitionEvent>.makeStream()
        let found = await VolcASRClient.firstServerError(in: stream, within: .milliseconds(120))
        XCTAssertNil(found)
    }
}
