import XCTest
@testable import Type4Me

final class AssemblyAITranscriptAccumulatorTests: XCTestCase {

    func testPartialTranscript_splitsCurrentTurnIntoConfirmedAndPartial() {
        var accumulator = AssemblyAITranscriptAccumulator()
        accumulator.apply(.init(
            turnOrder: 0,
            finalizedText: "Hello",
            displayText: "Hello world",
            authoritativeText: "Hello",
            isFinal: false,
            isFormatted: true
        ))

        let transcript = accumulator.transcript
        XCTAssertEqual(transcript.confirmedSegments, ["Hello"])
        XCTAssertEqual(transcript.partialText, " world")
        XCTAssertEqual(transcript.authoritativeText, "Hello world")
        XCTAssertFalse(transcript.isFinal)
    }

    func testFinalTurn_movesWholeTurnIntoConfirmedSegments() {
        var accumulator = AssemblyAITranscriptAccumulator()
        accumulator.apply(.init(
            turnOrder: 0,
            finalizedText: "Hello world.",
            displayText: "Hello world.",
            authoritativeText: "Hello world.",
            isFinal: true,
            isFormatted: true
        ))

        let transcript = accumulator.transcript
        XCTAssertEqual(transcript.confirmedSegments, ["Hello world."])
        XCTAssertEqual(transcript.partialText, "")
        XCTAssertEqual(transcript.authoritativeText, "Hello world.")
        XCTAssertTrue(transcript.isFinal)
    }

    func testFormattedFinalUpdate_overwritesPriorUnformattedTurn() {
        var accumulator = AssemblyAITranscriptAccumulator()
        accumulator.apply(.init(
            turnOrder: 0,
            finalizedText: "hello world",
            displayText: "hello world",
            authoritativeText: "hello world",
            isFinal: true,
            isFormatted: false
        ))
        accumulator.apply(.init(
            turnOrder: 0,
            finalizedText: "Hello world.",
            displayText: "Hello world.",
            authoritativeText: "Hello world.",
            isFinal: true,
            isFormatted: true
        ))

        XCTAssertEqual(accumulator.transcript.confirmedSegments, ["Hello world."])
        XCTAssertEqual(accumulator.transcript.authoritativeText, "Hello world.")
    }

    func testMultipleTurns_keepWhitespaceBetweenSegments() {
        var accumulator = AssemblyAITranscriptAccumulator()
        accumulator.apply(.init(
            turnOrder: 0,
            finalizedText: "Hello world.",
            displayText: "Hello world.",
            authoritativeText: "Hello world.",
            isFinal: true,
            isFormatted: true
        ))
        accumulator.apply(.init(
            turnOrder: 1,
            finalizedText: "I am",
            displayText: "I am testing",
            authoritativeText: "I am",
            isFinal: false,
            isFormatted: true
        ))

        let transcript = accumulator.transcript
        XCTAssertEqual(transcript.confirmedSegments, ["Hello world.", " I am"])
        XCTAssertEqual(transcript.partialText, " testing")
        XCTAssertEqual(transcript.authoritativeText, "Hello world. I am testing")
    }

    func testU3PartialWithoutFinalizedPrefix_keepsWholeTextAsPartial() {
        var accumulator = AssemblyAITranscriptAccumulator()
        accumulator.apply(.init(
            turnOrder: 0,
            finalizedText: "",
            displayText: "Its 8888-8888",
            authoritativeText: "",
            isFinal: false,
            isFormatted: false
        ))

        let transcript = accumulator.transcript
        XCTAssertEqual(transcript.confirmedSegments, [])
        XCTAssertEqual(transcript.partialText, "Its 8888-8888")
        XCTAssertEqual(transcript.authoritativeText, "Its 8888-8888")
        XCTAssertFalse(transcript.isFinal)
    }
}
