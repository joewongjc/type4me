import SwiftUI

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Appearance Settings Tab
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct AppearanceSettingsTab: View, SettingsCardHelpers {

    @Environment(AppState.self) private var appState

    @AppStorage(SettingsTheme.storageKey)
    private var settingsTheme = SettingsTheme.defaultValue.rawValue

    @AppStorage(RecordingTheme.storageKey)
    private var theme = RecordingTheme.defaultValue.rawValue

    @AppStorage(RecordingGlassStyle.storageKey)
    private var glassStyle = RecordingGlassStyle.defaultValue.rawValue

    @AppStorage(RecordingGlassTuning.StorageKey.floorOpacity)
    private var customGlassFloor = RecordingGlassTuning.customDefault.floorOpacity

    @AppStorage(RecordingGlassTuning.StorageKey.edgeFade)
    private var customGlassEdgeFade = RecordingGlassTuning.customDefault.edgeFade

    @AppStorage(RecordingGlassTuning.StorageKey.rimStrength)
    private var customGlassRim = RecordingGlassTuning.customDefault.rimStrength

    @AppStorage(RecordingGlassTuning.StorageKey.glassTint)
    private var customGlassTint = RecordingGlassTuning.customDefault.glassTint

    @AppStorage(RecordingGlassTuning.StorageKey.usesClearGlass)
    private var customGlassUsesClear = RecordingGlassTuning.customDefault.usesClearGlass

    @AppStorage(RecordingGlassTuning.StorageKey.shadowStrength)
    private var customGlassShadow = RecordingGlassTuning.customDefault.shadowStrength

    @AppStorage(RecordingGlassTuning.StorageKey.keepsActiveAppearance)
    private var customGlassKeepsActive = RecordingGlassTuning.customDefault.keepsActiveAppearance

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

    @AppStorage(AppearancePreferenceDefaults.showFinishButtonKey)
    private var showFinishButton = AppearancePreferenceDefaults.showFinishButtonDefault

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

    @AppStorage("tf_language")
    private var language = AppLanguage.systemDefault

    /// Mode id -> that mode's own copy of the whole recording-display block.
    /// A mode absent here follows the global settings edited above.
    @State private var profiles: [UUID: FloatingBarPresentation] = [:]
    @State private var selectedProfileModeID: UUID?

    private static let globalProfileKey = "global"

    private var followsGlobal: Bool {
        guard let selectedProfileModeID else { return false }
        return profiles[selectedProfileModeID] == nil
    }

    private var previewMode: ProcessingMode? {
        appState.availableModes.first { $0.id == selectedProfileModeID }
    }

    @AppStorage(FloatingBarPlacementStore.storageKey) private var placementRaw = ""

    private var isPlacementDefault: Bool {
        FloatingBarPlacementStore.decode(placementRaw).isDefault
    }

    // Compact square-proportioned icon segments following Apple segmented button standards.
    private let themeSegmentWidth: CGFloat = 40
    private var themeControlWidth: CGFloat { themeSegmentWidth * 3 + 8 }

    /// The block currently being edited: the selected mode's profile, or the
    /// global settings. The preview stage renders exactly this.
    private var presentation: FloatingBarPresentation {
        guard let selectedProfileModeID, let profile = profiles[selectedProfileModeID] else {
            return globalPresentation
        }
        return profile
    }

    private var globalPresentation: FloatingBarPresentation {
        FloatingBarPresentation(
            theme: RecordingTheme(rawValue: theme) ?? .dark,
            indicatorStyle: RecordingIndicatorStyle(rawValue: indicatorStyle) ?? .regular,
            visualStyle: RecordingVisualStyle(rawValue: visualStyle) ?? .siri,
            showsLiveTranscript: showLiveTranscript,
            enablesHoverTranscriptPreview: hoverTranscriptPreview,
            showsTooltips: showTooltips,
            showsCancelButton: showCancelButton,
            showsFinishButton: showFinishButton,
            showsModeName: showModeName,
            showsProviderName: showProviderName,
            showsModelName: showModelName
        )
    }

    /// The compact indicator has no orb and no hover preview, so the card hides
    /// the rows that cannot apply to whichever block is being edited.
    private var isCompact: Bool {
        presentation.indicatorStyle == .compact
    }

    private func value<T>(_ keyPath: KeyPath<FloatingBarPresentation, T>) -> T {
        presentation[keyPath: keyPath]
    }

    /// Sends one edited field to the selected mode's profile, or to the global
    /// setting when no mode is selected.
    private func write<T>(
        _ keyPath: WritableKeyPath<FloatingBarPresentation, T>,
        _ newValue: T,
        globally: () -> Void
    ) {
        guard let modeID = selectedProfileModeID else {
            globally()
            return
        }
        guard !followsGlobal else { return }
        var profile = profiles[modeID] ?? globalPresentation
        profile[keyPath: keyPath] = newValue
        persist(profile, for: modeID)
    }

    private func persist(_ profile: FloatingBarPresentation, for modeID: UUID) {
        var updated = profiles
        updated[modeID] = profile
        guard RecordingDisplayProfileStore.persist(updated, appState: appState) else { return }
        profiles = updated
    }

    private func setFollowsGlobal(_ follows: Bool) {
        guard let modeID = selectedProfileModeID else { return }
        if follows {
            var updated = profiles
            updated.removeValue(forKey: modeID)
            guard RecordingDisplayProfileStore.persist(updated, appState: appState) else { return }
            profiles = updated
        } else {
            persist(globalPresentation, for: modeID)
        }
    }

    private func syncProfiles() {
        profiles = appState.recordingDisplayProfiles
        if let selectedProfileModeID,
           !appState.availableModes.contains(where: { $0.id == selectedProfileModeID }) {
            self.selectedProfileModeID = nil
        }
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
            // Preview first so glass tuning below is visible while adjusting.
            AppearancePreviewStage(
                presentation: presentation,
                formattingOptions: formattingOptions,
                mode: previewMode
            )

            Spacer().frame(height: 16)

            settingsGroupCard(L("窗口外观", "Window Appearance"), icon: "paintpalette") {
                settingsOptionRow(
                    L("窗口主题", "Window Theme"),
                    subtitle: L("应用于 Type4Me 窗口；录音浮条主题独立设置。", "Applies to Type4Me windows. The recording bar has its own theme."),
                    controlWidth: themeControlWidth
                ) {
                    settingsInlineIconSegmentedPicker(
                        selection: Binding(
                            get: { SettingsTheme.resolve(settingsTheme).rawValue },
                            set: { settingsTheme = $0 }
                        ),
                        options: [SettingsTheme.system, .light, .dark].map {
                            ($0.rawValue, $0.iconName, $0.displayName(language: AppLanguage(rawValue: language) ?? .en))
                        },
                        segmentWidth: themeSegmentWidth
                    )
                    .accessibilityLabel(L("窗口主题", "Window Theme"))
                }

                // The finish only changes native Liquid Glass (macOS 26+).
                if #available(macOS 26.0, *) {
                    SettingsDivider()
                    glassStyleRow

                    if glassStyle == RecordingGlassStyle.custom.rawValue {
                        customGlassRows
                    }
                }
            }

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 1: 录音显示
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("录音显示", "Recording Display"), icon: "macwindow") {
                profileRow
                SettingsDivider()

                if selectedProfileModeID != nil {
                    followGlobalRow
                    SettingsDivider()
                }

                VStack(alignment: .leading, spacing: 0) {
                    themeRow
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

                    if isCompact {
                        SettingsDivider()
                        showFinishButtonRow
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
                .disabled(followsGlobal)
                .opacity(followsGlobal ? 0.45 : 1)

                SettingsDivider()
                indicatorPositionRow
            }
            .animation(TF.springGentle, value: isCompact)
            .animation(TF.springGentle, value: value(\.showsTooltips))

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
        .onAppear { syncProfiles() }
        .onReceive(NotificationCenter.default.publisher(for: .recordingDisplayProfilesDidChange)) { _ in
            syncProfiles()
        }
    }

    // MARK: - Profile Rows

    /// Selecting a mode only changes the editing target; inheritance is explicit.
    private var profileRow: some View {
        settingsOptionRow(
            L("配置对象", "Applies To"),
            subtitle: L(
                "全局配置是所有跟随全局的模式共用的录音显示配置。",
                "Global Configuration provides the recording-display settings for all modes that follow it."
            ),
            controlWidth: SettingsControlWidth.standard
        ) {
            settingsDropdown(
                selection: Binding(
                    get: { selectedProfileModeID?.uuidString ?? Self.globalProfileKey },
                    set: { rawValue in
                        guard rawValue != Self.globalProfileKey else {
                            selectedProfileModeID = nil
                            return
                        }
                        guard let modeID = UUID(uuidString: rawValue) else { return }
                        selectedProfileModeID = modeID
                    }
                ),
                options: [(Self.globalProfileKey, L("全局配置", "Global Configuration"))]
                    + appState.availableModes.map { ($0.id.uuidString, $0.localizedDisplayName) }
            )
        }
    }

    private var followGlobalRow: some View {
        settingsToggleRow(
            L("跟随全局", "Follow Global"),
            subtitle: L(
                "开启后使用「全局配置」，并随其变化；关闭后可独立设置下方选项。",
                "Use Global Configuration and follow its changes. Turn off to customize the options below."
            ),
            isOn: Binding(
                get: { followsGlobal },
                set: { setFollowsGlobal($0) }
            )
        )
    }


    private var glassStyleRow: some View {
        settingsOptionRow(
            L("浮条玻璃质感", "Bar Glass Finish"),
            subtitle: L(
                "增强（默认）：去掉底色，保持清透、带折射的玻璃，并用外投影显出厚度。标准：原来的样式。自定义：自己调整各项参数。",
                "Enhanced (default) drops the backing for clear, refractive glass with a drop shadow for depth. Standard is the original look. Custom lets you tune each parameter."
            ),
            controlWidth: SettingsControlWidth.standard
        ) {
            settingsInlineSegmentedPicker(
                selection: $glassStyle,
                options: RecordingGlassStyle.allCases.map { ($0.rawValue, $0.displayName) }
            )
            .accessibilityLabel(L("浮条玻璃质感", "Bar Glass Finish"))
        }
    }

    private var isCustomGlassDefault: Bool {
        RecordingGlassTuning(
            floorOpacity: customGlassFloor,
            edgeFade: customGlassEdgeFade,
            rimStrength: customGlassRim,
            glassTint: customGlassTint,
            usesClearGlass: customGlassUsesClear,
            shadowStrength: customGlassShadow,
            keepsActiveAppearance: customGlassKeepsActive
        ) == RecordingGlassTuning.customDefault
    }

    @ViewBuilder
    private var customGlassRows: some View {
        SettingsDivider()
        settingsToggleRow(
            L("清透模式", "Clear Glass"),
            subtitle: L(
                "浮条不会抢焦点，系统默认把它渲染成更磨砂的“非活动”玻璃；开启后保持活动窗口那种清透、带折射的玻璃。下次录音时生效。",
                "The bar never takes focus, so macOS draws it as frostier “inactive” glass. On keeps the clear, refractive glass of a focused window. Applies from the next recording."
            ),
            isOn: $customGlassKeepsActive,
            isIndented: true
        )
        SettingsDivider()
        glassSliderRow(
            L("底色浓度", "Backing Opacity"),
            subtitle: L("玻璃下面的主题色底板。越低越通透，越高文字越清楚。", "Theme-coloured backing under the glass. Lower is clearer; higher keeps text legible."),
            value: $customGlassFloor,
            range: RecordingGlassTuning.floorRange,
            display: percent
        )
        SettingsDivider()
        glassSliderRow(
            L("边缘透光", "Edge Clearance"),
            subtitle: L("底板从边缘往里淡出的宽度，边缘会折射背后的内容。", "How far the backing fades in from the rim, letting the edge refract what's behind."),
            value: $customGlassEdgeFade,
            range: RecordingGlassTuning.edgeFadeRange,
            display: { "\(Int($0.rounded())) pt" }
        )
        SettingsDivider()
        glassSliderRow(
            L("高光强度", "Rim Highlight"),
            value: $customGlassRim,
            range: RecordingGlassTuning.rimStrengthRange,
            display: percent
        )
        SettingsDivider()
        glassSliderRow(
            L("外投影", "Drop Shadow"),
            subtitle: L("在白色等纯色背景上，主要靠投影显出玻璃的厚度。", "On plain light pages the shadow is what gives the glass its depth."),
            value: $customGlassShadow,
            range: RecordingGlassTuning.shadowStrengthRange,
            display: percent
        )
        SettingsDivider()
        glassSliderRow(
            L("玻璃着色", "Glass Tint"),
            subtitle: L("给玻璃材质本身染上主题色。", "Tints the glass material itself with the theme colour."),
            value: $customGlassTint,
            range: RecordingGlassTuning.glassTintRange,
            display: percent
        )
        SettingsDivider()
        settingsOptionRow(
            L("玻璃类型", "Glass Type"),
            subtitle: L("通透：磨砂更少，更能看清背后。", "Clear: less frost, more of the background shows through."),
            controlWidth: SettingsControlWidth.inlineSegmented,
            isIndented: true
        ) {
            settingsInlineSegmentedPicker(
                selection: Binding(
                    get: { customGlassUsesClear ? "clear" : "regular" },
                    set: { customGlassUsesClear = $0 == "clear" }
                ),
                options: [("regular", L("常规", "Regular")), ("clear", L("通透", "Clear"))]
            )
            .accessibilityLabel(L("玻璃类型", "Glass Type"))
        }
        SettingsDivider()
        settingsOptionRow(
            L("自定义参数", "Custom Parameters"),
            isIndented: true
        ) {
            Button(L("恢复默认", "Reset to Default")) {
                let defaults = RecordingGlassTuning.customDefault
                customGlassFloor = defaults.floorOpacity
                customGlassEdgeFade = defaults.edgeFade
                customGlassRim = defaults.rimStrength
                customGlassTint = defaults.glassTint
                customGlassUsesClear = defaults.usesClearGlass
                customGlassShadow = defaults.shadowStrength
                customGlassKeepsActive = defaults.keepsActiveAppearance
            }
            .buttonStyle(.tf(.secondary, size: .small))
            .disabled(isCustomGlassDefault)
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func glassSliderRow(
        _ label: String,
        subtitle: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: @escaping (Double) -> String
    ) -> some View {
        settingsOptionRow(
            label,
            subtitle: subtitle,
            controlWidth: SettingsControlWidth.standard,
            isIndented: true
        ) {
            HStack(spacing: 8) {
                Slider(value: value, in: range)
                    .controlSize(.small)
                    .tint(TF.settingsInk)
                    .accessibilityLabel(label)
                    .accessibilityValue(display(value.wrappedValue))
                Text(display(value.wrappedValue))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(TF.settingsTextSecondary)
                    .frame(width: 44, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }

    private var themeRow: some View {
        settingsOptionRow(
            L("外观主题", "Appearance Theme"),
            controlWidth: SettingsControlWidth.inlineSegmented
        ) {
            settingsInlineSegmentedPicker(
                selection: Binding(
                    get: { value(\.theme).rawValue },
                    set: { rawValue in
                        guard let newTheme = RecordingTheme(rawValue: rawValue) else { return }
                        write(\.theme, newTheme) { theme = rawValue }
                    }
                ),
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
                selection: Binding(
                    get: { value(\.indicatorStyle).rawValue },
                    set: { rawValue in
                        guard let newStyle = RecordingIndicatorStyle(rawValue: rawValue) else { return }
                        write(\.indicatorStyle, newStyle) { indicatorStyle = rawValue }
                    }
                ),
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
                selection: Binding(
                    get: { value(\.visualStyle).rawValue },
                    set: { rawValue in
                        guard let newStyle = RecordingVisualStyle(rawValue: rawValue) else { return }
                        write(\.visualStyle, newStyle) { visualStyle = rawValue }
                    }
                ),
                options: RecordingVisualStyle.allCases.map { ($0.rawValue, $0.displayName) }
            )
        }
    }

    private var liveTranscriptRow: some View {
        settingsToggleRow(
            L("实时展示文本", "Live Transcript"),
            subtitle: L("开启后在录音时显示识别文本", "Show recognized text while recording"),
            isOn: Binding(
                get: { value(\.showsLiveTranscript) },
                set: { newValue in write(\.showsLiveTranscript, newValue) { showLiveTranscript = newValue } }
            )
        )
    }

    private var hoverPreviewRow: some View {
        settingsToggleRow(
            L("悬停文字预览", "Hover Text Preview"),
            isOn: Binding(
                get: { value(\.enablesHoverTranscriptPreview) },
                set: { newValue in write(\.enablesHoverTranscriptPreview, newValue) { hoverTranscriptPreview = newValue } }
            )
        )
    }

    private var showFinishButtonRow: some View {
        settingsToggleRow(
            L("显示录制按钮", "Show Record Button"),
            subtitle: L(
                "关闭后隐藏停止按钮，音波居中显示，仍可通过快捷键结束录制",
                "Hide the stop button and centre the waveform; you can still finish recording with the hotkey"
            ),
            isOn: Binding(
                get: { value(\.showsFinishButton) },
                set: { newValue in write(\.showsFinishButton, newValue) { showFinishButton = newValue } }
            )
        )
    }

    private var showCancelButtonRow: some View {
        settingsToggleRow(
            L("显示取消按钮", "Show Cancel Button"),
            subtitle: L(
                "关闭后隐藏取消按钮，仍可通过 Esc 键取消录制",
                "Hide cancel button; you can still cancel using Esc key"
            ),
            isOn: Binding(
                get: { value(\.showsCancelButton) },
                set: { newValue in write(\.showsCancelButton, newValue) { showCancelButton = newValue } }
            )
        )
    }

    private var showTooltipsRow: some View {
        settingsToggleRow(
            L("显示 Tooltips", "Show Tooltips"),
            subtitle: L(
                "开启后在录音开始与悬停按钮时显示提示气泡",
                "Show hints on recording start and button hover"
            ),
            isOn: Binding(
                get: { value(\.showsTooltips) },
                set: { newValue in write(\.showsTooltips, newValue) { showTooltips = newValue } }
            )
        )
    }

    private var modeNameRow: some View {
        settingsToggleRow(
            L("显示模式名称", "Show Mode Name"),
            subtitle: L("在录音开始提示中显示当前模式", "Show the current mode in the recording-start tooltip"),
            isOn: Binding(
                get: { value(\.showsModeName) },
                set: { newValue in write(\.showsModeName, newValue) { showModeName = newValue } }
            ),
            isEnabled: value(\.showsTooltips),
            isIndented: true
        )
    }

    private var providerNameRow: some View {
        settingsToggleRow(
            L("显示服务商", "Show Provider"),
            subtitle: L("在录音开始提示中显示语音识别服务商", "Show the speech provider in the recording-start tooltip"),
            isOn: Binding(
                get: { value(\.showsProviderName) },
                set: { newValue in write(\.showsProviderName, newValue) { showProviderName = newValue } }
            ),
            isEnabled: value(\.showsTooltips),
            isIndented: true
        )
    }

    private var modelNameRow: some View {
        settingsToggleRow(
            L("显示模型名称", "Show Model Name"),
            subtitle: L("在录音开始提示中显示语音识别模型", "Show the speech model in the recording-start tooltip"),
            isOn: Binding(
                get: { value(\.showsModelName) },
                set: { newValue in write(\.showsModelName, newValue) { showModelName = newValue } }
            ),
            isEnabled: value(\.showsTooltips),
            isIndented: true
        )
    }

    private var indicatorPositionRow: some View {
        settingsOptionRow(
            L("录音条位置", "Recording Bar Position"),
            subtitle: L(
                "将鼠标悬停在录音条上，拖动旁边的手柄即可移动。",
                "Hover over the recording bar and drag its handle to move it."
            )
        ) {
            HStack(spacing: 8) {
                Text(isPlacementDefault ? L("默认", "Default") : L("自定义", "Custom"))
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextSecondary)
                Button(L("恢复默认", "Reset to Default")) {
                    FloatingBarPlacementStore.reset()
                }
                .buttonStyle(.tf(.secondary, size: .small))
                .disabled(isPlacementDefault)
            }
        }
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
