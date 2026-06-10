import XCTest
@testable import Type4Me

final class RecognitionSessionTests: XCTestCase {
    override func tearDown() {
        KeychainService.selectedASRProvider = .volcano
    }

    func testInitialStateIsIdle() async {
        let session = RecognitionSession()
        let state = await session.state
        XCTAssertEqual(state, .idle)
    }

    func testSetState() async {
        let session = RecognitionSession()
        await session.setState(.recording)
        let state = await session.state
        XCTAssertEqual(state, .recording)
        await session.setState(.idle)
    }

    func testCanStartRecordingOnlyWhenIdle() async {
        let session = RecognitionSession()
        var canStart = await session.canStartRecording
        XCTAssertTrue(canStart)

        await session.setState(.recording)
        canStart = await session.canStartRecording
        XCTAssertFalse(canStart)
        await session.setState(.idle)
    }

    func testSwitchModeAppliesToDirect() async {
        KeychainService.selectedASRProvider = .volcano
        let session = RecognitionSession()

        await session.switchMode(to: .direct)

        let mode = await session.currentModeForTesting()
        XCTAssertEqual(mode.id, ProcessingMode.directId)
    }

    func testSwitchModeDirectWorksForSoniox() async {
        KeychainService.selectedASRProvider = .soniox
        let session = RecognitionSession()

        await session.switchMode(to: .direct)

        let mode = await session.currentModeForTesting()
        XCTAssertEqual(mode.id, ProcessingMode.directId)
    }

    func testShouldAttemptBatchFallbackWhenStreamingErrorWasObserved() {
        let shouldFallback = RecognitionSession.shouldAttemptBatchFallback(
            uploadFailed: false,
            asrTeardownClean: true,
            streamingError: DeepgramASRError.closed(code: 1008, reason: "policy violation")
        )

        XCTAssertTrue(shouldFallback)
    }

    func testTranscriptDiffExactMatch() {
        let diff = TranscriptDiff.classify(source: "你好", final: "你好")

        XCTAssertEqual(diff.type, .exactMatch)
        XCTAssertTrue(diff.canReuseLLMResult)
    }

    func testTranscriptDiffWhitespaceOnly() {
        let diff = TranscriptDiff.classify(source: "你 好", final: "你好\n")

        XCTAssertEqual(diff.type, .whitespaceOnly)
        XCTAssertTrue(diff.canReuseLLMResult)
    }

    func testTranscriptDiffPunctuationWidthOnly() {
        let diff = TranscriptDiff.classify(source: "你好。继续", final: "你好.继续")

        XCTAssertEqual(diff.type, .punctuationOnly)
        XCTAssertTrue(diff.canReuseLLMResult)
    }

    func testTranscriptDiffTrailingPunctuationOnly() {
        let diff = TranscriptDiff.classify(source: "你好", final: "你好。")

        XCTAssertEqual(diff.type, .trailingPunctuationOnly)
        XCTAssertEqual(diff.addedSuffixUnicode, ["U+3002"])
        XCTAssertTrue(diff.canReuseLLMResult)
    }

    func testTranscriptDiffSuffixAdded() {
        let diff = TranscriptDiff.classify(source: "你好", final: "你好啊")

        XCTAssertEqual(diff.type, .suffixAdded)
        XCTAssertFalse(diff.canReuseLLMResult)
    }

    func testTranscriptDiffPrefixAdded() {
        let diff = TranscriptDiff.classify(source: "开会", final: "今天开会")

        XCTAssertEqual(diff.type, .prefixAdded)
        XCTAssertFalse(diff.canReuseLLMResult)
    }

    func testTranscriptDiffSemanticChange() {
        let diff = TranscriptDiff.classify(source: "今天开会", final: "明天开会")

        XCTAssertEqual(diff.type, .semanticChange)
        XCTAssertTrue(diff.changedInMiddle)
        XCTAssertFalse(diff.canReuseLLMResult)
    }

    func testNormalizationDoesNotModifyReturnedTranscript() {
        let final = "你好。\n"

        _ = TranscriptDiff.classify(source: "你好.", final: final)

        XCTAssertEqual(final, "你好。\n")
    }

    func testEarlyLLMDecisionReusesExactProvisional() {
        XCTAssertEqual(
            EarlyLLMDecision.decide(earlyInput: "你好", finalInput: "你好", needsLLM: true),
            .reuse
        )
    }

