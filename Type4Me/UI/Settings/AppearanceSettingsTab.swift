import SwiftUI

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Appearance Settings Tab
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct AppearanceSettingsTab: View, SettingsCardHelpers {

    @AppStorage(RecordingTheme.storageKey)
    private var theme = RecordingTheme.defaultValue.rawValue

    @AppStorage(RecordingIndicatorStyle.storageKey)
    private var indicatorStyle = RecordingIndicatorStyle.defaultValue

    @AppStorage(RecordingVisualStyle.storageKey)
    private var visualStyle = RecordingVisualStyle.defaultValue

    @AppStorage(LiveTranscriptDisplayPreference.storageKey)
    private var showLiveTranscript = LiveTranscriptDisplayPreference.defaultValue

    @AppStorage("tf_hoverTranscriptPreview")
    private var hoverTranscriptPreview = true

    @AppStorage(AppearancePreferenceDefaults.showTooltipsKey)
    private var showTooltips = AppearancePreferenceDefaults.showTooltipsDefault

    @AppStorage(AppearancePreferenceDefaults.showCancelButtonKey)
    private var showCancelButton = AppearancePreferenceDefaults.showCancelButtonDefault

    @AppStorage(RecordingMetadataDisplayPreference.showModeNameKey)
    private var showModeName = RecordingMetadataDisplayPreference.showModeNameDefault

    @AppStorage(RecordingMetadataDisplayPreference.showProviderNameKey)
    private var showProviderName = RecordingMetadataDisplayPreference.showProviderNameDefault

    @AppStorage(RecordingMetadataDisplayPreference.showModelNameKey)
    private var showModelName = RecordingMetadataDisplayPreference.showModelNameDefault

    @AppStorage("tf_stripTrailingPunctuation")
    private var stripTrailingPunctuation = "off"

    @AppStorage(CJKSpacingMode.storageKey)
    private var cjkSpacingMode = CJKSpacingMode.defaultValue

    @AppStorage(CornerQuotePreference.storageKey)
    private var useCornerQuotes = CornerQuotePreference.defaultValue

    @AppStorage(RecordingGlassTuning.transparencyKey)
    private var glassTransparency = RecordingGlassTuning.defaultTransparency
    @AppStorage(RecordingSolidColor.storageKey)
    private var solidColorHex = RecordingSolidColor.defaultHex

    @AppStorage("tf_language")
    private var language = AppLanguage.systemDefault

    private var isCompact: Bool {
        indicatorStyle == RecordingIndicatorStyle.compact.rawValue
    }

    private var showsGlassCalibrationBackdrop: Bool {
        theme == RecordingTheme.light.rawValue
    }

    private var solidColorBinding: Binding<Color> {
        Binding(
            get: { RecordingSolidColor(hex: solidColorHex).color },
            set: { solidColorHex = RecordingSolidColor.hex(from: $0) }
        )
    }

    private var presentation: FloatingBarPresentation {
        FloatingBarPresentation(
            theme: RecordingTheme(rawValue: theme) ?? RecordingTheme.defaultValue,
            indicatorStyle: RecordingIndicatorStyle(rawValue: indicatorStyle) ?? .regular,
            visualStyle: RecordingVisualStyle(rawValue: visualStyle) ?? .siri,
            showsLiveTranscript: showLiveTranscript,
            enablesHoverTranscriptPreview: hoverTranscriptPreview,
            showsTooltips: showTooltips,
            showsCancelButton: showCancelButton,
            showsModeName: showModeName,
            showsProviderName: showProviderName,
            showsModelName: showModelName,
            samplesGlassWithinWindow: true
        )
    }

    private var formattingOptions: TextOutputFormattingOptions {
        TextOutputFormattingOptions(
            cjkSpacingMode: CJKSpacingMode(rawValue: cjkSpacingMode) ?? .pangu,
            usesCornerQuotes: useCornerQuotes,
            trailingPunctuationMode: TrailingPunctuationMode(rawValue: stripTrailingPunctuation) ?? .off
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppearancePreviewStage(
                presentation: presentation,
                formattingOptions: formattingOptions,
                showsGlassCalibrationBackdrop: showsGlassCalibrationBackdrop
            )

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 1: 录音显示
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("录音显示", "Recording Display"), icon: "macwindow") {
                themeRow
                SettingsDivider()
                themeDetailRow
                SettingsDivider()
                indicatorStyleRow
                SettingsDivider()

                if !isCompact {
                    visualStyleRow
                    SettingsDivider()
                }

                liveTranscriptRow

                if !isCompact {
                    SettingsDivider()
                    hoverPreviewRow
                }

                SettingsDivider()
                showCancelButtonRow
                SettingsDivider()

                showTooltipsRow
                SettingsDivider()
                modeNameRow
                SettingsDivider()
                providerNameRow
                SettingsDivider()
                modelNameRow
            }
            .animation(TF.springGentle, value: isCompact)
            .animation(TF.springGentle, value: showTooltips)
            .animation(TF.springGentle, value: theme)

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 2: 文本输出
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("文本输出", "Text Output"), icon: "text.quote") {
                stripPunctuationRow
                SettingsDivider()
                panguSpacingRow
                SettingsDivider()
                cornerQuotesRow
            }
        }
    }

    // MARK: - Row Builders

    @ViewBuilder
    private var themeDetailRow: some View {
        if theme == RecordingTheme.light.rawValue {
            glassTransparencyRow
        } else {
            solidColorRow
        }
    }

    private var glassTransparencyRow: some View {
        glassSliderRow(
            L("玻璃透明度", "Glass Transparency"),
            subtitle: L("只调整毛玻璃版本的透明程度", "Adjusts transparency for the Frosted Glass theme only"),
            value: $glassTransparency
        )
    }

    private var solidColorRow: some View {
        settingsOptionRow(
            L("背景颜色", "Background Color"),
            subtitle: L("纯色不使用毛玻璃", "Solid does not use glass"),
            controlWidth: 150
        ) {
            HStack(spacing: 10) {
                ColorPicker(
                    L("背景颜色", "Background Color"),
                    selection: solidColorBinding,
                    supportsOpacity: false
                )
                .labelsHidden()
                Text(RecordingSolidColor(hex: solidColorHex).hex)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .frame(width: 62, alignment: .trailing)
            }
        }
    }

    private func glassSliderRow(
        _ label: String,
        subtitle: String,
        value: Binding<Double>
    ) -> some View {
        settingsOptionRow(label, subtitle: subtitle, controlWidth: 260) {
            HStack(spacing: 10) {
                Slider(value: value, in: 0...1)
                    .controlSize(.small)
                Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    private var themeRow: some View {
        settingsOptionRow(
            L("外观主题", "Appearance Theme"),
            controlWidth: SettingsControlWidth.inlineSegmented
        ) {
            settingsInlineSegmentedPicker(
                selection: $theme,
                options: RecordingTheme.allCases.map { ($0.rawValue, $0.displayName) }
            )
        }
    }

    private var indicatorStyleRow: some View {
        settingsOptionRow(
            L("指示条风格", "Indicator Style"),
            controlWidth: SettingsControlWidth.inlineSegmented
        ) {
            settingsInlineSegmentedPicker(
                selection: $indicatorStyle,
                options: RecordingIndicatorStyle.allCases.map { ($0.rawValue, $0.displayName) }
            )
        }
    }

    private var visualStyleRow: some View {
        settingsOptionRow(
            L("录音视觉", "Recording Visual"),
            subtitle: L("选择常规指示条的液态玻璃球与文字光效。", "Choose the liquid-glass orb and text glow for the regular indicator.")
        ) {
            settingsDropdown(
                selection: $visualStyle,
                options: RecordingVisualStyle.allCases.map { ($0.rawValue, $0.displayName) }
            )
        }
    }

    private var liveTranscriptRow: some View {
        settingsToggleRow(
            L("实时展示文本", "Live Transcript"),
            subtitle: L("开启后在录音时显示识别文本", "Show recognized text while recording"),
            isOn: $showLiveTranscript
        )
    }

    private var hoverPreviewRow: some View {
        settingsToggleRow(
            L("悬停文字预览", "Hover Text Preview"),
            isOn: $hoverTranscriptPreview
        )
    }

    private var showCancelButtonRow: some View {
        settingsToggleRow(
            L("显示取消按钮", "Show Cancel Button"),
            subtitle: L(
                "关闭后隐藏取消按钮，仍可通过 Esc 键取消录制",
                "Hide cancel button; you can still cancel using Esc key"
            ),
            isOn: $showCancelButton
        )
    }

    private var showTooltipsRow: some View {
        settingsToggleRow(
            L("显示 Tooltips", "Show Tooltips"),
            subtitle: L(
                "开启后在录音开始与悬停按钮时显示提示气泡",
                "Show hints on recording start and button hover"
            ),
            isOn: $showTooltips
        )
    }

    private var modeNameRow: some View {
        settingsToggleRow(
            L("显示模式名称", "Show Mode Name"),
            subtitle: L("在录音开始提示中显示当前模式", "Show the current mode in the recording-start tooltip"),
            isOn: $showModeName,
            isEnabled: showTooltips,
            isIndented: true
        )
    }

    private var providerNameRow: some View {
        settingsToggleRow(
            L("显示服务商", "Show Provider"),
            subtitle: L("在录音开始提示中显示语音识别服务商", "Show the speech provider in the recording-start tooltip"),
            isOn: $showProviderName,
            isEnabled: showTooltips,
            isIndented: true
        )
    }

    private var modelNameRow: some View {
        settingsToggleRow(
            L("显示模型名称", "Show Model Name"),
            subtitle: L("在录音开始提示中显示语音识别模型", "Show the speech model in the recording-start tooltip"),
            isOn: $showModelName,
            isEnabled: showTooltips,
            isIndented: true
        )
    }

    private var stripPunctuationRow: some View {
        settingsOptionRow(
            L("去句末标点", "Strip Trailing Punctuation"),
            controlWidth: SettingsControlWidth.standard
        ) {
            settingsInlineSegmentedPicker(
                selection: $stripTrailingPunctuation,
                options: [
                    ("off", L("不去掉", "Off")),
                    ("period", L("去掉句号", "Periods Only")),
                    ("all", L("去掉所有标点", "All Punctuation")),
                ]
            )
        }
    }

    private var panguSpacingRow: some View {
        settingsOptionRow(
            L("盘古之白", "Pangu Spacing"),
            subtitle: L(
                "自动在中文与英文、数字和半角符号之间添加空格",
                "Automatically add spaces between CJK text and half-width letters, numbers, and symbols"
            ),
            controlWidth: SettingsControlWidth.standard
        ) {
            settingsInlineSegmentedPicker(
                selection: $cjkSpacingMode,
                options: [
                    (CJKSpacingMode.pangu.rawValue, L("开启", "On")),
                    (CJKSpacingMode.off.rawValue, L("关闭", "Off")),
                    (CJKSpacingMode.remove.rawValue, L("移除空格", "Remove Spaces")),
                ]
            )
        }
    }

    private var cornerQuotesRow: some View {
        settingsToggleRow(
            L("使用直角引号「」代替引号“”", "Use Corner Quotes 「」 Instead of Curly Quotes “”"),
            subtitle: L("同时使用『』代替‘’", "Also use 『』 instead of ‘’"),
            isOn: $useCornerQuotes
        )
    }
}
