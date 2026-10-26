import XCTest
@testable import Type4Me
@testable import Type4MeIntelliSenseCore

final class CorrectionDiffAnalyzerTests: XCTestCase {
    func testEnglishWordCorrection() throws {
        let baseline = "Please use ghosty today"
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: baseline,
            injectedRange: try range(of: "ghosty", in: baseline),
            current: "Please use Ghostty today"
        )
        XCTAssertEqual(result, .candidate(wrongText: "ghosty", correctedText: "Ghostty"))
    }

    func testEnglishInsertionDeletionAndTranspositionCorrections() throws {
        let cases = [
            ("Ghotty", "Ghostty"),
            ("Ghosttyy", "Ghostty"),
            ("Ghsotty", "Ghostty"),
            ("openai", "OpenAI"),
        ]
        for (wrong, corrected) in cases {
            let baseline = "Please use \(wrong) today"
            let result = CorrectionDiffAnalyzer.analyze(
                baseline: baseline,
                injectedRange: try range(of: wrong, in: baseline),
                current: "Please use \(corrected) today"
            )
            XCTAssertEqual(
                result,
                .candidate(wrongText: wrong, correctedText: corrected),
                "failed case \(wrong) → \(corrected)"
            )
        }
    }

    func testSpaceCorrectionExpandsToWords() throws {
        let baseline = "Use Open AI here"
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: baseline,
            injectedRange: try range(of: "Open AI", in: baseline),
            current: "Use OpenAI here"
        )
        XCTAssertEqual(result, .candidate(wrongText: "Open AI", correctedText: "OpenAI"))
    }

    func testInsertedBrandPunctuationExpandsToWord() throws {
        let baseline = "Try Nextjs now"
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: baseline,
            injectedRange: try range(of: "Nextjs", in: baseline),
            current: "Try Next.js now"
        )
        XCTAssertEqual(result, .candidate(wrongText: "Nextjs", correctedText: "Next.js"))
    }

    func testMixedChineseLatinReplacementKeepsExactTokenPair() {
        let original = "明天早上还要跟杰瑞开会"
        let edited = "明天早上还要跟Jerry开会"

        let result = CorrectionDiffAnalyzer.analyze(
            baseline: original,
            injectedRange: NSRange(original.startIndex..<original.endIndex, in: original),
            current: edited
        )

        XCTAssertEqual(result, .candidate(wrongText: "杰瑞", correctedText: "Jerry"))
    }

    func testReverseMixedLatinChineseReplacementKeepsExactTokenPair() {
        let original = "明天早上还要跟Jerry开会"
        let edited = "明天早上还要跟杰瑞开会"

        let result = CorrectionDiffAnalyzer.analyze(
            baseline: original,
            injectedRange: NSRange(original.startIndex..<original.endIndex, in: original),
            current: edited
        )

        XCTAssertEqual(result, .candidate(wrongText: "Jerry", correctedText: "杰瑞"))
    }

    func testSingleHanMixedScriptReplacementRemainsAmbiguous() {
        let original = "跟杰开会"
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: original,
            injectedRange: NSRange(original.startIndex..<original.endIndex, in: original),
            current: "跟J开会"
        )

        XCTAssertEqual(result, .rejected(.ambiguousCJKReplacement))
    }

    func testTechnicalTokenBoundaryRejectsMixedSentenceButAcceptsIndividualTokens() {
        XCTAssertFalse(TechnicalTokenBoundaryResolver.isSingleStableToken(
            "明天早上还要跟Jerry开会"
        ))
        XCTAssertTrue(TechnicalTokenBoundaryResolver.isSingleStableToken("杰瑞"))
        XCTAssertTrue(TechnicalTokenBoundaryResolver.isSingleStableToken("Jerry"))
        XCTAssertTrue(TechnicalTokenBoundaryResolver.isSingleStableToken("Next.js"))
        XCTAssertTrue(TechnicalTokenBoundaryResolver.isSingleStableToken("Open AI"))
    }

    func testImmediateMixedScriptCorrectionUsesChineseBoundaryValidation() async {
        let segmenter = MixedScriptAgreeingSegmenter()

        let result = await ImmediateCorrectionAnalyzer.analyze(
            original: "明天早上还要跟杰瑞开会",
            edited: "明天早上还要跟Jerry开会",
            chineseSegmenter: segmenter
        )

        XCTAssertEqual(result, .candidate(wrongText: "杰瑞", correctedText: "Jerry"))
        let segmenterCallCount = await segmenter.callCount()
        XCTAssertEqual(segmenterCallCount, 1)
    }

    func testImmediateMixedScriptCorrectionRejectsDisputedChineseBoundary() async {
        let result = await ImmediateCorrectionAnalyzer.analyze(
            original: "明天早上还要跟杰瑞开会",
            edited: "明天早上还要跟Jerry开会",
            chineseSegmenter: MixedScriptDisagreeingSegmenter()
        )

        XCTAssertEqual(result, .rejected(.invalidCandidate))
    }

    func testImmediateMixedScriptCorrectionFallsBackToNativeTokenizer() async {
        let result = await ImmediateCorrectionAnalyzer.analyze(
            original: "明天早上还要跟杰瑞开会",
            edited: "明天早上还要跟Jerry开会",
            chineseSegmenter: NaturalLanguageChineseWordSegmenter()
        )

        XCTAssertEqual(result, .candidate(wrongText: "杰瑞", correctedText: "Jerry"))
    }

    func testSingleChineseCharacterCorrectionIsRejectedAsAmbiguous() throws {
        let baseline = "我们使用阶越星辰模型"
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: baseline,
            injectedRange: NSRange(baseline.startIndex..<baseline.endIndex, in: baseline),
            current: "我们使用阶跃星辰模型"
        )
        XCTAssertEqual(result, .rejected(.ambiguousCJKReplacement))
    }

    func testMultiCharacterChineseReplacementKeepsExactDiff() throws {
        let baseline = "这个问题和一个人的加好程度其实是有关系的"
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: baseline,
            injectedRange: NSRange(baseline.startIndex..<baseline.endIndex, in: baseline),
            current: "这个问题和一个人的佳豪程度其实是有关系的"
        )
        XCTAssertEqual(result, .candidate(wrongText: "加好", correctedText: "佳豪"))
    }

    func testUnrelatedTypingOutsideInjectionDoesNotHideCorrection() throws {
        let baseline = "prefix ghosty suffix"
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: baseline,
            injectedRange: try range(of: "ghosty", in: baseline),
            current: "new prefix Ghostty suffix tail"
        )
        XCTAssertEqual(result, .candidate(wrongText: "ghosty", correctedText: "Ghostty"))
    }

    func testMultipleCorrectionsInsideInjectionAreRejected() {
        let baseline = "ghosty and Nextjs"
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: baseline,
            injectedRange: NSRange(baseline.startIndex..<baseline.endIndex, in: baseline),
            current: "Ghostty and Next.js"
        )
        XCTAssertEqual(result, .rejected(.multipleChanges))
    }

    func testPureWordInsertionAndDeletionAreRejected() {
        let insertion = CorrectionDiffAnalyzer.analyze(
            baseline: "Open model",
            injectedRange: NSRange(location: 0, length: 10),
            current: "Open AI model"
        )
        if case .candidate = insertion { XCTFail("Pure insertion must not become a candidate") }

        let deletion = CorrectionDiffAnalyzer.analyze(
            baseline: "Open AI model",
            injectedRange: NSRange(location: 0, length: 13),
            current: "Open model"
        )
        if case .candidate = deletion { XCTFail("Pure deletion must not become a candidate") }
    }

    func testPurePunctuationReplacementIsRejected() {
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: "hello.",
            injectedRange: NSRange(location: 0, length: 6),
            current: "hello!"
        )
        XCTAssertEqual(result, .rejected(.invalidCandidate))
    }

    func testNumericFactChangeIsNotAnImmediateCorrection() async {
        let result = await ImmediateCorrectionAnalyzer.analyze(
            original: "版本 3",
            edited: "版本 4"
        )

        XCTAssertEqual(result, .rejected(.invalidCandidate))
    }

    func testImmediateChineseHomophoneCorrectionHasHighAffinity() async {
        let result = await ImmediateCorrectionAnalyzer.analyze(
            original: "这个人的加好程度很高",
            edited: "这个人的佳豪程度很高",
            confirmedMappings: []
        )

        XCTAssertEqual(result, .candidate(wrongText: "加好", correctedText: "佳豪"))
    }

    func testImmediateUnrelatedChineseEditIsHistoryOnly() async {
        let result = await ImmediateCorrectionAnalyzer.analyze(
            original: "今天吃苹果",
            edited: "今天吃微软",
            confirmedMappings: []
        )

        XCTAssertEqual(result, .rejected(.lowAffinity))
    }

    func testImmediateUnrelatedMixedScriptEditIsHistoryOnly() async {
        let result = await ImmediateCorrectionAnalyzer.analyze(
            original: "今天吃苹果",
            edited: "今天吃Microsoft",
            chineseSegmenter: NaturalLanguageChineseWordSegmenter(),
            confirmedMappings: []
        )

        XCTAssertEqual(result, .rejected(.lowAffinity))
    }

    func testSensitiveAndOverlongCandidatesAreRejected() {
        let emailBaseline = "wrong@example.com"
        let emailResult = CorrectionDiffAnalyzer.analyze(
            baseline: emailBaseline,
            injectedRange: NSRange(emailBaseline.startIndex..<emailBaseline.endIndex, in: emailBaseline),
            current: "right@example.com"
        )
        XCTAssertEqual(emailResult, .rejected(.sensitiveContent))

        let longWrong = String(repeating: "a", count: 65)
        let longCorrect = String(repeating: "a", count: 64) + "b"
        let longResult = CorrectionDiffAnalyzer.analyze(
            baseline: longWrong,
            injectedRange: NSRange(longWrong.startIndex..<longWrong.endIndex, in: longWrong),
            current: longCorrect
        )
        XCTAssertEqual(longResult, .rejected(.invalidCandidate))
    }

    private func range(of substring: String, in text: String) throws -> NSRange {
        guard let range = text.range(of: substring) else {
            throw NSError(domain: "CorrectionDiffAnalyzerTests", code: 1)
        }
        return NSRange(range, in: text)
    }
}

