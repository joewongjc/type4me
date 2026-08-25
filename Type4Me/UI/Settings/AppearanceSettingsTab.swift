import SwiftUI

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Appearance Settings Tab
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct AppearanceSettingsTab: View, SettingsCardHelpers {

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

    @AppStorage("tf_stripTrailingPunctuation")
    private var stripTrailingPunctuation = "off"

    @AppStorage(CJKSpacingMode.storageKey)
    private var cjkSpacingMode = CJKSpacingMode.defaultValue

    @AppStorage(CornerQuotePreference.storageKey)
    private var useCornerQuotes = CornerQuotePreference.defaultValue

    @AppStorage("tf_language")
    private var language = AppLanguage.systemDefault

    private var isCompact: Bool {
        indicatorStyle == RecordingIndicatorStyle.compact.rawValue
    }

    private var presentation: FloatingBarPresentation {
        FloatingBarPresentation(
            indicatorStyle: RecordingIndicatorStyle(rawValue: indicatorStyle) ?? .regular,
            visualStyle: RecordingVisualStyle(rawValue: visualStyle) ?? .timeline,
            showsLiveTranscript: showLiveTranscript,
            enablesHoverTranscriptPreview: hoverTranscriptPreview,
            showsTooltips: showTooltips,
            showsCancelButton: showCancelButton
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
                formattingOptions: formattingOptions
            )

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 1: 录音显示
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("录音显示", "Recording Display"), icon: "macwindow") {
                indicatorStyleRow

                if !isCompact {
                    SettingsDivider()
                    visualStyleRow
                    SettingsDivider()
                    liveTranscriptRow
                    SettingsDivider()
                    hoverPreviewRow
                }

                SettingsDivider()
                showTooltipsRow
                SettingsDivider()
                showCancelButtonRow
            }
            .animation(TF.springGentle, value: isCompact)

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

    private var indicatorStyleRow: some View {
        settingsOptionRow(L("指示条外观", "Indicator Style")) {
            settingsDropdown(
                selection: $indicatorStyle,
                options: RecordingIndicatorStyle.allCases.map { ($0.rawValue, $0.displayName) }
            )
        }
    }

    private var visualStyleRow: some View {
        settingsOptionRow(L("录音动效", "Visual Style")) {
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

    private var stripPunctuationRow: some View {
        settingsOptionRow(L("去句末标点", "Strip Trailing Punctuation")) {
            settingsDropdown(
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
            )
        ) {
            settingsDropdown(
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
