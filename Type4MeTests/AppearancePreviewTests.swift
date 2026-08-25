import XCTest
@testable import Type4Me

@MainActor
final class AppearancePreviewTests: XCTestCase {

    // MARK: - FloatingBarPresentation Override & Fallback Tests

    func testFloatingBarPresentationInit() {
        let presentation = FloatingBarPresentation(
            indicatorStyle: .regular,
            visualStyle: .dual,
            showsLiveTranscript: false,
            enablesHoverTranscriptPreview: false,
            showsTooltips: false,
            showsCancelButton: false
        )

        XCTAssertEqual(presentation.indicatorStyle, .regular)
        XCTAssertEqual(presentation.visualStyle, .dual)
        XCTAssertFalse(presentation.showsLiveTranscript)
        XCTAssertFalse(presentation.enablesHoverTranscriptPreview)
        XCTAssertFalse(presentation.showsTooltips)
        XCTAssertFalse(presentation.showsCancelButton)
        XCTAssertTrue(presentation.showsRecordingIndicator)
    }

    func testFloatingBarPresentation_defaults() {
        let presentation = FloatingBarPresentation()
        XCTAssertEqual(presentation.indicatorStyle, .regular)
        XCTAssertEqual(presentation.visualStyle, .timeline)
        XCTAssertTrue(presentation.showsLiveTranscript)
        XCTAssertTrue(presentation.enablesHoverTranscriptPreview)
        XCTAssertTrue(presentation.showsTooltips)
        XCTAssertTrue(presentation.showsCancelButton)
        XCTAssertTrue(presentation.showsRecordingIndicator)
    }

    func testAppearancePreferenceDefaults() {
        XCTAssertEqual(AppearancePreferenceDefaults.showTooltipsKey, "tf_showTooltips")
        XCTAssertTrue(AppearancePreferenceDefaults.showTooltipsDefault)
        XCTAssertEqual(AppearancePreferenceDefaults.showCancelButtonKey, "tf_showCancelButton")
        XCTAssertTrue(AppearancePreferenceDefaults.showCancelButtonDefault)
    }

    func testRecordingChromeWidthDesignTokens() {
        // Dual-button chrome: Finish(35) + Cancel(35) + EdgeInsets*2(20) + Gap*2(16) + Safety(16) = 122
        XCTAssertEqual(TF.recordingChromeWidth, 122)
        // Single-button chrome: Finish(35) + EdgeInsets*2(20) + Gap(8) + Safety(16) = 79
        XCTAssertEqual(TF.recordingSingleButtonChromeWidth, 79)
        // Difference is exactly one control size (35) plus one control gap (8)
        XCTAssertEqual(
            TF.recordingChromeWidth - TF.recordingSingleButtonChromeWidth,
            TF.recordingControlSize + TF.recordingControlGap
        )
    }

    func testFloatingBarPresentation_compactShowsRecordingIndicatorEvenWhenVisualStyleHidden() {
        let compactHidden = FloatingBarPresentation(
            indicatorStyle: .compact,
            visualStyle: .hidden,
            showsLiveTranscript: true,
            enablesHoverTranscriptPreview: true
        )
        XCTAssertTrue(compactHidden.showsRecordingIndicator)

        let regularHidden = FloatingBarPresentation(
            indicatorStyle: .regular,
            visualStyle: .hidden,
            showsLiveTranscript: true,
            enablesHoverTranscriptPreview: true
        )
        XCTAssertFalse(regularHidden.showsRecordingIndicator)
    }

    func testRecordingIndicatorStyle_allCases() {
        XCTAssertEqual(RecordingIndicatorStyle.allCases.count, 2)
        XCTAssertEqual(RecordingIndicatorStyle.regular.rawValue, "regular")
        XCTAssertEqual(RecordingIndicatorStyle.compact.rawValue, "compact")
        XCTAssertEqual(RecordingIndicatorStyle.defaultValue, "regular")
        XCTAssertEqual(RecordingIndicatorStyle.regular.displayName, L("常规", "Regular"))
        XCTAssertEqual(RecordingIndicatorStyle.compact.displayName, L("紧凑型", "Compact"))
    }

    func testRecordingIndicatorStyle_currentResolution() {
        let suite = "Type4MeTests.RecordingIndicatorStyle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Missing key falls back to .regular
        XCTAssertEqual(RecordingIndicatorStyle.current(userDefaults: defaults), .regular)

        // Stored "compact"
        defaults.set("compact", forKey: RecordingIndicatorStyle.storageKey)
        XCTAssertEqual(RecordingIndicatorStyle.current(userDefaults: defaults), .compact)

        // Invalid raw value falls back to .regular
        defaults.set("invalid_style", forKey: RecordingIndicatorStyle.storageKey)
        XCTAssertEqual(RecordingIndicatorStyle.current(userDefaults: defaults), .regular)
    }

