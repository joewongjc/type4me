import AppKit
import XCTest
@testable import Type4Me

@MainActor
final class AppearancePreviewTests: XCTestCase {

    func testRecordingTheme_allCases() {
        XCTAssertEqual(RecordingTheme.allCases.count, 2)
        XCTAssertEqual(RecordingTheme.dark.rawValue, "dark")
        XCTAssertEqual(RecordingTheme.light.rawValue, "light")
        XCTAssertEqual(RecordingTheme.storageKey, "tf_recordingTheme")
        XCTAssertEqual(RecordingTheme.defaultValue, .light)

        XCTAssertEqual(RecordingTheme.dark.displayName, L("纯色", "Solid"))
        XCTAssertEqual(RecordingTheme.light.displayName, L("毛玻璃版本", "Frosted Glass"))
        XCTAssertFalse(RecordingTheme.dark.usesGlass)
        XCTAssertTrue(RecordingTheme.light.usesGlass)
    }

    func testRecordingIndicatorStyle_allCases() {
        XCTAssertEqual(RecordingIndicatorStyle.allCases.count, 2)
        XCTAssertEqual(RecordingIndicatorStyle.regular.displayName, L("常规", "Regular"))
        XCTAssertEqual(RecordingIndicatorStyle.compact.displayName, L("紧凑", "Compact"))
    }

    func testFloatingBarPresentationInit() {
        let presentation = FloatingBarPresentation(
            theme: .light,
            indicatorStyle: .regular,
            visualStyle: .voiceWave,
            showsLiveTranscript: false,
            enablesHoverTranscriptPreview: false,
            showsTooltips: false,
            showsCancelButton: false,
            showsModeName: true,
            showsProviderName: true,
            showsModelName: true
        )

        XCTAssertEqual(presentation.theme, .light)
        XCTAssertEqual(presentation.indicatorStyle, .regular)
        XCTAssertEqual(presentation.visualStyle, .voiceWave)
        XCTAssertFalse(presentation.showsLiveTranscript)
        XCTAssertFalse(presentation.enablesHoverTranscriptPreview)
        XCTAssertFalse(presentation.showsTooltips)
        XCTAssertFalse(presentation.showsCancelButton)
        XCTAssertTrue(presentation.showsModeName)
        XCTAssertTrue(presentation.showsProviderName)
        XCTAssertTrue(presentation.showsModelName)
        XCTAssertTrue(presentation.showsRecordingIndicator)
    }

    func testFloatingBarPresentation_defaults() {
        let presentation = FloatingBarPresentation()
        XCTAssertEqual(presentation.theme, .light)
        XCTAssertEqual(presentation.indicatorStyle, .regular)
        XCTAssertEqual(presentation.visualStyle, .siri)
        XCTAssertTrue(presentation.showsLiveTranscript)
        XCTAssertTrue(presentation.enablesHoverTranscriptPreview)
        XCTAssertTrue(presentation.showsTooltips)
        XCTAssertTrue(presentation.showsCancelButton)
        XCTAssertTrue(presentation.showsModeName)
        XCTAssertFalse(presentation.showsProviderName)
        XCTAssertFalse(presentation.showsModelName)
        XCTAssertTrue(presentation.showsRecordingIndicator)
    }

    func testAppearancePreferenceDefaults() {
        XCTAssertEqual(AppearancePreferenceDefaults.showTooltipsKey, "tf_showTooltips")
        XCTAssertTrue(AppearancePreferenceDefaults.showTooltipsDefault)
        XCTAssertEqual(AppearancePreferenceDefaults.showCancelButtonKey, "tf_showCancelButton")
        XCTAssertTrue(AppearancePreferenceDefaults.showCancelButtonDefault)
    }

    func testRecordingGlassTuning_defaultsMatchCurrentSurface() {
        let tuning = RecordingGlassTuning()

        XCTAssertEqual(tuning.transparency, 0.10)
        XCTAssertEqual(tuning.materialOpacity, 0.90)
    }

    func testRecordingGlassTuning_clampsCompositingValues() {
        let tuning = RecordingGlassTuning(transparency: 1.4)

        XCTAssertEqual(tuning.transparency, 1)
        XCTAssertEqual(tuning.materialOpacity, 0)
    }

    func testRecordingSolidColorDefaultsToWhiteAndAdaptsContrast() {
        let defaultColor = RecordingSolidColor(hex: RecordingSolidColor.defaultHex)
        XCTAssertEqual(defaultColor.hex, "#FFFFFF")
        XCTAssertTrue(defaultColor.usesDarkForeground)

        let light = RecordingSolidColor(hex: "#F6F6F8")
        XCTAssertEqual(light.hex, "#F6F6F8")
        XCTAssertTrue(light.usesDarkForeground)

        XCTAssertEqual(
            RecordingSolidColor(hex: "not-a-color").hex,
            RecordingSolidColor.defaultHex
        )
    }

