import XCTest
@testable import Type4Me

final class SonioxTranscriptAccumulatorTests: XCTestCase {

    func testApply_combinesFinalAndPartialText() {
        var accumulator = SonioxTranscriptAccumulator()
        accumulator.apply(.init(finalizedText: "Hello ", partialText: "wor"))

        let transcript = accumulator.transcript
        XCTAssertEqual(transcript.confirmedSegments, ["Hello "])
        XCTAssertEqual(transcript.partialText, "wor")
        XCTAssertEqual(transcript.authoritativeText, "Hello wor")
        XCTAssertFalse(transcript.isFinal)
    }

    func testApply_appendsNewFinalTokensAndClearsPartialWhenStabilized() {
        var accumulator = SonioxTranscriptAccumulator()
        accumulator.apply(.init(finalizedText: "Hello ", partialText: "wor"))
        accumulator.apply(.init(finalizedText: "world", partialText: ""))

        let transcript = accumulator.transcript
        XCTAssertEqual(transcript.confirmedSegments, ["Hello world"])
        XCTAssertEqual(transcript.partialText, "")
        XCTAssertEqual(transcript.authoritativeText, "Hello world")
        XCTAssertTrue(transcript.isFinal)
    }

    func testApply_ignoresEmptyFinalChunksAndReplacesCurrentPartial() {
        var accumulator = SonioxTranscriptAccumulator()
        accumulator.apply(.init(finalizedText: "Type", partialText: "4"))
        accumulator.apply(.init(finalizedText: "", partialText: "4Me"))

        let transcript = accumulator.transcript
        XCTAssertEqual(transcript.confirmedSegments, ["Type"])
        XCTAssertEqual(transcript.partialText, "4Me")
        XCTAssertEqual(transcript.authoritativeText, "Type4Me")
    }
}