final class CorrectionAffinityAnalyzerTests: XCTestCase {
    func testLatinSpellingCorrectionsHaveHighAffinity() {
        for (wrong, corrected) in [
            ("Ghotty", "Ghostty"),
            ("Ghsotty", "Ghostty"),
            ("Open AI", "OpenAI"),
        ] {
            let result = CorrectionAffinityAnalyzer.evaluate(wrong: wrong, corrected: corrected)
            XCTAssertTrue(result.isHighConfidence, "failed case \(wrong) → \(corrected)")
            XCTAssertEqual(result.reason, .orthographic)
        }
    }

    func testUnrelatedLatinWordsHaveLowAffinity() {
        let result = CorrectionAffinityAnalyzer.evaluate(wrong: "apple", corrected: "Microsoft")

        XCTAssertFalse(result.isHighConfidence)
        XCTAssertEqual(result.reason, .unrelated)
    }

    func testChineseHomophoneHasHighAffinity() {
        let result = CorrectionAffinityAnalyzer.evaluate(wrong: "加好", corrected: "佳豪")

        XCTAssertTrue(result.isHighConfidence)
        XCTAssertEqual(result.reason, .chineseHomophone)
    }

    func testUnrelatedChineseWordsHaveLowAffinity() {
        let result = CorrectionAffinityAnalyzer.evaluate(wrong: "苹果", corrected: "微软")

        XCTAssertFalse(result.isHighConfidence)
        XCTAssertEqual(result.reason, .unrelated)
    }

