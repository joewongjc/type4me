import XCTest
@testable import Type4Me

/// Client-level behaviors required by development design §29.3 and §30 that do
/// not need a live network connection.
final class GeminiASRClientTests: XCTestCase {

    // MARK: - §16.1: teardown must never throw on an unused session

    func testEndAudio_withoutConnect_doesNotThrow() async throws {
        let client = GeminiASRClient()
        // RecognitionSession budgets only 3s for endAudio() and treats a throw
        // as an unclean teardown, so an unused session must return silently.
        try await client.endAudio()
    }

    func testSendAudio_withoutConnect_doesNotThrow() async throws {
        let client = GeminiASRClient()
        try await client.sendAudio(Data(repeating: 0, count: 3200))
        try await client.endAudio()
    }

    func testDisconnect_withoutConnect_isSafeAndRepeatable() async {
        let client = GeminiASRClient()
        await client.disconnect()
        await client.disconnect()
    }

    // MARK: - §16: empty audio must not open an activity window

    func testEmptyAudio_doesNotStartActivity() async throws {
        let client = GeminiASRClient()
        try await client.sendAudio(Data())
        // No activityStart was sent, so endAudio must not send activityEnd
        // either; it returns without throwing.
        try await client.endAudio()
    }

    // MARK: - §24: abnormal close classification

    func testUnexpectedClose_ignoresBenignCloseCodes() {
        XCTAssertNil(GeminiASRError.unexpectedClose(code: .normalClosure, reason: nil))
        XCTAssertNil(GeminiASRError.unexpectedClose(code: .goingAway, reason: nil))
        XCTAssertNil(GeminiASRError.unexpectedClose(code: .noStatusReceived, reason: nil))
    }

    func testUnexpectedClose_reportsAbnormalCloseCodes() {
        let error = GeminiASRError.unexpectedClose(code: .internalServerError, reason: "boom")
        XCTAssertEqual(error, .closed(code: 1011, reason: "boom"))

        let noReason = GeminiASRError.unexpectedClose(code: .abnormalClosure, reason: nil)
        XCTAssertEqual(noReason, .closed(code: 1006, reason: nil))
    }

    func testUnexpectedClose_mapsSessionLimitReasonToSessionLimitReached() {
        XCTAssertEqual(
            GeminiASRError.unexpectedClose(code: .internalServerError, reason: "Session duration limit exceeded"),
            .sessionLimitReached
        )
        XCTAssertEqual(
            GeminiASRError.unexpectedClose(code: .policyViolation, reason: "maximum session length reached"),
            .sessionLimitReached
        )
        // A generic server failure must not be mislabeled as a session limit.
        XCTAssertEqual(
            GeminiASRError.unexpectedClose(code: .internalServerError, reason: "internal error"),
            .closed(code: 1011, reason: "internal error")
        )
    }

    // MARK: - §24: close tracker semantics

    func testCloseTracker_recordsFirstAbnormalCloseOnly() async {
        let tracker = GeminiCloseTracker()
        await tracker.recordClose(code: .internalServerError, reason: "first")
        await tracker.recordClose(code: .policyViolation, reason: "second")

        let consumed = await tracker.consumeCloseError()
        XCTAssertEqual(consumed as? GeminiASRError, .closed(code: 1011, reason: "first"))

        let afterConsume = await tracker.consumeCloseError()
        XCTAssertNil(afterConsume)
    }

    func testCloseTracker_ignoresNormalClosure() async {
        let tracker = GeminiCloseTracker()
        await tracker.recordClose(code: .normalClosure, reason: nil)
        let consumed = await tracker.consumeCloseError()
        XCTAssertNil(consumed)
    }

    func testCloseTracker_recordsTransportFailure() async {
        let tracker = GeminiCloseTracker()
        let transportError = URLError(.networkConnectionLost)
        await tracker.recordFailure(transportError)

        let consumed = await tracker.consumeCloseError()
        XCTAssertEqual((consumed as? URLError)?.code, .networkConnectionLost)
    }

    func testCloseTracker_normalClosureDoesNotMaskEarlierFailure() async {
        let tracker = GeminiCloseTracker()
        await tracker.recordFailure(URLError(.timedOut))
        await tracker.recordClose(code: .normalClosure, reason: nil)

        let consumed = await tracker.consumeCloseError()
        XCTAssertEqual((consumed as? URLError)?.code, .timedOut)
    }
}
