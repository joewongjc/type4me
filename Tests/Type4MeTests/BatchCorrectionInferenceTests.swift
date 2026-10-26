import XCTest
@testable import Type4Me

final class BatchCorrectionInferenceTests: XCTestCase {
    func testRequiresThreeSessionsAcrossTwoDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let evidence = [
            item(id: "1", dayOffset: -2, now: now),
            item(id: "2", dayOffset: -1, now: now),
            item(id: "3", dayOffset: -1, now: now),
        ]

        let suggestions = BatchCorrectionInference.infer(from: evidence, now: now)

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.wrongText, "ghosty")
        XCTAssertEqual(suggestions.first?.correctedText, "Ghostty")
        XCTAssertEqual(suggestions.first?.state, .pending)
    }

    func testSameDayEvidenceDoesNotMeetThreshold() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let evidence = (1...3).map { item(id: "\($0)", dayOffset: 0, now: now) }

        XCTAssertTrue(BatchCorrectionInference.infer(from: evidence, now: now).isEmpty)
    }

    func testDirectionBelowEightyPercentDoesNotGenerateSuggestion() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var evidence = [
            item(id: "1", dayOffset: -2, now: now),
            item(id: "2", dayOffset: -1, now: now),
            item(id: "3", dayOffset: 0, now: now),
        ]
        evidence.append(CorrectionEvidence(
            recordID: "4",
            observedAt: now,
            bundleIdentifier: nil,
            wrongText: "ghosty",
            correctedText: "Ghostly",
            normalizedKey: BatchCorrectionInference.normalizedPairKey(
                wrong: "ghosty",
                corrected: "Ghostly"
            ),
            confidence: 1
        ))

        XCTAssertTrue(BatchCorrectionInference.infer(from: evidence, now: now).isEmpty)
    }

    func testDuplicateRecordContributesOnlyOnceAndIgnoredKeyIsSuppressed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = item(id: "1", dayOffset: -2, now: now)
        let evidence = [
            first,
            first,
            item(id: "2", dayOffset: -1, now: now),
            item(id: "3", dayOffset: 0, now: now),
        ]
        let ignored = Set([first.normalizedKey])

        XCTAssertTrue(BatchCorrectionInference.infer(
            from: evidence,
            now: now,
            ignoredKeys: ignored
        ).isEmpty)
    }

    func testExtractEvidenceFiltersUnsupportedDataVersion() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let supported = record(
            id: "supported",
            version: UserEditObservationFormat.currentVersion,
            date: now
        )
        let unsupported = record(id: "unsupported", version: 1, date: now)

        let evidence = await BatchCorrectionInference.extractEvidence(
            from: [supported, unsupported],
            chineseSegmenter: NativeOnlyChineseSegmenterForBatch()
        )

        XCTAssertEqual(evidence.map(\.recordID), ["supported"])
    }

    private func item(id: String, dayOffset: Int, now: Date) -> CorrectionEvidence {
        let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: now)!
        return CorrectionEvidence(
            recordID: id,
            observedAt: date,
            bundleIdentifier: nil,
            wrongText: "ghosty",
            correctedText: "Ghostty",
            normalizedKey: BatchCorrectionInference.normalizedPairKey(
                wrong: "ghosty",
                corrected: "Ghostty"
            ),
            confidence: 1
        )
    }

    private func record(id: String, version: Int, date: Date) -> HistoryRecord {
        HistoryRecord(
            id: id,
            createdAt: date,
            durationSeconds: 1,
            rawText: "ghosty",
            processingMode: "智能感知",
            processedText: "ghosty",
            finalText: "ghosty",
            status: "completed",
            characterCount: 6,
            asrProvider: nil,
            userEditedText: "Ghostty",
            userEditStatus: .edited,
            userEditObservedAt: date,
            userEditVersion: version
        )
    }
}

private struct NativeOnlyChineseSegmenterForBatch: ChineseWordSegmenting {
    func tokenSpans(in text: String) async -> [ChineseTokenSpan] { [] }
}