    func testChineseEnglishTransliterationsHaveHighAffinity() {
        for (wrong, corrected) in [("杰瑞", "Jerry"), ("阿卡迪亚", "Arcadia")] {
            let result = CorrectionAffinityAnalyzer.evaluate(wrong: wrong, corrected: corrected)
            XCTAssertTrue(result.isHighConfidence, "failed case \(wrong) → \(corrected)")
            XCTAssertEqual(result.reason, .transliteration)
        }
    }

    func testUnrelatedChineseEnglishPairHasLowAffinity() {
        let result = CorrectionAffinityAnalyzer.evaluate(wrong: "苹果", corrected: "Microsoft")

        XCTAssertFalse(result.isHighConfidence)
        XCTAssertEqual(result.reason, .unrelated)
    }

    func testConfirmedMappingOverridesAffinityHeuristics() {
        let result = CorrectionAffinityAnalyzer.evaluate(
            wrong: "苹果",
            corrected: "Microsoft",
            confirmedMappings: [CorrectionMapping(trigger: "苹果", replacement: "Microsoft")]
        )

        XCTAssertTrue(result.isHighConfidence)
        XCTAssertEqual(result.reason, .confirmedMapping)
    }
}

private actor MixedScriptAgreeingSegmenter: ChineseWordSegmenting {
    private var calls = 0

    func tokenSpans(in text: String) -> [ChineseTokenSpan] {
        calls += 1
        guard let range = text.range(of: "杰瑞") else { return [] }
        return [
            ChineseTokenSpan(range: range, source: .jiebaAccurate),
            ChineseTokenSpan(range: range, source: .naturalLanguage),
        ]
    }

    func callCount() -> Int { calls }
}