    func testEarlyLLMDecisionReusesTrailingPunctuation() {
        XCTAssertEqual(
            EarlyLLMDecision.decide(earlyInput: "你好", finalInput: "你好。", needsLLM: true),
            .reuse
        )
    }

    func testEarlyLLMDecisionRunsFreshForHanCharacterSuffix() {
        XCTAssertEqual(
            EarlyLLMDecision.decide(earlyInput: "你好", finalInput: "你好啊", needsLLM: true),
            .runFresh
        )
    }

    func testEarlyLLMDecisionRunsFreshForMiddleChange() {
        XCTAssertEqual(
            EarlyLLMDecision.decide(earlyInput: "今天开会", finalInput: "明天开会", needsLLM: true),
            .runFresh
        )
    }

    func testEarlyLLMDecisionRunsFreshWithoutPartial() {
        XCTAssertEqual(
            EarlyLLMDecision.decide(earlyInput: nil, finalInput: "你好", needsLLM: true),
            .runFresh
        )
    }

    func testEarlyLLMDecisionSkipsDirectMode() {
        XCTAssertEqual(
            EarlyLLMDecision.decide(earlyInput: "你好", finalInput: "你好", needsLLM: false),
            .noRequest
        )
    }

    func testEarlyLLMDecisionSkipsEmptyFinal() {
        XCTAssertEqual(
            EarlyLLMDecision.decide(earlyInput: "你好", finalInput: "", needsLLM: true),
            .noRequest
        )
    }

    func testCompletedProvisionalTaskIsReused() async {
        let provisional = Task<String?, Never> { "provisional" }
        _ = await provisional.value

        let selection = EarlyLLMTaskSelector.select(
            earlyInput: "你好",
            finalInput: "你好。",
            needsLLM: true,
            earlyTask: provisional,
            makeFreshTask: { Task { "fresh" } }
        )

        XCTAssertTrue(selection.reused)
        let result = await selection.task?.value
        XCTAssertEqual(result, "provisional")
    }

    func testRunningProvisionalTaskIsAwaitableWhenFinalArrivesFirst() async {
        let provisional = Task<String?, Never> {
            try? await Task.sleep(for: .milliseconds(20))
            return "provisional"
        }

        let selection = EarlyLLMTaskSelector.select(
            earlyInput: "你好",
            finalInput: "你好",
            needsLLM: true,
            earlyTask: provisional,
            makeFreshTask: { Task { "fresh" } }
        )

        XCTAssertTrue(selection.reused)
        let result = await selection.task?.value
        XCTAssertEqual(result, "provisional")
    }

    func testSemanticChangeCancelsProvisionalAndRunsFreshTask() async {
        let provisional = Task<String?, Never> {
            try? await Task.sleep(for: .seconds(1))
            return "stale"
        }

        let selection = EarlyLLMTaskSelector.select(
            earlyInput: "今天开会",
            finalInput: "明天开会",
            needsLLM: true,
            earlyTask: provisional,
            makeFreshTask: { Task { "fresh" } }
        )

        XCTAssertFalse(selection.reused)
        XCTAssertTrue(provisional.isCancelled)
        let result = await selection.task?.value
        XCTAssertEqual(result, "fresh")
    }

    func testCancelledNonCooperativeProvisionalCannotBecomeSelectedResult() async {
        let provisional = Task<String?, Never> {
            try? await Task.sleep(for: .milliseconds(20))
            return "stale"
        }

        let selection = EarlyLLMTaskSelector.select(
            earlyInput: "你好",
            finalInput: "你好啊",
            needsLLM: true,
            earlyTask: provisional,
            makeFreshTask: { Task { "fresh" } }
        )

        XCTAssertTrue(provisional.isCancelled)
        let result = await selection.task?.value
        XCTAssertEqual(result, "fresh")
    }

    func testNoLLMRequestCancelsProvisional() {
        let provisional = Task<String?, Never> { "stale" }

        let selection = EarlyLLMTaskSelector.select(
            earlyInput: "你好",
            finalInput: "你好",
            needsLLM: false,
            earlyTask: provisional,
            makeFreshTask: { Task { "fresh" } }
        )

        XCTAssertTrue(provisional.isCancelled)
        XCTAssertNil(selection.task)
    }

    func testSpeculativeMinimumTextLength() {
        var throttle = SpeculativeLLMThrottle()

        XCTAssertEqual(throttle.submit("1234567"), .tooShort)
        XCTAssertEqual(throttle.submit("12345678"), .debounce)
    }

