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
    @AppStorage("tf_escAbortEnabled") private var escAbortEnabled = true
    @AppStorage("tf_preserveClipboard") private var preserveClipboard = true
    @AppStorage("tf_showDockIcon") private var showDockIcon = true
    @AppStorage("tf_bypassProxy") private var bypassProxy = "off"
    @AppStorage("tf_allowSensitivePromptContext") private var allowSensitivePromptContext = false
    @AppStorage("tf_sonioxAsyncCalibration") private var sonioxAsyncCalibration = false

    @State private var hasMic = false
    @State private var hasAccessibility = false

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

            settingsGroupCard(L("录音行为", "Recording Behavior"), icon: "waveform") {
                // Row 1: 提示音 / 录音动效
                HStack(alignment: .top, spacing: 16) {
                    startSoundRow
                        .frame(maxWidth: .infinity)
                    visualStyleRow
                        .frame(maxWidth: .infinity)
                }

                SettingsDivider()

                // Row 2: 降低音量 / ESC打断
                HStack(alignment: .top, spacing: 16) {
                    volumeReductionRow
                        .frame(maxWidth: .infinity)
                    escAbortRow
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
                VStack(alignment: .leading, spacing: 0) {
                    bypassProxyRow
                    SettingsDivider()
                    sensitivePromptContextRow
                    SettingsDivider()
                    sonioxCalibrationRow
                }
            }

        }
        .task {
            checkPermissions()
            syncLoginItemState()
        }
        .onChange(of: launchAtLogin) { _, newValue in
            setLoginItem(enabled: newValue)
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

    private var escAbortRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("ESC 打断录音", "ESC to Abort").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: Binding(
                    get: { escAbortEnabled ? "on" : "off" },
                    set: { escAbortEnabled = $0 == "on" }
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

    private var bypassProxyRow: some View {
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

    private var sensitivePromptContextRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("云端上下文共享", "Cloud Context Sharing").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: Binding(
                    get: { allowSensitivePromptContext ? "on" : "off" },
                    set: { allowSensitivePromptContext = $0 == "on" }
                ),
                options: [
                    ("off", L("关闭", "Off")),
                    ("on", L("开启", "On")),
                ]
            )
            Text(L("仅当模式 prompt 使用 {selected} 或 {clipboard} 时，允许把选中文本和剪贴板发送给云端 LLM。本地 Ollama 不受此开关限制。", "Allow selected text and clipboard content to be sent to cloud LLMs only when a mode prompt uses {selected} or {clipboard}. Local Ollama is unaffected by this switch."))
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextTertiary)
        }
        .padding(.vertical, 6)
    }

    private var sonioxCalibrationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("SONIOX 二次云端校准", "Soniox Secondary Cloud Pass").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: Binding(
                    get: { sonioxAsyncCalibration ? "on" : "off" },
                    set: { sonioxAsyncCalibration = $0 == "on" }
                ),
                options: [
                    ("off", L("关闭", "Off")),
                    ("on", L("开启", "On")),
                ]
            )
            Text(L("录音结束后把完整音频再上传一次到 Soniox 做异步校准，可提高准确率，但会额外发送整段录音并产生额外计费。", "Upload the full recording to Soniox for an async second pass after stop. This can improve accuracy, but sends the entire recording again and may incur extra billing."))
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextTertiary)
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
