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
    @AppStorage("tf_speakerKeepAlive") private var speakerKeepAlive = false
    @AppStorage("tf_micKeepAlive") private var micKeepAlive = false
    @AppStorage("tf_selectedMicrophoneUID") private var selectedMicrophoneUID = ""
    @AppStorage("tf_selectedSpeakerUID") private var selectedSpeakerUID = ""

    @State private var hasMic = false
    @State private var hasAccessibility = false
    @State private var availableMicrophones: [(uid: String, name: String)] = []
    @State private var availableSpeakers: [(uid: String, name: String)] = []

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
            // CARD 1: 录音行为
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("语音识别行为", "Speech Recognition"), icon: "waveform") {
                // Row 1: 提示音 / 录音动效
                HStack(alignment: .top, spacing: 16) {
                    startSoundRow
                        .frame(maxWidth: .infinity)
                    visualStyleRow
                        .frame(maxWidth: .infinity)
                }

                SettingsDivider()

                // Row 2: 降低音量 / 去句末标点
                HStack(alignment: .top, spacing: 16) {
                    volumeReductionRow
                        .frame(maxWidth: .infinity)
                    stripPunctuationRow
                        .frame(maxWidth: .infinity)
                }

                SettingsDivider()

                // Row 3: 麦克风 / 提示音输出
                HStack(alignment: .top, spacing: 16) {
                    microphoneSelectionRow
                        .frame(maxWidth: .infinity)
                    speakerSelectionRow
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
                // Row 1: 音箱保活 / 麦克风保活
                HStack(alignment: .top, spacing: 16) {
                    speakerKeepAliveRow
                        .frame(maxWidth: .infinity)
                    micKeepAliveRow
                        .frame(maxWidth: .infinity)
                }

                SettingsDivider()

                // Row 2: 绕过系统代理
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
        .onChange(of: speakerKeepAlive) { _, _ in
            AudioKeepAliveManager.syncSpeakerState()
        }
        .onChange(of: micKeepAlive) { _, _ in
            AudioKeepAliveManager.syncMicState()
        }
        .onChange(of: selectedSpeakerUID) { _, _ in
            // Restart keep-alive on the new device if active
            SoundFeedback.restartKeepAliveIfNeeded()
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
            settingsDropdown(
                selection: $selectedMicrophoneUID,
                options: [("", L("系统默认", "System Default"))] + availableMicrophones.map { ($0.uid, $0.name) },
                icon: "mic.fill"
            )
        }
        .padding(.vertical, 6)
    }

    private func refreshMicrophones() {
        availableMicrophones = AudioCaptureEngine.availableAudioDevices()
        if !selectedMicrophoneUID.isEmpty,
           !availableMicrophones.contains(where: { $0.uid == selectedMicrophoneUID }) {
            selectedMicrophoneUID = ""
        }
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
                options: [("", L("系统默认", "System Default"))] + availableSpeakers.map { ($0.uid, $0.name) },
                icon: "speaker.wave.2.fill"
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

    private var speakerKeepAliveRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("音箱保活", "Speaker Keep-Alive").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("防止蓝牙音箱休眠断开", "Prevent BT speaker sleep"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            settingsDropdown(
                selection: Binding(
                    get: { speakerKeepAlive ? "on" : "off" },
                    set: { speakerKeepAlive = $0 == "on" }
                ),
                options: [
                    ("on", L("开启", "On")),
                    ("off", L("关闭", "Off")),
                ]
            )
        }
        .padding(.vertical, 6)
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