private struct MixedScriptDisagreeingSegmenter: ChineseWordSegmenting {
    func tokenSpans(in text: String) async -> [ChineseTokenSpan] {
        guard let range = text.range(of: "杰瑞") else { return [] }
        return [ChineseTokenSpan(range: range, source: .naturalLanguage)]
            + text.range(of: "明天").map {
                [ChineseTokenSpan(range: $0, source: .jiebaAccurate)]
            }.orEmpty
    }
}

private extension Optional where Wrapped == [ChineseTokenSpan] {
    var orEmpty: [ChineseTokenSpan] { self ?? [] }
}

final class CorrectionLearningStoreTests: XCTestCase {
    func testLearnsHotwordAndMappingTogether() throws {
        let persistence = FakeCorrectionPersistence()
        let store = CorrectionLearningStore(persistence: persistence)
        try store.learn(candidate(wrong: "ghosty", corrected: "Ghostty"))

        XCTAssertEqual(persistence.hotwords, ["Ghostty"])
        XCTAssertEqual(
            persistence.mappings,
            [CorrectionMapping(trigger: "ghosty", replacement: "Ghostty")]
        )
    }

    func testDeduplicatesHotwordAndUpdatesConflictingMapping() throws {
        let persistence = FakeCorrectionPersistence(
            hotwords: ["GHOSTTY"],
            mappings: [CorrectionMapping(trigger: "Ghosty", replacement: "Old")]
        )
        let store = CorrectionLearningStore(persistence: persistence)
        try store.learn(candidate(wrong: "ghosty", corrected: "Ghostty"))

        XCTAssertEqual(persistence.hotwords, ["GHOSTTY"])
        XCTAssertEqual(
            persistence.mappings,
            [CorrectionMapping(trigger: "ghosty", replacement: "Ghostty")]
        )
        XCTAssertEqual(persistence.hotwordSaveCount, 0)
        XCTAssertEqual(persistence.mappingSaveCount, 1)
    }

    func testMappingFailureRollsBackHotwords() {
        let persistence = FakeCorrectionPersistence()
        persistence.failMappingSave = true
        let store = CorrectionLearningStore(persistence: persistence)

        XCTAssertThrowsError(try store.learn(candidate(wrong: "ghosty", corrected: "Ghostty")))
        XCTAssertEqual(persistence.hotwords, [])
        XCTAssertEqual(persistence.mappings, [])
    }

    private func candidate(wrong: String, corrected: String) -> CorrectionCandidate {
        CorrectionCandidate(
            wrongText: wrong,
            correctedText: corrected,
            sourceRecordID: "record",
            bundleIdentifier: "com.example.editor"
        )
    }
}