    func testCompactIndicatorDesignDimensionsMatchSpecification() {
        XCTAssertEqual(TF.compactIndicatorWidth, 180)
        XCTAssertEqual(TF.compactIndicatorHeight, 24)
        XCTAssertEqual(TF.compactIndicatorControlVisualSize, 15)
        XCTAssertEqual(TF.compactIndicatorWaveBarWidth, 2)
        XCTAssertEqual(TF.compactIndicatorWaveMinHeight, 2)
        XCTAssertEqual(TF.compactIndicatorWaveMaxHeight, 18)
        XCTAssertEqual(TF.compactStatusMaxWidth, TF.barWidth)
    }

    func testRecordingVisualStyle_allCases() {
        XCTAssertEqual(RecordingVisualStyle.classic.displayName, L("线条", "Lines"))
        XCTAssertEqual(RecordingVisualStyle.dual.displayName, L("粒子云", "Particles"))
        XCTAssertEqual(RecordingVisualStyle.timeline.displayName, L("电平", "Levels"))
        XCTAssertEqual(RecordingVisualStyle.effectless.displayName, L("无特效", "No Effects"))
        XCTAssertEqual(RecordingVisualStyle.hidden.displayName, L("无", "None"))

        XCTAssertTrue(RecordingVisualStyle.classic.showsRecordingPanel)
        XCTAssertTrue(RecordingVisualStyle.dual.showsRecordingPanel)
        XCTAssertTrue(RecordingVisualStyle.timeline.showsRecordingPanel)
        XCTAssertTrue(RecordingVisualStyle.effectless.showsRecordingPanel)
        XCTAssertFalse(RecordingVisualStyle.hidden.showsRecordingPanel)

        XCTAssertTrue(RecordingVisualStyle.classic.showsBackgroundEffect)
        XCTAssertTrue(RecordingVisualStyle.dual.showsBackgroundEffect)
        XCTAssertTrue(RecordingVisualStyle.timeline.showsBackgroundEffect)
        XCTAssertFalse(RecordingVisualStyle.effectless.showsBackgroundEffect)
        XCTAssertFalse(RecordingVisualStyle.hidden.showsBackgroundEffect)
    }

    // MARK: - Text Formatting Options Preview Tests

    func testAppearanceFormattingSample_panguEnabled() {
        let options = TextOutputFormattingOptions(
            cjkSpacingMode: .pangu,
            usesCornerQuotes: false,
            trailingPunctuationMode: .off
        )
        let zhSample = AppearancePreviewStage.formattingSamples[0]
        let formattedZh = TextOutputFormatter.format(zhSample, options: options)

        // Should contain spacing between CJK and Latin / Numbers
        XCTAssertTrue(formattedZh.contains("MacBook 上测试 Type4Me 2.1"))
        // Quotes remain curly
        XCTAssertTrue(formattedZh.contains("“这个效果很好”。"))
    }

    func testAppearanceFormattingSample_cornerQuotesEnabled() {
        let options = TextOutputFormattingOptions(
            cjkSpacingMode: .pangu,
            usesCornerQuotes: true,
            trailingPunctuationMode: .off
        )
        let zhSample = AppearancePreviewStage.formattingSamples[0]
        let enSample = AppearancePreviewStage.formattingSamples[1]
        let formattedZh = TextOutputFormatter.format(zhSample, options: options)
        let formattedEn = TextOutputFormatter.format(enSample, options: options)

        // Chinese quotes are converted to corner quotes
        XCTAssertTrue(formattedZh.contains("「这个效果很好」"))
        XCTAssertFalse(formattedZh.contains("“"))
        XCTAssertFalse(formattedZh.contains("”"))

        // English quotes are converted and apostrophe preserved
        XCTAssertTrue(formattedEn.contains("「it’s fast and accurate」") || formattedEn.contains("「it's fast and accurate」"))
    }