    func testRecordingGlassTuning_migratesLegacyOpacityToTransparency() throws {
        let suiteName = "Type4MeTests.RecordingGlassTuning.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(0.7, forKey: "tf_recordingGlassMaterialOpacity")

        RecordingGlassTuning.migrateLegacyPreferencesIfNeeded(userDefaults: defaults)

        XCTAssertEqual(
            defaults.double(forKey: RecordingGlassTuning.transparencyKey),
            0.3,
            accuracy: 0.001
        )
    }

    func testVisualEffectBlurConfigurationAppliesNativeGlassControls() {
        let visualEffect = VisualEffectBlur(
            cornerRadius: 17,
            blendingMode: .withinWindow,
            appearanceName: .aqua,
            blurEffect: .frosted,
            transparency: 0.58,
            tintColor: NSColor(white: 0.25, alpha: 0.4)
        )
        let view = RecordingGlassEffectHostView()

        visualEffect.configure(view)

        XCTAssertEqual(view.alphaValue, 0.42, accuracy: 0.001)
        XCTAssertEqual(view.layer?.cornerRadius, 17)
        XCTAssertEqual(view.appearance?.name, .aqua)
        XCTAssertEqual(view.appliedBlurEffect, .frosted)
        XCTAssertEqual(view.appliedTintColor, NSColor(white: 0.25, alpha: 0.4))
        if #available(macOS 26.0, *) {
            XCTAssertTrue(view.usesNativeLiquidGlass)
            XCTAssertEqual(view.nativeGlassStyle, .regular)
            XCTAssertEqual(view.nativeGlassTintColor, NSColor(white: 0.25, alpha: 0.4))
        }

