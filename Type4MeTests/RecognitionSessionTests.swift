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

}