    func testAppearanceFormattingSample_stripTrailingPeriods() {
        let options = TextOutputFormattingOptions(
            cjkSpacingMode: .pangu,
            usesCornerQuotes: false,
            trailingPunctuationMode: .period
        )
        let zhSample = AppearancePreviewStage.formattingSamples[0]
        let enSample = AppearancePreviewStage.formattingSamples[1]
        let formattedZh = TextOutputFormatter.format(zhSample, options: options)
        let formattedEn = TextOutputFormatter.format(enSample, options: options)

        // Trailing periods removed from both Chinese and English lines
        XCTAssertTrue(formattedZh.hasSuffix("“这个效果很好”"))
        XCTAssertFalse(formattedZh.hasSuffix("。"))

        XCTAssertTrue(formattedEn.hasSuffix("“it's fast and accurate”") || formattedEn.hasSuffix("“it’s fast and accurate”"))
        XCTAssertFalse(formattedEn.hasSuffix("."))
    }

    func testAppearanceFormattingSample_removeSpaces() {
        let options = TextOutputFormattingOptions(
            cjkSpacingMode: .remove,
            usesCornerQuotes: false,
            trailingPunctuationMode: .off
        )
        let zhSample = AppearancePreviewStage.formattingSamples[0]
        let formattedZh = TextOutputFormatter.format(zhSample, options: options)

        // Spacing removed
        XCTAssertTrue(formattedZh.contains("在MacBook上测试Type4Me 2.1"))
    }

    func testAppearanceFormattingSample_combinedOptions() {
        let options = TextOutputFormattingOptions(
            cjkSpacingMode: .pangu,
            usesCornerQuotes: true,
            trailingPunctuationMode: .period
        )
        let formatted = AppearancePreviewStage.formattingSamples
            .map { TextOutputFormatter.format($0, options: options) }
            .joined(separator: "\n")

        XCTAssertTrue(formatted.contains("在 MacBook 上测试 Type4Me 2.1"))
        XCTAssertTrue(formatted.contains("「这个效果很好」"))
        XCTAssertTrue(formatted.contains("fast and accurate」"))
        XCTAssertFalse(formatted.contains("。"))
        XCTAssertFalse(formatted.hasSuffix("."))
    }

    // MARK: - DemoState Lifecycle & Isolation Tests

    func testDemoState_startAppearancePreview() {
        let demoState = DemoState()
        let sample = "Test Sample Text"

        demoState.startAppearancePreview(sampleText: sample)

        XCTAssertEqual(demoState.demoMode, .appearancePreview)
        XCTAssertEqual(demoState.barPhase, .recording)
        XCTAssertEqual(demoState.segments.count, 1)
        XCTAssertEqual(demoState.transcriptionText, sample)
        XCTAssertNotNil(demoState.recordingStartDate)

        demoState.stop()
        XCTAssertEqual(demoState.demoMode, .quickLoop)
        XCTAssertEqual(demoState.barPhase, .hidden)
        XCTAssertTrue(demoState.segments.isEmpty)
        XCTAssertEqual(demoState.audioLevel.current, 0)
    }

    func testDemoState_updateAppearancePreviewSampleText() {
        let demoState = DemoState()
        demoState.startAppearancePreview(sampleText: "Initial Text")
        XCTAssertEqual(demoState.transcriptionText, "Initial Text")

        demoState.updateAppearancePreview(sampleText: "Updated Text")
        XCTAssertEqual(demoState.transcriptionText, "Updated Text")
        XCTAssertEqual(demoState.barPhase, .recording)
        XCTAssertEqual(demoState.demoMode, .appearancePreview)

        demoState.stop()
    }

    func testDemoState_actionIsolationInAppearancePreviewMode() {
        let demoState = DemoState()
        demoState.startAppearancePreview(sampleText: "Sample")

        // Clicking finish / cancel should not advance or disrupt preview state
        demoState.performRecordingControlAction(.finish)
        XCTAssertEqual(demoState.barPhase, .recording)

        demoState.performRecordingControlAction(.cancel)
        XCTAssertEqual(demoState.barPhase, .recording)

        demoState.stop()
    }

    func testDemoState_actionInQuickLoopMode() {
        let demoState = DemoState()
        demoState.startQuickModeDemo()
        // Wait briefly or simulate recording phase
        demoState.barPhase = .recording

        demoState.performRecordingControlAction(.finish)
        XCTAssertEqual(demoState.barPhase, .processing)

        demoState.stop()
    }

    // MARK: - SettingsTab Appearance Tests

    func testSettingsTab_appearanceProperties() {
        let tab = SettingsTab.appearance
        XCTAssertEqual(tab.rawValue, "appearance")
        XCTAssertEqual(tab.icon, "paintbrush")
        XCTAssertFalse(tab.displayName.isEmpty)
        XCTAssertFalse(tab.subtitle.isEmpty)
        XCTAssertTrue(SettingsTab.allCases.contains(.appearance))
    }
}