final class CorrectionLearningEligibilityTests: XCTestCase {
    func testPostInjectionPlanGatesCrossModeAndSensitiveSessions() {
        var settings = IntelliSenseSettings()
        settings.correctionDetectionEnabled = true
        settings.expressionLearningEnabled = true

        let normal = PostInjectionLearningPlan.resolve(
            settings: settings,
            modeID: ProcessingMode.intelliSenseId,
            startedModeID: ProcessingMode.intelliSenseId,
            isCrossModeFallback: false,
            aborted: false,
            guardRejected: false,
            contextAvailability: .full,
            targetBundleIdentifier: "com.example.editor"
        )
        XCTAssertTrue(normal.correctionEnabled)
        XCTAssertTrue(normal.expressionLearningEnabled)

        let crossMode = PostInjectionLearningPlan.resolve(
            settings: settings,
            modeID: ProcessingMode.intelliSenseId,
            startedModeID: ProcessingMode.directId,
            isCrossModeFallback: true,
            aborted: false,
            guardRejected: false,
            contextAvailability: nil,
            targetBundleIdentifier: "com.example.editor"
        )
        XCTAssertTrue(crossMode.correctionEnabled)
        XCTAssertFalse(crossMode.expressionLearningEnabled)

        for availability in [ContextAvailability.sensitive, .blacklisted] {
            let blocked = PostInjectionLearningPlan.resolve(
                settings: settings,
                modeID: ProcessingMode.intelliSenseId,
                startedModeID: ProcessingMode.intelliSenseId,
                isCrossModeFallback: false,
                aborted: false,
                guardRejected: false,
                contextAvailability: availability,
                targetBundleIdentifier: "com.example.editor"
            )
            XCTAssertFalse(blocked.shouldTrackInjection)
        }
    }

    @MainActor
    func testCancellingWithoutAnObservationDoesNotCreateAnimatedPanel() {
        let coordinator = CorrectionLearningCoordinator()

        XCTAssertFalse(coordinator.isPanelControllerLoaded)

        coordinator.cancelObservation()

        XCTAssertFalse(coordinator.isPanelControllerLoaded)
    }

    @MainActor
    func testOnlyIntelliSenseIsSupported() {
        XCTAssertTrue(CorrectionLearningCoordinator.supports(modeID: ProcessingMode.intelliSenseId))
        XCTAssertFalse(CorrectionLearningCoordinator.supports(modeID: ProcessingMode.directId))
        XCTAssertFalse(CorrectionLearningCoordinator.supports(modeID: ProcessingMode.formalWritingId))
        XCTAssertFalse(CorrectionLearningCoordinator.supports(modeID: ProcessingMode.translateId))
        XCTAssertFalse(CorrectionLearningCoordinator.supports(modeID: UUID()))
    }

    func testUserEditObservationTimingMatchesDesign() {
        let timing = UserEditObservationTiming.production
        XCTAssertEqual(timing.observationTimeout, .seconds(60))
        XCTAssertEqual(timing.stableWindow, .milliseconds(800))
        XCTAssertEqual(timing.candidatePresentationDelay, .seconds(4))
        XCTAssertEqual(timing.readRetryDelay, .milliseconds(100))
        XCTAssertEqual(timing.resolverBudget, .milliseconds(10))
        XCTAssertEqual(timing.evidenceDecayHalfLifeDays, 90)
    }
}

private final class FakeCorrectionPersistence: CorrectionVocabularyPersisting {
    var hotwords: [String]
    var mappings: [CorrectionMapping]
    var failMappingSave = false
    var hotwordSaveCount = 0
    var mappingSaveCount = 0

    init(hotwords: [String] = [], mappings: [CorrectionMapping] = []) {
        self.hotwords = hotwords
        self.mappings = mappings
    }

    func loadHotwords() -> [String] { hotwords }
    func loadMappings() -> [CorrectionMapping] { mappings }

    func saveHotwords(_ words: [String]) throws {
        hotwordSaveCount += 1
        hotwords = words
    }

    func saveMappings(_ mappings: [CorrectionMapping]) throws {
        mappingSaveCount += 1
        if failMappingSave { throw NSError(domain: "FakeCorrectionPersistence", code: 1) }
        self.mappings = mappings
    }
}