        VisualEffectBlur(
            blurEffect: .clear,
            transparency: 0.58
        ).configure(view)
        XCTAssertEqual(view.appliedBlurEffect, .clear)
        XCTAssertEqual(view.alphaValue, 0.42, accuracy: 0.001)
        XCTAssertNil(view.appliedTintColor)
        XCTAssertEqual(view.subviews.count, 1)
        if #available(macOS 26.0, *) {
            XCTAssertEqual(view.nativeGlassStyle, .clear)
            XCTAssertNil(view.nativeGlassTintColor)
        }
    }

    func testNativeGlassStyleUpdatesReuseHostAndPreserveCompositorInputs() {
        guard #available(macOS 26.0, *) else { return }

        let view = RecordingGlassEffectHostView()
        let combinations: [(RecordingGlassBlurEffect, Double, CGFloat, CGFloat)] = [
            (.clear, 0.15, 0.2, 0.35),
            (.frosted, 0.65, 0.8, 0.75),
        ]

        for (blurEffect, transparency, luminance, tintStrength) in combinations {
            let tint = NSColor(white: luminance, alpha: tintStrength)
            VisualEffectBlur(
                cornerRadius: 22,
                blurEffect: blurEffect,
                transparency: transparency,
                tintColor: tint
            ).configure(view)

            XCTAssertEqual(
                view.nativeGlassStyle,
                blurEffect == .frosted ? .regular : .clear
            )
            XCTAssertEqual(view.alphaValue, 1 - transparency, accuracy: 0.001)
            XCTAssertEqual(view.nativeGlassTintColor, tint)
            XCTAssertEqual(view.layer?.cornerRadius, 22)
            XCTAssertEqual(view.subviews.count, 1)
        }
    }

    func testRecordingMetadataDisplayPreferenceDefaults() {
        XCTAssertTrue(RecordingMetadataDisplayPreference.showModeNameDefault)
        XCTAssertFalse(RecordingMetadataDisplayPreference.showProviderNameDefault)
        XCTAssertFalse(RecordingMetadataDisplayPreference.showModelNameDefault)
    }

    func testRecordingChromeWidthDesignTokens() {
        // Both controls use 45pt layout slots, even though cancel draws a 35pt
        // circle. Equal slots keep the middle text lane centered.
        XCTAssertEqual(TF.recordingControlSlotSize, 45)
        XCTAssertEqual(TF.recordingChromeWidth, 138)
        // With cancel hidden, its slot disappears; a 22pt trailing buffer
        // mirrors the orb-side gap plus the 14pt text fade guard.
        XCTAssertEqual(TF.recordingSingleButtonMirroredTextBuffer, 22)
        XCTAssertEqual(TF.recordingSingleButtonChromeWidth, 107)
        XCTAssertEqual(TF.recordingSingleButtonMinimumWidth, 110)
        XCTAssertEqual(TF.recordingTranscriptFadeWidth, 14)
    }

    func testSingleButtonRecordingWidthRemovesTheMissingControlsSlot() {
        let listeningTextWidth: CGFloat = 42
        let dualButtonWidth = recordingBaseCapsuleWidth(
            textWidth: listeningTextWidth,
            showsCancelButton: true
        )
        let singleButtonWidth = recordingBaseCapsuleWidth(
            textWidth: listeningTextWidth,
            showsCancelButton: false
        )

        XCTAssertEqual(dualButtonWidth, 180)
        XCTAssertEqual(singleButtonWidth, 149)
        XCTAssertLessThan(singleButtonWidth, dualButtonWidth)
        XCTAssertEqual(
            singleButtonWidth - listeningTextWidth,
            TF.recordingSingleButtonChromeWidth
        )

        let textLaneWidth = singleButtonWidth
            - TF.recordingEdgeInset * 2
            - TF.recordingControlSlotSize
            - TF.recordingControlGap
            - TF.recordingSingleButtonMirroredTextBuffer
        let laneSlack = (textLaneWidth - listeningTextWidth) / 2
        XCTAssertEqual(laneSlack, 8)

        // The reserved trailing area remains outside the text lane even after
        // the capsule reaches its 400pt maximum width.
        let maximumTextLaneWidth = TF.barWidth
            - TF.recordingEdgeInset * 2
            - TF.recordingControlSlotSize
            - TF.recordingControlGap
            - TF.recordingSingleButtonMirroredTextBuffer
        XCTAssertEqual(maximumTextLaneWidth, 309)
        XCTAssertEqual(
            TF.recordingEdgeInset + TF.recordingSingleButtonMirroredTextBuffer,
            30
        )
    }

    func testRecordingModeHintWidthExpandsAroundAClampedCenter() {
        XCTAssertEqual(recordingModeHintWidth(textWidth: 100), 124)
        XCTAssertEqual(
            recordingModeHintWidth(textWidth: 1_000),
            TF.barWidth + TF.recordingTooltipOverhang * 2
        )
    }

    func testFloatingBarPresentation_showsRecordingIndicatorAlwaysTrueWhenConfigured() {
        let compact = FloatingBarPresentation(
            indicatorStyle: .compact,
            visualStyle: .staticGlass,
            showsLiveTranscript: true,
            enablesHoverTranscriptPreview: true
        )
        XCTAssertTrue(compact.showsRecordingIndicator)

        let regular = FloatingBarPresentation(
            indicatorStyle: .regular,
            visualStyle: .staticGlass,
            showsLiveTranscript: true,
            enablesHoverTranscriptPreview: true
        )
        XCTAssertTrue(regular.showsRecordingIndicator)
    }

    func testPreviewPhase_allCases() {
        XCTAssertEqual(PreviewPhase.allCases.count, 2)
        XCTAssertEqual(PreviewPhase.recording.displayName, L("录音中", "Recording"))
        XCTAssertEqual(PreviewPhase.processing.displayName, L("处理中", "Processing"))
    }

    func testRecordingVisualStyle_allCases() {
        XCTAssertEqual(RecordingVisualStyle.siri.displayName, L("Siri 波澜", "Siri Ripple"))
        XCTAssertEqual(RecordingVisualStyle.blueDrop.displayName, L("蓝晶液滴", "Blue Crystal Drop"))
        XCTAssertEqual(RecordingVisualStyle.chromaticMetal.displayName, L("色差液态金属", "Chromatic Liquid Metal"))
        XCTAssertEqual(RecordingVisualStyle.frost.displayName, L("冰霜流体", "Frost Fluid"))
        XCTAssertEqual(RecordingVisualStyle.opal.displayName, L("虹彩欧泊", "Iridescent Opal"))
        XCTAssertEqual(RecordingVisualStyle.voiceWave.displayName, L("声纹薄膜", "Voiceprint Membrane"))
        XCTAssertEqual(RecordingVisualStyle.violetEmber.displayName, L("紫焰流核", "Violet Flame Core"))
        XCTAssertEqual(RecordingVisualStyle.aurora.displayName, L("极光帷幕", "Aurora Veil"))
        XCTAssertEqual(RecordingVisualStyle.chrome.displayName, L("液态铬", "Liquid Chrome"))
        XCTAssertEqual(RecordingVisualStyle.spectrum.displayName, L("彩色声场", "Color Soundfield"))
        XCTAssertEqual(RecordingVisualStyle.staticSiri.displayName, L("静态 Siri (低能耗)", "Static Siri (Power-saving)"))

        XCTAssertTrue(RecordingVisualStyle.siri.isAnimated)
        XCTAssertFalse(RecordingVisualStyle.staticSiri.isAnimated)
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
        XCTAssertFalse(demoState.segments.isEmpty)
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

    // MARK: - Compact Live Transcript Tests

    func testCompactTranscriptOffset() {
        // Text fits comfortably inside viewport: no offset (leading aligned)
        XCTAssertEqual(compactTranscriptOffset(textWidth: 0, viewportWidth: 164), 0)
        XCTAssertEqual(compactTranscriptOffset(textWidth: 80, viewportWidth: 164), 0)
        // Exactly at viewport boundary: no offset
        XCTAssertEqual(compactTranscriptOffset(textWidth: 164, viewportWidth: 164), 0)
        // Text overflows viewport: negative offset aligns text tail to right edge
        XCTAssertEqual(compactTranscriptOffset(textWidth: 190, viewportWidth: 164), -26)
        XCTAssertEqual(compactTranscriptOffset(textWidth: 300, viewportWidth: 164), -136)
    }

    func testCompactLiveTranscriptDesignTokens() {
        XCTAssertEqual(TF.compactIndicatorWidth, 180)
        XCTAssertEqual(TF.compactIndicatorHeight, 24)
        XCTAssertEqual(TF.compactTranscriptLaneHeight, 24)
        XCTAssertEqual(TF.compactTranscriptExpandedHeight, 48)
        XCTAssertEqual(TF.compactTranscriptFontSize, 12)
        XCTAssertEqual(TF.compactTranscriptCornerRadius, 10)
        XCTAssertEqual(TF.compactTranscriptHorizontalInset, 8)
        XCTAssertEqual(TF.compactTranscriptLeadingFadeWidth, 10)

        // Viewport width arithmetic contract
        let viewportWidth = TF.compactIndicatorWidth - TF.compactTranscriptHorizontalInset * 2
        XCTAssertEqual(viewportWidth, 164)

        // Height arithmetic contract
        XCTAssertEqual(
            TF.compactTranscriptLaneHeight + TF.compactIndicatorHeight,
            TF.compactTranscriptExpandedHeight
        )
    }

    func testFloatingBarPresentation_compactLiveTranscriptSupport() {
        let compactLiveOn = FloatingBarPresentation(
            indicatorStyle: .compact,
            showsLiveTranscript: true
        )
        XCTAssertEqual(compactLiveOn.indicatorStyle, .compact)
        XCTAssertTrue(compactLiveOn.showsLiveTranscript)

        let compactLiveOff = FloatingBarPresentation(
            indicatorStyle: .compact,
            showsLiveTranscript: false
        )
        XCTAssertEqual(compactLiveOff.indicatorStyle, .compact)
        XCTAssertFalse(compactLiveOff.showsLiveTranscript)
    }

    func testFloatingBarPresentation_switchingStylesPreservesCorrectPreferences() {
        var presentation = FloatingBarPresentation(
            indicatorStyle: .compact,
            showsLiveTranscript: true
        )
        XCTAssertEqual(presentation.indicatorStyle, .compact)
        XCTAssertTrue(presentation.showsLiveTranscript)

        // Switch to regular
        presentation.indicatorStyle = .regular
        XCTAssertEqual(presentation.indicatorStyle, .regular)
        XCTAssertTrue(presentation.showsLiveTranscript)

        // Switch live transcript off
        presentation.showsLiveTranscript = false
        XCTAssertFalse(presentation.showsLiveTranscript)
    }

    func testFloatingBarPanelLayout_fallbackWithLiveTranscript() {
        let compactLiveOn = FloatingBarPanelLayout.fallback(for: .compact, showsLiveTranscript: true)
        XCTAssertEqual(compactLiveOn.contentSize, NSSize(width: TF.barWidthCompact, height: TF.compactTranscriptExpandedHeight))
        XCTAssertEqual(compactLiveOn.capsuleSize, NSSize(width: TF.barWidthCompact, height: TF.compactTranscriptExpandedHeight))
        XCTAssertEqual(compactLiveOn.panelSize, NSSize(width: 196, height: 64))

        let compactLiveOff = FloatingBarPanelLayout.fallback(for: .compact, showsLiveTranscript: false)
        XCTAssertEqual(compactLiveOff.contentSize, NSSize(width: TF.barWidthCompact, height: TF.compactIndicatorHeight))
        XCTAssertEqual(compactLiveOff.capsuleSize, NSSize(width: TF.barWidthCompact, height: TF.compactIndicatorHeight))
        XCTAssertEqual(compactLiveOff.panelSize, NSSize(width: 196, height: 40))

        let regular = FloatingBarPanelLayout.fallback(for: .regular)
        XCTAssertEqual(regular.contentSize, NSSize(width: TF.barWidthCompact, height: TF.barHeight))
        XCTAssertEqual(regular.capsuleSize, NSSize(width: TF.barWidthCompact, height: TF.barHeight))
        XCTAssertEqual(regular.panelSize, NSSize(width: 196, height: 71))
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
