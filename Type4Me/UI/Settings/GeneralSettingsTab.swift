import SwiftUI
import ServiceManagement
import AVFoundation
import ApplicationServices

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - General Settings Tab
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct GeneralSettingsTab: View, SettingsCardHelpers {

    // MARK: - Global

    @AppStorage("tf_startSound") private var startSound = StartSoundStyle.chime.rawValue
    @AppStorage("tf_launchAtLogin") private var launchAtLogin = true
    @AppStorage("tf_volumeReduction") private var volumeReduction = -1
    @AppStorage("tf_visualStyle") private var visualStyle = "timeline"
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault
    @AppStorage("tf_preserveClipboard") private var preserveClipboard = true
    @AppStorage("tf_showDockIcon") private var showDockIcon = true
    @AppStorage("tf_bypassProxy") private var bypassProxy = "off"
    @AppStorage("tf_stripTrailingPunctuation") private var stripTrailingPunctuation = "off"
    @AppStorage("tf_preserveCJKLatinSpacing") private var preserveCJKLatinSpacing = true
    @AppStorage("tf_hoverTranscriptPreview") private var hoverTranscriptPreview = true
    @AppStorage("tf_micKeepAlive") private var micKeepAlive = false
    @AppStorage(AudioInputDevicePreferenceStore.modeKey) private var microphonePreferenceMode = AudioInputDevicePreferenceMode.systemDefault.rawValue
    @AppStorage(AudioInputDevicePreferenceStore.priorityEntriesKey) private var microphonePriorityEntriesStorage = ""
    @AppStorage("tf_selectedSpeakerUID") private var selectedSpeakerUID = ""

    @State private var hasMic = false
    @State private var hasAccessibility = false
    @State private var availableMicrophones: [AudioInputDevice] = []
    @State private var availableSpeakers: [(uid: String, name: String)] = []
    @State private var showMicrophonePrioritySheet = false
    @State private var draftMicrophonePriorityEntries: [AudioInputDevicePreferenceEntry] = []

    typealias TestStatus = SettingsTestStatus

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                label: "GENERAL",
                title: L("通用设置", "General Settings"),
                description: L("偏好设置与系统权限。快捷键请在「处理模式」中配置。", "Preferences and permissions. Hotkeys are configured in Modes.")
            )

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 1: 录音设置
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("录音设置", "Recording"), icon: "mic.fill") {
                // Row 1: 麦克风 / 降低音量
                HStack(alignment: .top, spacing: 16) {
                    microphoneSelectionRow
                        .frame(maxWidth: .infinity)
                    volumeReductionRow
                        .frame(maxWidth: .infinity)
                }

                SettingsDivider()

                // Row 2: 录音动效 / 麦克风保活
                HStack(alignment: .top, spacing: 16) {
                    visualStyleRow
                        .frame(maxWidth: .infinity)
                    micKeepAliveRow
                        .frame(maxWidth: .infinity)
                }
            }

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 2: 语音识别设置
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("语音识别设置", "Speech Recognition"), icon: "waveform") {
                // Row 1: 提示音 / 提示音输出
                HStack(alignment: .top, spacing: 16) {
                    startSoundRow
                        .frame(maxWidth: .infinity)
                    speakerSelectionRow
                        .frame(maxWidth: .infinity)
                }

                SettingsDivider()

                // Row 2: 去句末标点 / 中英文空格 / 悬停文字预览
                HStack(alignment: .top, spacing: 16) {
                    stripPunctuationRow
                        .frame(maxWidth: .infinity)
                    cjkLatinSpacingRow
                        .frame(maxWidth: .infinity)
                    hoverPreviewRow
                        .frame(maxWidth: .infinity)
                }
            }

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 2: 系统集成
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("系统集成", "System Integration"), icon: "gearshape.2") {
                // Row 1: 开机启动 / Dock图标
                HStack(alignment: .top, spacing: 16) {
                    launchAtLoginRow
                        .frame(maxWidth: .infinity)
                    dockIconRow
                        .frame(maxWidth: .infinity)
                }

                SettingsDivider()

                // Row 2: 剪贴板 / 界面语言
                HStack(alignment: .top, spacing: 16) {
                    preserveClipboardRow
                        .frame(maxWidth: .infinity)
                    languageRow
                        .frame(maxWidth: .infinity)
                }
            }

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 3: 系统权限
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(
                L("系统权限", "Permissions"),
                icon: "lock.shield.fill",
                trailing: AnyView(
                    Button {
                        checkPermissions()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(TF.settingsTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("刷新权限状态", "Refresh permission status"))
                )
            ) {
                HStack(spacing: 12) {
                    permissionBlock(
                        icon: "mic.fill", name: L("麦克风", "Microphone"), granted: hasMic
                    ) {
                        AVCaptureDevice.requestAccess(for: .audio) { granted in
                            Task { @MainActor in
                                hasMic = granted
                                if !granted {
                                    NSWorkspace.shared.open(
                                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                                    )
                                }
                            }
                        }
                    }

                    permissionBlock(
                        icon: "accessibility", name: L("辅助功能", "Accessibility"), granted: hasAccessibility
                    ) {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        hasAccessibility = AXIsProcessTrustedWithOptions(options)
                    }
                }
            }

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 4: 高级设置
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("高级设置", "Advanced"), icon: "wrench.and.screwdriver") {
                // 绕过系统代理
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("绕过系统代理", "Bypass System Proxy").uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(TF.settingsTextTertiary)
                    settingsDropdown(
                        selection: $bypassProxy,
                        options: [
                            ("off", L("关闭", "Off")),
                            ("all", L("全局绕过", "All Connections")),
                            ("asr", L("语音识别绕过", "ASR Only")),
                            ("llm", L("文本处理 LLM 绕过", "LLM Only")),
                        ]
                    )
                    Text(L("不经过代理软件，直连对应服务器", "Connect directly to servers, bypassing proxy"))
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .padding(.vertical, 6)
            }

        }
        .task {
            checkPermissions()
            syncLoginItemState()
            refreshMicrophones()
            refreshSpeakers()
        }
        .onChange(of: launchAtLogin) { _, newValue in
            setLoginItem(enabled: newValue)
        }
        .onChange(of: micKeepAlive) { _, _ in
            AudioKeepAliveManager.syncMicState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .audioInputDevicesDidChange)) { _ in
            refreshMicrophones()
        }
        .sheet(isPresented: $showMicrophonePrioritySheet) {
            MicrophonePrioritySheet(
                devices: availableMicrophones,
                initialEntries: draftMicrophonePriorityEntries,
                onCancel: {
                    showMicrophonePrioritySheet = false
                },
                onSave: { entries in
                    saveMicrophonePriority(entries)
                    showMicrophonePrioritySheet = false
                }
            )
        }
    }

    // MARK: - Layout Helpers

    private func moduleHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(TF.settingsText)
                .padding(.bottom, 12)
        }
    }

    private func moduleSpacer() -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 20)
            Divider()
            Spacer().frame(height: 20)
        }
    }

    private func twoColumnLayout<Left: View, Right: View>(
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                left()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                right()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 16) {
                left()
                right()
            }
        }
    }

    // MARK: - Row Builders

    private func settingsToggleRow(_ label: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(TF.settingsText)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(minHeight: 40)
        .padding(.vertical, 6)
    }

    private var startSoundRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("提示音", "Start Sound").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: $startSound,
                options: StartSoundStyle.allCases.map { ($0.rawValue, $0.displayName) }
            )
            .onChange(of: startSound) { _, newValue in
                if let style = StartSoundStyle(rawValue: newValue) {
                    SoundFeedback.previewStartSound(style)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var visualStyleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("录音动效", "Visual Style").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsSegmentedPicker(
                selection: $visualStyle,
                options: [
                    ("classic", L("线条", "Lines")),
                    ("dual", L("粒子云", "Blocks")),
                    ("timeline", L("电平", "Minimal")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var launchAtLoginRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("开机自动启动", "Launch at Startup").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: Binding(
                    get: { launchAtLogin ? "on" : "off" },
                    set: { launchAtLogin = $0 == "on" }
                ),
                options: [
                    ("on", L("开启", "On")),
                    ("off", L("关闭", "Off")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var volumeReductionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("录音时降低音量", "Lower System Volume").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: Binding(
                    get: { String(volumeReduction) },
                    set: { volumeReduction = Int($0) ?? -1 }
                ),
                options: [
                    ("-1", L("不降低", "Off")),
                    ("50", "50%"),
                    ("40", "40%"),
                    ("30", "30%"),
                    ("20", "20%"),
                    ("10", "10%"),
                    ("0", L("静音", "Mute")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var stripPunctuationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("去句末标点", "Strip Trailing Punctuation").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: $stripTrailingPunctuation,
                options: [
                    ("off", L("不去掉", "Off")),
                    ("period", L("去掉句号", "Periods Only")),
                    ("all", L("去掉所有标点", "All Punctuation")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var cjkLatinSpacingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("中英文空格", "CJK-Latin Spacing").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: Binding(
                    get: { preserveCJKLatinSpacing ? "on" : "off" },
                    set: { preserveCJKLatinSpacing = $0 == "on" }
                ),
                options: [
                    ("on", L("保留", "Keep")),
                    ("off", L("去掉", "Strip")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var hoverPreviewRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("悬停文字预览", "Hover Text Preview").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: Binding(
                    get: { hoverTranscriptPreview ? "on" : "off" },
                    set: { hoverTranscriptPreview = $0 == "on" }
                ),
                options: [
                    ("on", L("开启", "On")),
                    ("off", L("关闭", "Off")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var microphoneSelectionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("麦克风", "Microphone").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("选择音频输入设备", "Select audio input device"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
                Spacer()
                Button {
                    refreshMicrophones()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
                .help(L("刷新麦克风列表", "Refresh microphone list"))
            }

            microphonePreferenceDropdown
        }
        .padding(.vertical, 6)
    }

    private func refreshMicrophones() {
        let devices = AudioCaptureEngine.availableAudioInputDevices()
        availableMicrophones = devices
        AudioInputDeviceMonitor.shared.replaceCachedDevices(devices)
    }

    private var microphonePreferenceDropdown: some View {
        Menu {
            Button {
                setMicrophoneSystemDefault()
            } label: {
                Label(
                    L("跟随系统", "Follow System"),
                    systemImage: microphonePreference == .systemDefault ? "checkmark" : "gearshape"
                )
            }

            if microphonePriorityEntries.isEmpty {
                Button {
                    openMicrophonePrioritySheet()
                } label: {
                    Label(L("指定优先级", "Set Priority"), systemImage: "list.number")
                }
            } else {
                Divider()
                Button {
                    microphonePreferenceMode = AudioInputDevicePreferenceMode.priority.rawValue
                } label: {
                    Label(
                        microphonePriorityMenuLabel,
                        systemImage: microphonePreference == .priority ? "checkmark" : "list.number"
                    )
                }
                Button {
                    openMicrophonePrioritySheet()
                } label: {
                    Label(L("修改优先级", "Edit Priority"), systemImage: "slider.horizontal.3")
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: microphonePreference == .priority ? "list.number" : "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextTertiary)
                Text(microphonePreferenceLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(TF.settingsText)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(TF.settingsCardAlt)
            )
        }
        .buttonStyle(.plain)
    }

    private var microphonePreference: AudioInputDevicePreferenceMode {
        AudioInputDevicePreferenceMode(rawValue: microphonePreferenceMode) ?? .systemDefault
    }

    private var microphonePriorityEntries: [AudioInputDevicePreferenceEntry] {
        AudioInputDevicePreferenceStore.priorityEntries(from: microphonePriorityEntriesStorage)
    }

    private var microphonePreferenceLabel: String {
        guard microphonePreference == .priority, !microphonePriorityEntries.isEmpty else {
            return L("跟随系统", "Follow System")
        }
        return L("当前优先级：\(microphonePrioritySummary)",
                 "Priority: \(microphonePrioritySummary)")
    }

    private var microphonePriorityMenuLabel: String {
        L("当前优先级：\(microphonePrioritySummary)",
          "Current Priority: \(microphonePrioritySummary)")
    }

    private var microphonePrioritySummary: String {
        let names = microphonePriorityEntries.map { displayName(for: $0) }
        return (names + [L("跟随系统", "System")]).joined(separator: L("、", ", "))
    }

    private func openMicrophonePrioritySheet() {
        refreshMicrophones()
        let currentEntries = refreshedPriorityEntries(microphonePriorityEntries)
        draftMicrophonePriorityEntries = currentEntries.isEmpty
            ? availableMicrophones.map { AudioInputDevicePreferenceEntry(uid: $0.uid, name: $0.name) }
            : currentEntries
        showMicrophonePrioritySheet = true
    }

    private func refreshedPriorityEntries(
        _ entries: [AudioInputDevicePreferenceEntry]
    ) -> [AudioInputDevicePreferenceEntry] {
        entries.map { entry in
            guard let device = availableMicrophones.first(where: { $0.uid == entry.uid }) else {
                return entry
            }
            return AudioInputDevicePreferenceEntry(uid: entry.uid, name: device.name)
        }
    }

    private func displayName(for entry: AudioInputDevicePreferenceEntry) -> String {
        availableMicrophones.first(where: { $0.uid == entry.uid })?.name ?? entry.name
    }

    private func saveMicrophonePriority(_ entries: [AudioInputDevicePreferenceEntry]) {
        let storage = AudioInputDevicePreferenceStore.storageValue(for: entries)
        guard !storage.isEmpty else {
            microphonePreferenceMode = AudioInputDevicePreferenceMode.systemDefault.rawValue
            microphonePriorityEntriesStorage = ""
            return
        }
        microphonePreferenceMode = AudioInputDevicePreferenceMode.priority.rawValue
        microphonePriorityEntriesStorage = storage
    }

    private func setMicrophoneSystemDefault() {
        microphonePreferenceMode = AudioInputDevicePreferenceMode.systemDefault.rawValue
    }

    private var speakerSelectionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("提示音输出", "Alert Output").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("选择提示音播放设备", "Select alert sound device"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
                Spacer()
                Button {
                    refreshSpeakers()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
                .help(L("刷新输出设备列表", "Refresh output device list"))
            }
            settingsDropdown(
                selection: $selectedSpeakerUID,
                options: [("", L("系统默认", "System Default"))] + availableSpeakers.map { ($0.uid, $0.name) }
            )
        }
        .padding(.vertical, 6)
    }

    private func refreshSpeakers() {
        availableSpeakers = SoundFeedback.availableOutputDevices()
        if !selectedSpeakerUID.isEmpty,
           !availableSpeakers.contains(where: { $0.uid == selectedSpeakerUID }) {
            selectedSpeakerUID = ""
        }
    }

    private var micKeepAliveRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("麦克风保活", "Mic Keep-Alive").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("防止蓝牙麦克风断开", "Prevent BT mic disconnect"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            settingsDropdown(
                selection: Binding(
                    get: { micKeepAlive ? "on" : "off" },
                    set: { micKeepAlive = $0 == "on" }
                ),
                options: [
                    ("on", L("开启", "On")),
                    ("off", L("关闭", "Off")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var preserveClipboardRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("注入剪贴板", "Copy to Clipboard").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("开启后始终写入剪贴板", "Always copy to clipboard"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            settingsDropdown(
                selection: Binding(
                    get: { preserveClipboard ? "off" : "on" },
                    set: { preserveClipboard = $0 != "on" }
                ),
                options: [
                    ("on", L("开启", "On")),
                    ("off", L("关闭", "Off")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var dockIconRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("DOCK 图标", "Dock Icon").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("隐藏后仅保留菜单栏", "Menu bar only when hidden"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            settingsDropdown(
                selection: Binding(
                    get: { showDockIcon ? "on" : "off" },
                    set: { showDockIcon = $0 == "on" }
                ),
                options: [
                    ("on", L("显示", "Show")),
                    ("off", L("隐藏", "Hide")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var languageRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("界面语言", "Primary Language").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: $language,
                options: AppLanguage.allCases.map { ($0.rawValue, $0.displayName) },
                icon: "globe"
            )
        }
        .padding(.vertical, 6)
    }

    // MARK: - Permission Block

    private func permissionBlock(
        icon: String,
        name: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(granted ? TF.settingsAccentGreen : TF.settingsTextTertiary)
                )

            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TF.settingsText)

            Spacer()

            if granted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsAccentGreen)
                    Text(L("已授权", "Authorized"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TF.settingsAccentGreen)
                }
            } else {
                Button { action() } label: {
                    Text(L("授权", "Grant"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsAccentAmber))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
    }

    // MARK: - Permissions

    private func checkPermissions() {
        hasMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAccessibility = AXIsProcessTrusted()
    }

    // MARK: - Login Item

    private func setLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = !enabled
        }
    }

    private func syncLoginItemState() {
        let status = SMAppService.mainApp.status
        if status == .notRegistered, !UserDefaults.standard.bool(forKey: "tf_didInitialLoginItemSetup") {
            // First launch: register login item by default
            UserDefaults.standard.set(true, forKey: "tf_didInitialLoginItemSetup")
            setLoginItem(enabled: true)
        } else {
            launchAtLogin = status == .enabled
        }
    }
}

private struct MicrophonePrioritySheet: View {
    let devices: [AudioInputDevice]
    let initialEntries: [AudioInputDevicePreferenceEntry]
    let onCancel: () -> Void
    let onSave: ([AudioInputDevicePreferenceEntry]) -> Void

    @State private var orderedEntries: [AudioInputDevicePreferenceEntry]

    init(
        devices: [AudioInputDevice],
        initialEntries: [AudioInputDevicePreferenceEntry],
        onCancel: @escaping () -> Void,
        onSave: @escaping ([AudioInputDevicePreferenceEntry]) -> Void
    ) {
        self.devices = devices
        self.initialEntries = initialEntries
        self.onCancel = onCancel
        self.onSave = onSave
        _orderedEntries = State(initialValue: initialEntries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("麦克风优先级", "Microphone Priority"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
                Text(L("Type4Me 会按顺序使用可用设备，最后回退到系统默认。",
                       "Type4Me uses the first available device, then falls back to system default."))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if allEntries.isEmpty {
                        Text(L("当前没有可用输入设备。", "No input devices are currently available."))
                            .font(.system(size: 12))
                            .foregroundStyle(TF.settingsTextTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    } else {
                        ForEach(allEntries) { entry in
                            deviceRow(entry)
                        }
                    }

                    systemFallbackRow
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 320)

            HStack {
                Spacer()
                Button(L("取消", "Cancel"), action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

                Button {
                    onSave(orderedEntries)
                } label: {
                    Text(L("保存", "Save"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(orderedEntries.isEmpty ? TF.settingsTextTertiary : TF.settingsAccentAmber)
                        )
                }
                .buttonStyle(.plain)
                .disabled(orderedEntries.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(TF.settingsBg)
    }

    private var allEntries: [AudioInputDevicePreferenceEntry] {
        var result = orderedEntries
        for device in devices where !result.contains(where: { $0.uid == device.uid }) {
            result.append(AudioInputDevicePreferenceEntry(uid: device.uid, name: device.name))
        }
        return result
    }

    private var systemFallbackRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TF.settingsTextTertiary)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("最后：跟随系统", "Last: Follow System"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsText)
                Text(L("所有指定设备都不可用时使用。", "Used when none of the selected devices are available."))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt.opacity(0.55)))
    }

    private func deviceRow(_ entry: AudioInputDevicePreferenceEntry) -> some View {
        let selectedIndex = orderedEntries.firstIndex(where: { $0.uid == entry.uid })
        let device = devices.first { $0.uid == entry.uid }
        return HStack(spacing: 10) {
            if let selectedIndex {
                Text("\(selectedIndex + 1)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(TF.settingsNavActive))
            } else {
                Image(systemName: "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(device?.name ?? entry.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsText)
                    .lineLimit(1)
                Text(device.map { $0.category.displayName } ?? L("未连接", "Offline"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }

            Spacer()

            if let selectedIndex {
                iconButton("chevron.up", disabled: selectedIndex == 0) {
                    moveEntry(from: selectedIndex, by: -1)
                }
                iconButton("chevron.down", disabled: selectedIndex == orderedEntries.count - 1) {
                    moveEntry(from: selectedIndex, by: 1)
                }
                iconButton("minus.circle", disabled: false) {
                    orderedEntries.remove(at: selectedIndex)
                }
            } else {
                iconButton("plus.circle", disabled: false) {
                    orderedEntries.append(entry)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
    }

    private func iconButton(_ systemName: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(disabled ? TF.settingsTextTertiary.opacity(0.4) : TF.settingsTextTertiary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func moveEntry(from index: Int, by offset: Int) {
        let newIndex = index + offset
        guard orderedEntries.indices.contains(index), orderedEntries.indices.contains(newIndex) else {
            return
        }
        let entry = orderedEntries.remove(at: index)
        orderedEntries.insert(entry, at: newIndex)
    }
}
