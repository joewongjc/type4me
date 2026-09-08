import XCTest
@testable import Type4Me

/// Issue #290: an exhausted Volcengine quota surfaced as a recording that
/// stopped by itself, with no error anywhere in the UI.
///
/// No real error frame has ever been captured from this client, so these tests
/// deliberately do not assert one byte layout. They pin the property that the
/// fix is actually about: whatever shape the frame arrives in, the server's own
/// words must come back out, and a frame carrying an error must never be
/// mistaken for a clean end of session.
final class VolcServerErrorTests: XCTestCase {

    private static let quotaBody = #"{"error":"quota exceeded for types: audio_duration_lifetime"}"#
    private static let quotaCode: UInt32 = 45_000_292

    private func header(compression: UInt8 = 0) -> Data {
        // version 1, header size 1 unit, serverError (0b1111), no sequence.
        Data([0x11, 0xF0, 0x10 | compression, 0x00])
    }

    private func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    /// The layout the Volcengine docs describe: code, then size, then body.
    private func codeThenSizeFrame(body: String) -> Data {
        var frame = header()
        frame.append(bigEndian(Self.quotaCode))
        frame.append(bigEndian(UInt32(body.utf8.count)))
        frame.append(Data(body.utf8))
        return frame
    }

    /// Same error without the code word, in case the framing differs.
    private func sizeOnlyFrame(body: String) -> Data {
        var frame = header()
        frame.append(bigEndian(UInt32(body.utf8.count)))
        frame.append(Data(body.utf8))
        return frame
    }

    /// No framing words at all.
    private func bareBodyFrame(body: String) -> Data {
        var frame = header()
        frame.append(Data(body.utf8))
        return frame
    }

    // MARK: - Extraction survives the framing being unknown

    func testQuotaMessageSurvivesEveryPlausibleFraming() throws {
        let frames: [(String, Data)] = [
            ("code+size", codeThenSizeFrame(body: Self.quotaBody)),
            ("size only", sizeOnlyFrame(body: Self.quotaBody)),
            ("bare body", bareBodyFrame(body: Self.quotaBody)),
        ]

        for (label, frame) in frames {
            let extracted = VolcProtocol.extractServerError(frame)
            XCTAssertEqual(
                extracted.message,
                "quota exceeded for types: audio_duration_lifetime",
                "framing \(label) lost the server message"
            )
        }
    }

    func testErrorCodeIsReportedWhenTheFrameCarriesOne() {
        let extracted = VolcProtocol.extractServerError(codeThenSizeFrame(body: Self.quotaBody))
        XCTAssertEqual(extracted.code, Int(Self.quotaCode))
    }

    /// A length word must not be mistaken for an error code.
    func testShortLeadingWordIsNotReportedAsAnErrorCode() {
        let extracted = VolcProtocol.extractServerError(sizeOnlyFrame(body: Self.quotaBody))
        XCTAssertNil(extracted.code)
        XCTAssertNotNil(extracted.message)
    }

    func testGzippedBodyIsStillReadable() throws {
        let compressed = try VolcProtocol.gzipCompress(Data(Self.quotaBody.utf8))
        var frame = header(compression: 0x01)
        frame.append(bigEndian(Self.quotaCode))
        frame.append(bigEndian(UInt32(compressed.count)))
        frame.append(compressed)

        let extracted = VolcProtocol.extractServerError(frame)
        XCTAssertEqual(extracted.message, "quota exceeded for types: audio_duration_lifetime")
    }

    func testAlternateJSONKeysAreAccepted() {
        for key in ["error", "message", "msg", "error_msg"] {
            let body = "{\"\(key)\":\"boom\"}"
            let extracted = VolcProtocol.extractServerError(codeThenSizeFrame(body: body))
            XCTAssertEqual(extracted.message, "boom", "key \(key) was not read")
        }
    }

    /// The other shape this codebase already assumed: no code word in the
    /// framing, the code carried inside the JSON body instead. Both must work,
    /// because which one Volcengine actually sends is still unconfirmed.
    func testCodeCarriedInsideTheBodyIsRead() {
        let body = #"{"code":1001,"message":"auth failed"}"#
        let extracted = VolcProtocol.extractServerError(sizeOnlyFrame(body: body))
        XCTAssertEqual(extracted.code, 1001)
        XCTAssertEqual(extracted.message, "auth failed")
    }

    func testNonJSONBodyFallsBackToRawText() {
        let extracted = VolcProtocol.extractServerError(bareBodyFrame(body: "quota exceeded"))
        XCTAssertEqual(extracted.message, "quota exceeded")
    }

    /// A frame with nothing readable is how a clean session end is told apart
    /// from an error, so it must not manufacture a message out of framing bytes.
    func testFrameWithoutReadableContentYieldsNothing() {
        var frame = header()
        frame.append(Data([0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04]))
        let extracted = VolcProtocol.extractServerError(frame)
        XCTAssertNil(extracted.message)
        XCTAssertNil(extracted.code)
    }

    // MARK: - The decoder must not bury the message

    func testDecodeServerResponseThrowsTheServerMessageNotInvalidPayload() {
        XCTAssertThrowsError(
            try VolcProtocol.decodeServerResponse(codeThenSizeFrame(body: Self.quotaBody))
        ) { error in
            guard let volc = error as? VolcProtocolError,
                  case .serverError(let code, let message) = volc
            else {
                return XCTFail("expected .serverError, got \(error)")
            }
            XCTAssertEqual(code, Int(Self.quotaCode))
            XCTAssertEqual(message, "quota exceeded for types: audio_duration_lifetime")
        }
    }
}
