import XCTest
@testable import Type4Me
@testable import Type4MeIntelliSenseCore

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

        await session.setState(.recovering)
        canStart = await session.canStartRecording
        XCTAssertFalse(canStart)
        await session.setState(.idle)
    }

    func testASRConnectFailureIsReportedOnlyForCurrentRecordingSession() {
        XCTAssertTrue(RecognitionSession.shouldReportASRConnectFailure(
            expectedGeneration: 3,
            currentGeneration: 3,
            state: .recording
        ))
        XCTAssertFalse(RecognitionSession.shouldReportASRConnectFailure(
            expectedGeneration: 3,
            currentGeneration: 3,
            state: .finishing
        ))
        XCTAssertFalse(RecognitionSession.shouldReportASRConnectFailure(
            expectedGeneration: 3,
            currentGeneration: 4,
            state: .recording
        ))
    }

    func testRecoveryHotkeyRequiresSecondPressToInterrupt() async {
        let session = RecognitionSession()
        await session.setState(.recovering)

        let first = await session.handleRecoveryHotkeyPress()
        XCTAssertEqual(first, .prompted)
        let stateAfterFirstPress = await session.state
        XCTAssertEqual(stateAfterFirstPress, .recovering)

        let second = await session.handleRecoveryHotkeyPress()
        XCTAssertEqual(second, .interrupted)
        let stateAfterSecondPress = await session.state
        XCTAssertEqual(stateAfterSecondPress, .idle)
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

    func testTranslationTargetAndPromptAreFrozenForSession() async throws {
        let session = RecognitionSession()
        let english = ProcessingMode.translation(target: .english)
        try await session.freezeTranslationModeForTesting(english)

        let firstPrompt = await session.promptForCurrentModeForTesting()
        var changedSetting = ProcessingMode.translation(target: .japanese)
        changedSetting.translationTargetLanguageCode = TranslationLanguage.japanese.rawValue
        await session.replaceTranslationModeSnapshotForTesting(changedSetting)
        let secondPrompt = await session.promptForCurrentModeForTesting()

        let frozenTarget = await session.frozenTranslationTargetForTesting()
        XCTAssertEqual(frozenTarget, .english)
        XCTAssertEqual(secondPrompt, firstPrompt)
        XCTAssertTrue(secondPrompt.contains("English (en)"))
        XCTAssertFalse(secondPrompt.contains("Japanese (ja)"))
    }

    func testIntelliSensePromptUsesCurrentTranscriptWithFrozenContext() async {
        let session = RecognitionSession()
        var settings = IntelliSenseSettings()
        settings.applicationAwarenessEnabled = true
        settings.expressionLearningEnabled = true
        await session.freezeIntelliSenseForTesting(
            snapshot: IntelliSenseContextSnapshot(
                bundleIdentifier: "company.thebrowser.dia",
                appName: "Dia",
                appCategory: .browser,
                controlCategory: .multiLine,
                contextBeforeCursor: "",
                contextAfterCursor: "",
                availability: .appOnly,
                wasTruncated: false
            ),
            settings: settings,
            expressionProfile: EffectiveExpressionProfile(
                directives: ["倾向连续自然段，减少列表。"]
            )
        )

        let speculative = await session.promptForCurrentModeForTesting(
            text: "目前报价模式分为三块。第一块是 license，第二块是 Studio。"
        )
        let final = await session.promptForCurrentModeForTesting(
            text: "目前报价模式分为三块。第一块是 license，第二块是 Studio，第三块是 FDE。"
        )

        XCTAssertTrue(speculative.contains("明确包含 2 个有顺序"))
        XCTAssertTrue(final.contains("明确包含 3 个有顺序"))
        XCTAssertFalse(final.contains("减少列表"))
        XCTAssertTrue(final.contains("company.thebrowser.dia") == false)
    }

    func testUnknownTranslationTargetCannotBeFrozen() async {
        let session = RecognitionSession()
        var mode = ProcessingMode.translation()
        mode.translationTargetLanguageCode = "x-future"

        do {
            try await session.freezeTranslationModeForTesting(mode)
            XCTFail("Expected unsupported target")
        } catch let error as TranslationError {
            XCTAssertEqual(error.errorDescription, L(
                "暂不支持目标语言：x-future",
                "Unsupported target language: x-future"
            ))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnexpectedTranslationLanguageHasUserFacingFailureMessage() {
        let error = TranslationError.unexpectedLanguage(.japanese)

        XCTAssertEqual(error.errorDescription, L(
            "翻译结果不是目标语言（日语），已停止粘贴。",
            "The translation was not in the target language (Japanese) and was not pasted."
        ))
    }

    func testShouldAttemptBatchFallbackWhenStreamingErrorWasObserved() {
        let shouldFallback = RecognitionSession.shouldAttemptBatchFallback(
            uploadFailed: false,
            asrTeardownClean: true,
            streamingError: DeepgramASRError.closed(code: 1008, reason: "policy violation")
        )

        XCTAssertTrue(shouldFallback)
    }

    func testRevisePurposeNeverRunsInputModeLLM() {
        let prepared = RevisePreparedTarget(
            transactionID: UUID(),
            targetID: UUID(),
            targetGeneration: 0,
            sourceRecordID: "record-1",
            currentText: "明天上午 9 点开会",
            currentFullValue: "明天上午 9 点开会",
            currentRange: NSRange(location: 0, length: 10),
            confidence: .exact,
            controlKind: .multiLine,
            sourceModeKind: .direct,
            learningResumePlan: nil,
            isDeletionTombstone: false
        )

        XCTAssertFalse(RecognitionSession.shouldRunInputModeLLM(
            recordingPurpose: .revise(prepared),
            mode: .intelliSense
        ))
        XCTAssertTrue(RecognitionSession.shouldRunInputModeLLM(
            recordingPurpose: .input(.intelliSense),
            mode: .intelliSense
        ))
        XCTAssertFalse(RecognitionSession.shouldRunInputModeLLM(
            recordingPurpose: .input(.direct),
            mode: .direct
        ))
    }

    func testInjectionTrackingIsEnabledIndependentlyForVoiceRevise() {
        XCTAssertTrue(RecognitionSession.shouldTrackInjection(
            shouldTrackLearning: false,
            isReviseActive: true,
            isReviseExcluded: false
        ))
        XCTAssertFalse(RecognitionSession.shouldTrackInjection(
            shouldTrackLearning: false,
            isReviseActive: false,
            isReviseExcluded: false
        ))
        XCTAssertFalse(RecognitionSession.shouldTrackInjection(
            shouldTrackLearning: false,
            isReviseActive: true,
            isReviseExcluded: true
        ))
        XCTAssertTrue(RecognitionSession.shouldTrackInjection(
            shouldTrackLearning: true,
            isReviseActive: true,
            isReviseExcluded: true
        ))
    }

    private func reviseSettingsExcluding(_ bundleIdentifiers: String...) -> ReviseSettings {
        ReviseSettings(
            enabled: true,
            excludedApps: bundleIdentifiers.map {
                ReviseExcludedApp(bundleIdentifier: $0, displayName: $0)
            }
        )
    }

    func testReviseOnlyTrackingRejectsExcludedFrontmostApp() {
        let authorize = RecognitionSession.trackedCaptureAuthorization(
            baseLearningEligible: false,
            isReviseActive: true,
            reviseSettings: reviseSettingsExcluding("com.apple.Terminal")
        )
        XCTAssertFalse(authorize("com.apple.Terminal"))
        XCTAssertTrue(authorize("com.apple.Notes"))
    }

    func testLearningKeepsTrackingWhenReviseExcludesFrontmostApp() {
        let authorize = RecognitionSession.trackedCaptureAuthorization(
            baseLearningEligible: true,
            intelliSenseSettings: IntelliSenseSettings(),
            isReviseActive: true,
            reviseSettings: reviseSettingsExcluding("com.apple.Terminal")
        )
        XCTAssertTrue(authorize("com.apple.Terminal"))
    }

    func testAppSwitchAfterDecisionStopsAXReadInExcludedApp() {
        let authorize = RecognitionSession.trackedCaptureAuthorization(
            baseLearningEligible: false,
            isReviseActive: true,
            reviseSettings: reviseSettingsExcluding("com.apple.Terminal")
        )
        XCTAssertTrue(authorize("com.apple.Notes"))

        var didReadB = false
        let snapshot = TextInjectionEngine.authorizedSnapshot(
            bundleIdentifier: "com.apple.Terminal",
            authorize: authorize
        ) {
            didReadB = true
            return TextInjectionEngine.FocusedElementSnapshot(
                bundleIdentifier: "com.apple.Terminal",
                value: "secret draft",
                hasFocusedElement: true
            )
        }

        XCTAssertNil(snapshot)
        XCTAssertFalse(didReadB)
    }

    func testIntelliSenseBlacklistStopsAXReadEvenWhenT1DecisionWasEligible() {
        var settings = IntelliSenseSettings()
        settings.correctionDetectionEnabled = true
        settings.blacklistedApps = [
            BlacklistedApp(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal")
        ]

        // T1 decision at App A (Notes): eligible
        let authorize = RecognitionSession.trackedCaptureAuthorization(
            baseLearningEligible: true,
            intelliSenseSettings: settings,
            isReviseActive: false,
            reviseSettings: ReviseSettings(enabled: false)
        )
        XCTAssertTrue(authorize("com.apple.Notes"))

        // T2/T3 switch to App B (Terminal, blacklisted in IntelliSense): rejected
        XCTAssertFalse(authorize("com.apple.Terminal"))

        var didReadB = false
        let snapshot = TextInjectionEngine.authorizedSnapshot(
            bundleIdentifier: "com.apple.Terminal",
            authorize: authorize
        ) {
            didReadB = true
            return TextInjectionEngine.FocusedElementSnapshot(
                bundleIdentifier: "com.apple.Terminal",
                value: "sensitive terminal text",
                hasFocusedElement: true
            )
        }

        XCTAssertNil(snapshot)
        XCTAssertFalse(didReadB)
    }

    func testSwitchingFromBlacklistedAppToAllowedAppPermitsLearningCapture() {
        var settings = IntelliSenseSettings()
        settings.correctionDetectionEnabled = true
        settings.blacklistedApps = [
            BlacklistedApp(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal")
        ]

        let authorize = RecognitionSession.trackedCaptureAuthorization(
            baseLearningEligible: true,
            intelliSenseSettings: settings,
            isReviseActive: false,
            reviseSettings: ReviseSettings(enabled: false)
        )
        XCTAssertFalse(authorize("com.apple.Terminal"))
        XCTAssertTrue(authorize("com.apple.Notes"))
    }

    func testAuthorizationFailsClosedOnNilOrEmptyBundleIdentifier() {
        let authorize = RecognitionSession.trackedCaptureAuthorization(
            baseLearningEligible: true,
            intelliSenseSettings: IntelliSenseSettings(),
            isReviseActive: true,
            reviseSettings: ReviseSettings(enabled: true)
        )
        XCTAssertFalse(authorize(nil))
        XCTAssertFalse(authorize(""))
    }

    func testSessionFormattingUsesTheSelectedModeAcrossOutputKinds() throws {
        let suite = "RecognitionSessionTests.Formatting.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(CJKSpacingMode.off.rawValue, forKey: CJKSpacingMode.storageKey)
        defaults.set(TrailingPunctuationMode.period.rawValue, forKey: "tf_stripTrailingPunctuation")

        var quick = ProcessingMode.direct
        quick.punctuationMode = .inherit
        XCTAssertEqual(
            RecognitionSession.formattedOutputText("快速模式。", mode: quick, userDefaults: defaults),
            "快速模式"
        )

        var polished = ProcessingMode.formalWriting
        polished.punctuationMode = .removeAll
        XCTAssertEqual(
            RecognitionSession.formattedOutputText("润色：完成！", mode: polished, userDefaults: defaults),
            "润色完成"
        )

        var intelliSense = ProcessingMode.intelliSense
        intelliSense.punctuationMode = .questionsAndExclamationsOnly
        XCTAssertEqual(
            RecognitionSession.formattedOutputText("智能，完成？Yes!", mode: intelliSense, userDefaults: defaults),
            "智能完成？Yes!"
        )

        var translation = ProcessingMode.translation(target: .english)
        translation.punctuationMode = .stripTrailing
        XCTAssertEqual(
            RecognitionSession.formattedOutputText("Translation complete?!", mode: translation, userDefaults: defaults),
            "Translation complete"
        )
    }

    func testCrossModeFinishFormatsWithTheEndingMode() throws {
        let suite = "RecognitionSessionTests.CrossModeFormatting.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(CJKSpacingMode.off.rawValue, forKey: CJKSpacingMode.storageKey)

        var startingMode = ProcessingMode.direct
        startingMode.punctuationMode = .preserve
        var endingMode = ProcessingMode.formalWriting
        endingMode.punctuationMode = .removeAll
        let processingMode = CrossModeFinishPreference.processingMode(
            startingMode: startingMode,
            endingMode: endingMode,
            isEnabled: true
        )

        XCTAssertEqual(processingMode.id, endingMode.id)
        XCTAssertEqual(
            RecognitionSession.formattedOutputText("跨模式，完成！", mode: processingMode, userDefaults: defaults),
            "跨模式完成"
        )
    }

    func testResolveEffectiveTranscript_batchProviderWithUnfinalizedPartial_returnsEmpty() {
        let partialTranscript = RecognitionTranscript(
            confirmedSegments: [],
            partialText: "未完成的半截识别文本",
            authoritativeText: "未完成的半截识别文本",
            isFinal: false
        )

        let result = RecognitionSession.resolveEffectiveTranscript(
            currentTranscript: partialTranscript,
            providerIsStreaming: false
        )

        XCTAssertEqual(result, .empty)
        XCTAssertTrue(result.displayText.isEmpty)
    }

    func testResolveEffectiveTranscript_batchProviderWithFinalizedTranscript_preservesText() {
        let finalTranscript = RecognitionTranscript(
            confirmedSegments: ["完整识别文本"],
            partialText: "",
            authoritativeText: "完整识别文本",
            isFinal: true
        )

        let result = RecognitionSession.resolveEffectiveTranscript(
            currentTranscript: finalTranscript,
            providerIsStreaming: false
        )

        XCTAssertEqual(result, finalTranscript)
        XCTAssertEqual(result.displayText, "完整识别文本")
    }

    func testResolveEffectiveTranscript_streamingProviderWithPartial_preservesTextForRecovery() {
        let partialTranscript = RecognitionTranscript(
            confirmedSegments: ["前半句"],
            partialText: "后半句",
            authoritativeText: "",
            isFinal: false
        )

        let result = RecognitionSession.resolveEffectiveTranscript(
            currentTranscript: partialTranscript,
            providerIsStreaming: true
        )

        XCTAssertEqual(result, partialTranscript)
        XCTAssertEqual(result.displayText, "前半句后半句")
    }

    func testRecordingTimeTranscriptUpdatesDoNotScheduleOrTriggerLLM() async throws {
        let session = RecognitionSession()
        let mockClient = MockLLMProcessCounter()
        await session.setInjectedLLMClientForTesting(mockClient)
        await session.setState(.recording)

        // Emitting multiple streaming transcript events during recording
        await session.ingestASREventForTesting(.transcript(RecognitionTranscript(
            confirmedSegments: ["今天天气"],
            partialText: "真不错",
            authoritativeText: "",
            isFinal: false
        )))
        await session.ingestASREventForTesting(.transcript(RecognitionTranscript(
            confirmedSegments: ["今天天气真不错"],
            partialText: "我们出去走走",
            authoritativeText: "",
            isFinal: false
        )))

        // Wait beyond old speculative debounce duration (800ms) to prove no background call is fired
        try await Task.sleep(for: .milliseconds(900))

        let processCalls = await mockClient.processCallCount
        XCTAssertEqual(processCalls, 0, "No LLM process call should be scheduled or triggered during recording")
        let state = await session.state
        XCTAssertEqual(state, .recording)
        await session.setState(.idle)
    }

    func testResolveEffectiveTranscriptFeedsBatchFallbackResultToFinalPipeline() {
        // Given a streaming session that failed with only a partial transcript
        let partialTranscript = RecognitionTranscript(
            confirmedSegments: [],
            partialText: "明天下午开",
            authoritativeText: "",
            isFinal: false
        )

        // And batch fallback recovers the full text
        let batchFallbackText = "明天下午开会讨论报价"
        let recoveredTranscript = RecognitionTranscript(
            confirmedSegments: [batchFallbackText],
            partialText: "",
            authoritativeText: batchFallbackText,
            isFinal: true
        )

        // resolveEffectiveTranscript preserves the authoritative recovered text
        let effective = RecognitionSession.resolveEffectiveTranscript(
            currentTranscript: recoveredTranscript,
            providerIsStreaming: true
        )

        XCTAssertEqual(effective.displayText, batchFallbackText)
        XCTAssertNotEqual(effective.displayText, partialTranscript.displayText)
    }

    func testFinalizeEmitsLLMFailedTrueWhenLLMThrows() async throws {
        let session = RecognitionSession()
        let throwingClient = ThrowingMockLLMClient()
        await session.setInjectedLLMClientForTesting(throwingClient)
        let eventBox = FinalizedEventBox()
        await session.setOnASREvent { event in
            Task { await eventBox.record(event) }
        }

        let polishMode = ProcessingMode(
            id: UUID(),
            name: "Test Polish",
            prompt: "Please polish this text",
            isBuiltin: false,
            executionKind: .recording
        )
        let started = await session.startManualInput(modes: [polishMode])
        XCTAssertTrue(started, "Session should start manual input")

        await session.submitManualInput("需要润色的原始文本", mode: polishMode)

        let event = try await eventBox.waitForFinalized(timeout: .seconds(2))
        XCTAssertEqual(event.text, "需要润色的原始文本")
        XCTAssertTrue(event.llmFailed, "When LLM throws, llmFailed must be true in finalized event")
    }

    func testFinalizeEmitsLLMFailedFalseWhenLLMSucceeds() async throws {
        let session = RecognitionSession()
        let successClient = SuccessMockLLMClient(result: "已润色的精炼文本")
        await session.setInjectedLLMClientForTesting(successClient)

        let eventBox = FinalizedEventBox()
        await session.setOnASREvent { event in
            Task { await eventBox.record(event) }
        }

        let polishMode = ProcessingMode(
            id: UUID(),
            name: "Test Polish",
            prompt: "Please polish this text",
            isBuiltin: false,
            executionKind: .recording
        )
        let started = await session.startManualInput(modes: [polishMode])
        XCTAssertTrue(started, "Session should start manual input")

        await session.submitManualInput("需要润色的原始文本", mode: polishMode)

        let event = try await eventBox.waitForFinalized(timeout: .seconds(2))
        XCTAssertEqual(event.text, "已润色的精炼文本")
        XCTAssertFalse(event.llmFailed, "When LLM succeeds, llmFailed must be false in finalized event")
    }

    func testFinalizedEventPreservesLLMFailedFlag() {
        let successEvent = RecognitionEvent.finalized(text: "输出文本", injection: .inserted, llmFailed: false)
        if case .finalized(let text, let injection, let llmFailed) = successEvent {
            XCTAssertEqual(text, "输出文本")
            XCTAssertEqual(injection, .inserted)
            XCTAssertFalse(llmFailed)
        } else {
            XCTFail("Expected .finalized event")
        }

        let failedEvent = RecognitionEvent.finalized(text: "原文文本", injection: .copiedToClipboard, llmFailed: true)
        if case .finalized(let text, let injection, let llmFailed) = failedEvent {
            XCTAssertEqual(text, "原文文本")
            XCTAssertEqual(injection, .copiedToClipboard)
            XCTAssertTrue(llmFailed)
        } else {
            XCTFail("Expected .finalized event")
        }
    }
}

private actor MockLLMProcessCounter: LLMClient {
    private(set) var processCallCount = 0
    private(set) var lastProcessedText: String?

    func process(
        text: String,
        prompt: String,
        config: LLMConfig,
        inputBoundary: LLMInputBoundary
    ) async throws -> String {
        processCallCount += 1
        lastProcessedText = text
        return text
    }

    func warmUp(baseURL: String) async {}
    func invalidate() async {}
}

private actor FinalizedEventBox {
    private var finalizedEvent: (text: String, injection: InjectionOutcome, llmFailed: Bool)?

    func record(_ event: RecognitionEvent) {
        guard case .finalized(let text, let injection, let llmFailed) = event else { return }
        finalizedEvent = (text, injection, llmFailed)
    }

    func waitForFinalized(timeout: Duration) async throws -> (text: String, injection: InjectionOutcome, llmFailed: Bool) {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if let event = finalizedEvent {
                return event
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        struct TimeoutError: Error {}
        throw TimeoutError()
    }
}

private actor ThrowingMockLLMClient: LLMClient {
    enum MockError: Error {
        case simulatedFailure
    }

    func process(
        text: String,
        prompt: String,
        config: LLMConfig,
        inputBoundary: LLMInputBoundary
    ) async throws -> String {
        throw MockError.simulatedFailure
    }

    func warmUp(baseURL: String) async {}
    func invalidate() async {}
}

private actor SuccessMockLLMClient: LLMClient {
    let result: String

    init(result: String) {
        self.result = result
    }

    func process(
        text: String,
        prompt: String,
        config: LLMConfig,
        inputBoundary: LLMInputBoundary
    ) async throws -> String {
        return result
    }

    func warmUp(baseURL: String) async {}
    func invalidate() async {}
}
