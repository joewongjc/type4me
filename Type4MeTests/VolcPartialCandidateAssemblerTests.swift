import XCTest
@testable import Type4Me

final class VolcPartialCandidateAssemblerTests: XCTestCase {
    func testMutableRevisionReplacesPreviousMutableRevision() {
        var assembler = VolcPartialCandidateAssembler()
        _ = assembler.assemble(
            result: result(partial: "明天下午"),
            isFinal: false
        )

        let revision = assembler.assemble(
            result: result(partial: "明天下午三点"),
            isFinal: false
        )

        XCTAssertEqual(revision.transcript.composedText, "明天下午三点")
        XCTAssertTrue(revision.replacedMutableSegment)
        XCTAssertTrue(revision.transcript.isPartialCandidateReliable)
    }

    func testCommittedSegmentIsAppendedOnlyOnce() {
        var assembler = VolcPartialCandidateAssembler()
        let source = VolcASRResult(
            text: "明天下午三点",
            utterances: [
                VolcUtterance(text: "明天下午", definite: true),
                VolcUtterance(text: "三点", definite: false),
            ]
        )

        let first = assembler.assemble(result: source, isFinal: false)
        let second = assembler.assemble(result: source, isFinal: false)

        XCTAssertEqual(first.transcript.confirmedSegments, ["明天下午"])
        XCTAssertEqual(second.transcript.confirmedSegments, ["明天下午"])
        XCTAssertFalse(second.appendedCommittedSegment)
        XCTAssertEqual(second.transcript.composedText, "明天下午三点")
    }

    func testMultipleRevisionsDoNotDuplicateReliablePartialText() {
        var assembler = VolcPartialCandidateAssembler()
        _ = assembler.assemble(result: result(partial: "项目"), isFinal: false)
        _ = assembler.assemble(result: result(partial: "项目会议"), isFinal: false)
        let latest = assembler.assemble(
            result: result(partial: "项目会议安排"),
            isFinal: false
        )

        XCTAssertEqual(latest.transcript.composedText, "项目会议安排")
    }

    func testFinalAuthoritativeTranscriptRemainsUnchanged() {
        var assembler = VolcPartialCandidateAssembler()
        _ = assembler.assemble(
            result: result(partial: "错误的长临时结果"),
            isFinal: false
        )

        let final = assembler.assemble(
            result: VolcASRResult(
                text: "收到。",
                utterances: [
                    VolcUtterance(text: "收到。", definite: true)
                ]
            ),
            isFinal: true
        )

        XCTAssertEqual(final.transcript.authoritativeText, "收到。")
        XCTAssertEqual(final.transcript.displayText, "收到。")
        XCTAssertTrue(final.transcript.isPartialCandidateReliable)
    }

    func testOutOfOrderSequenceCannotOverwriteNewerRevision() {
        var gate = VolcSequenceGate()

        XCTAssertTrue(gate.accept(10))
        XCTAssertTrue(gate.accept(11))
        XCTAssertFalse(gate.accept(10))
        XCTAssertEqual(gate.latest, 11)
    }

    func testPrefixCollapseMarksCandidateUnreliable() {
        var assembler = VolcPartialCandidateAssembler()
        _ = assembler.assemble(
            result: result(partial: "明天下午三点开会"),
            isFinal: false
        )

        let revision = assembler.assemble(
            result: result(partial: "主要讨论开发进度"),
            isFinal: false
        )

        XCTAssertEqual(
            revision.transcript.partialCandidateReliability,
            .unreliable(reason: "prefixCollapse")
        )
        XCTAssertFalse(PartialCandidateGate.isEligible(revision.transcript))
    }

    func testReliablePartialCandidateIsEligibleForSpeculation() {
        var assembler = VolcPartialCandidateAssembler()
        let candidate = assembler.assemble(
            result: result(partial: "明天下午三点开会"),
            isFinal: false
        )

        XCTAssertTrue(PartialCandidateGate.isEligible(candidate.transcript))
    }

    func testSuspiciousLengthJumpMarksCandidateUnreliable() {
        var assembler = VolcPartialCandidateAssembler()
        _ = assembler.assemble(
            result: result(partial: "一二三四五六七八"),
            isFinal: false
        )
        let candidate = assembler.assemble(
            result: result(partial: "一二三四五六七八九十一二三四五六七八九十一二三四"),
            isFinal: false
        )

        XCTAssertEqual(
            candidate.transcript.partialCandidateReliability,
            .unreliable(reason: "suspiciousLengthJump")
        )
    }

    private func result(partial: String) -> VolcASRResult {
        VolcASRResult(
            text: partial,
            utterances: [
                VolcUtterance(text: partial, definite: false)
            ]
        )
    }
}