    func testSpeculativeMinimumCharacterIncrement() {
        var throttle = SpeculativeLLMThrottle()
        XCTAssertEqual(throttle.submit("12345678"), .debounce)
        XCTAssertTrue(throttle.beginDebouncedRequest(for: "12345678"))
        _ = throttle.requestCompleted(input: "12345678")

        XCTAssertEqual(throttle.submit("123456789012345"), .deltaTooSmall)
        XCTAssertEqual(throttle.submit("1234567890123456"), .debounce)
    }

    func testSpeculativeDebounceKeepsNewestCandidate() {
        var throttle = SpeculativeLLMThrottle()
        XCTAssertEqual(throttle.submit("12345678"), .debounce)
        XCTAssertEqual(throttle.submit("abcdefgh"), .debounce)

        XCTAssertFalse(throttle.beginDebouncedRequest(for: "12345678"))
        XCTAssertTrue(throttle.beginDebouncedRequest(for: "abcdefgh"))
    }

    func testSpeculativeRequestDoesNotRunConcurrently() {
        var throttle = SpeculativeLLMThrottle()
        _ = throttle.submit("12345678")
        XCTAssertTrue(throttle.beginDebouncedRequest(for: "12345678"))

        XCTAssertEqual(throttle.submit("1234567890123456"), .queued)
        XCTAssertFalse(throttle.beginDebouncedRequest(for: "1234567890123456"))
    }

    func testNewestPendingTranscriptIsScheduledAfterCompletion() {
        var throttle = SpeculativeLLMThrottle()
        _ = throttle.submit("12345678")
        _ = throttle.beginDebouncedRequest(for: "12345678")
        XCTAssertEqual(throttle.submit("1234567890123456"), .queued)
        XCTAssertEqual(throttle.submit("123456789012345678901234"), .queued)

        let pending = throttle.requestCompleted(input: "12345678")

        XCTAssertEqual(pending, "123456789012345678901234")
        XCTAssertEqual(throttle.submit(pending!), .debounce)
    }

    func testStopBypassesSpeculativeDebounce() {
        var throttle = SpeculativeLLMThrottle()
        XCTAssertEqual(throttle.submit("12345678"), .debounce)

        throttle.prepareForStop()
        throttle.markStopTimeRequestStarted(input: "12345678")

        XCTAssertTrue(throttle.inFlight)
        XCTAssertNil(throttle.debounceText)
        XCTAssertEqual(throttle.lastStartedText, "12345678")
    }

    func testStopReusesMatchingInFlightTask() async {
        let provisional = Task<String?, Never> {
            try? await Task.sleep(for: .milliseconds(10))
            return "provisional"
        }

        let selection = EarlyLLMTaskSelector.select(
            earlyInput: "12345678",
            finalInput: "12345678",
            needsLLM: true,
            earlyTask: provisional,
            makeFreshTask: { Task { "fresh" } }
        )

        XCTAssertTrue(selection.reused)
        let result = await selection.task?.value
        XCTAssertEqual(result, "provisional")
    }

    func testStopCancelsStaleInFlightTask() async {
        let provisional = Task<String?, Never> {
            try? await Task.sleep(for: .seconds(1))
            return "stale"
        }

        let selection = EarlyLLMTaskSelector.select(
            earlyInput: "12345678",
            finalInput: "12345678新内容",
            needsLLM: true,
            earlyTask: provisional,
            makeFreshTask: { Task { "fresh" } }
        )

        XCTAssertTrue(provisional.isCancelled)
        XCTAssertFalse(selection.reused)
        let result = await selection.task?.value
        XCTAssertEqual(result, "fresh")
    }

    func testFinalTextCanBeInjectedAtMostOncePerGeneration() {
        var guardState = FinalInjectionGuard()

        XCTAssertTrue(guardState.claim(generation: 10))
        XCTAssertFalse(guardState.claim(generation: 10))
        XCTAssertTrue(guardState.claim(generation: 11))
    }

    func testCurrentSessionGenerationAcceptsLLMCompletion() {
        XCTAssertTrue(SessionGenerationGuard.isCurrent(expected: 7, active: 7))
    }

    func testOldSessionGenerationCannotPolluteNewSession() {
        XCTAssertFalse(SessionGenerationGuard.isCurrent(expected: 7, active: 8))
    }
}
