import SwiftUI
import ServiceManagement
import AVFoundation
import ApplicationServices
import Type4MeReviseCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - General Settings Tab
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct GeneralSettingsTab: View, SettingsCardHelpers {

    var showsHeader = true

    // MARK: - Global

    @AppStorage("tf_startSound") private var startSound = StartSoundStyle.chime.rawValue
    @AppStorage("tf_launchAtLogin") private var launchAtLogin = true
    @AppStorage("tf_volumeReduction") private var volumeReduction = -1
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault
    @AppStorage(ClipboardOutputPolicy.storageKey)
    private var clipboardOutputPolicyRaw = ClipboardOutputPolicy.defaultValue.rawValue
    @AppStorage("tf_showDockIcon") private var showDockIcon = true
    @AppStorage("tf_bypassProxy") private var bypassProxy = "off"
    @AppStorage("tf_micKeepAlive") private var micKeepAlive = false
    @AppStorage(CrossModeFinishPreference.storageKey) private var allowCrossModeFinish = CrossModeFinishPreference.defaultValue
    @AppStorage(AudioInputDevicePreferenceStore.modeKey) private var microphonePreferenceMode = AudioInputDevicePreferenceMode.systemDefault.rawValue
    @AppStorage(AudioInputDevicePreferenceStore.priorityEntriesKey) private var microphonePriorityEntriesStorage = ""
    @AppStorage("tf_selectedSpeakerUID") private var selectedSpeakerUID = ""

    @State private var hasMic = false
    @State private var hasAccessibility = false
    @State private var availableMicrophones: [AudioInputDevice] = []
    @State private var availableSpeakers: [(uid: String, name: String)] = []
    @State private var showMicrophonePrioritySheet = false
    @State private var draftMicrophonePriorityEntries: [AudioInputDevicePreferenceEntry] = []

    @State private var reviseSettings: ReviseSettings = ReviseSettingsStore.shared.load()
    @State private var reviseKeyCode: Int? = ReviseSettingsStore.shared.load().hotkey?.keyCode
    @State private var reviseModifiers: UInt64? = ReviseSettingsStore.shared.load().hotkey?.modifiers

    typealias TestStatus = SettingsTestStatus

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                SettingsSectionHeader(
                    label: L("通用", "GENERAL"),
                    title: L("通用设置", "General Settings"),
                    description: L("偏好设置与系统权限。快捷键请在「处理模式」中配置。", "Preferences and permissions. Hotkeys are configured in Modes.")
                )
            }

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 1: 录音设置
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("录音设置", "Recording"), icon: "mic.fill") {
                microphoneSelectionRow
                SettingsDivider()
                volumeReductionRow
                SettingsDivider()
                startSoundRow
                SettingsDivider()
                speakerSelectionRow
                SettingsDivider()
                micKeepAliveRow
                SettingsDivider()
                crossModeFinishRow
            }

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD: 改口设置
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("改口设置", "Revise"), icon: "arrow.triangle.2.circlepath") {
                reviseToggleRow
                if reviseSettings.enabled {
                    SettingsDivider()
                    reviseHotkeyRow
                    SettingsDivider()
                    reviseHotkeyStyleRow
                }
            }

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 3: 系统集成
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("系统集成", "System Integration"), icon: "gearshape.2") {
                launchAtLoginRow
                SettingsDivider()
                dockIconRow
                SettingsDivider()
                preserveClipboardRow
                SettingsDivider()
                languageRow
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
                permissionRow(
                    name: L("麦克风", "Microphone"), granted: hasMic
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

                SettingsDivider()

                permissionRow(
                    name: L("辅助功能", "Accessibility"), granted: hasAccessibility
                ) {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    hasAccessibility = AXIsProcessTrustedWithOptions(options)
                }
            }

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 4: 高级设置
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("高级设置", "Advanced"), icon: "wrench.and.screwdriver") {
                settingsOptionRow(
                    L("绕过系统代理", "Bypass System Proxy"),
                    subtitle: L("不经过代理软件，直连对应服务器", "Connect directly to servers, bypassing proxy")
                ) {
                    settingsDropdown(
                        selection: $bypassProxy,
                        options: [
                            ("off", L("关闭", "Off")),
                            ("all", L("全局绕过", "All Connections")),
                            ("asr", L("语音识别绕过", "ASR Only")),
                            ("llm", L("文本处理 LLM 绕过", "LLM Only")),
                        ]
                    )
                }
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

    // MARK: - Row Builders

    private var startSoundRow: some View {
        settingsOptionRow(L("提示音", "Start Sound")) {
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
    }

    private var crossModeFinishRow: some View {
        settingsToggleRow(
            L("允许跨模式结束", "Allow Cross-Mode Finish"),
            subtitle: L(
                "开启后，使用结束快捷键所属的模式处理文本",
                "When enabled, process text with the mode whose shortcut ends recording"
            ),
            isOn: $allowCrossModeFinish
        )
    }

    private var launchAtLoginRow: some View {
        let isSupported = LoginItemRegistrationPolicy.supportsCurrentProcess
        return settingsToggleRow(
            L("开机自动启动", "Launch at Startup"),
            subtitle: isSupported ? nil : L(
                "仅在 Type4Me 以 App 形式运行时可用",
                "Available only when Type4Me runs as an app"
            ),
            isOn: $launchAtLogin,
            isEnabled: isSupported
        )
    }

    private var volumeReductionRow: some View {
        settingsOptionRow(L("录音时降低音量", "Lower System Volume")) {
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
    }

    private var microphoneSelectionRow: some View {
        settingsOptionRow(
            L("麦克风", "Microphone"),
            subtitle: L("选择音频输入设备", "Select audio input device"),
            controlWidth: SettingsControlWidth.provider
        ) {
            HStack(spacing: 8) {
                Button {
                    refreshMicrophones()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
                .help(L("刷新麦克风列表", "Refresh microphone list"))
                microphonePreferenceDropdown
            }
        }
    }

    private func refreshMicrophones() {
        availableMicrophones = AudioInputDeviceMonitor.shared.refreshSynchronously()
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
            settingsDropdownLabel(
                microphonePreferenceLabel,
                icon: microphonePreference == .priority ? "list.number" : "gearshape"
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
        L("使用当前优先级", "Use Current Priority")
    }

    private var microphonePrioritySummary: String {
        let names = microphonePriorityEntries.map { displayName(for: $0) }
        let visibleNames = Array(names.prefix(2))
        let hiddenCount = max(0, names.count - visibleNames.count)
        let hiddenSummary = hiddenCount > 0 ? [L("另 \(hiddenCount) 个", "\(hiddenCount) more")] : []
        return (visibleNames + hiddenSummary + [L("跟随系统", "System")]).joined(separator: L("、", ", "))
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
        settingsOptionRow(
            L("提示音输出", "Alert Output"),
            subtitle: L("选择提示音播放设备", "Select alert sound device"),
            controlWidth: SettingsControlWidth.provider
        ) {
            HStack(spacing: 8) {
                Button {
                    refreshSpeakers()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
                .help(L("刷新输出设备列表", "Refresh output device list"))
                settingsDropdown(
                    selection: $selectedSpeakerUID,
                    options: [("", L("系统默认", "System Default"))] + availableSpeakers.map { ($0.uid, $0.name) }
                )
            }
        }
    }

    private func refreshSpeakers() {
        availableSpeakers = SoundFeedback.availableOutputDevices()
        if !selectedSpeakerUID.isEmpty,
           !availableSpeakers.contains(where: { $0.uid == selectedSpeakerUID }) {
            selectedSpeakerUID = ""
        }
    }

    private var micKeepAliveRow: some View {
        settingsToggleRow(
            L("麦克风保活", "Mic Keep-Alive"),
            subtitle: L("开启后防止蓝牙麦克风断开", "Prevent Bluetooth microphones from disconnecting"),
            isOn: $micKeepAlive
        )
    }

    // MARK: - Revise Settings Rows

    private var reviseToggleRow: some View {
        settingsToggleRow(
            L("启用改口功能", "Enable Revise"),
            subtitle: L(
                "在刚输入的内容后按快捷键口述修改要求，直接原地修改",
                "Revise recent text in-place by speaking instructions with hotkey"
            ),
            isOn: Binding(
                get: { reviseSettings.enabled },
                set: { newValue in
                    reviseSettings.enabled = newValue
                    persistReviseSettings()
                }
            )
        )
    }

    private var reviseHotkeyRow: some View {
        settingsOptionRow(
            L("改口快捷键", "Revise Hotkey"),
            subtitle: L("默认 fn + R", "Default: fn + R"),
            controlWidth: SettingsControlWidth.provider
        ) {
            HotkeyRecorderView(
                keyCode: Binding(
                    get: { reviseKeyCode },
                    set: { newCode in
                        reviseKeyCode = newCode
                        if let code = newCode {
                            var hk = reviseSettings.hotkey ?? ReviseSettings.defaultHotkey
                            hk.keyCode = code
                            hk.modifiers = reviseModifiers
                            reviseSettings.hotkey = hk
                            persistReviseSettings()
                        }
                    }
                ),
                modifiers: Binding(
                    get: { reviseModifiers },
                    set: { newMods in
                        reviseModifiers = newMods
                        if let code = reviseKeyCode {
                            var hk = reviseSettings.hotkey ?? ReviseSettings.defaultHotkey
                            hk.keyCode = code
                            hk.modifiers = newMods
                            reviseSettings.hotkey = hk
                            persistReviseSettings()
                        }
                    }
                )
            )
        }
    }

    private var reviseHotkeyStyleRow: some View {
        settingsOptionRow(
            L("触发方式", "Trigger Style"),
            subtitle: L("长按松开结束，或单击开始/结束", "Hold to speak, or tap to toggle")
        ) {
            settingsSegmentedPicker(
                selection: Binding(
                    get: { (reviseSettings.hotkey?.style ?? .hold).rawValue },
                    set: { rawValue in
                        guard let newStyle = HotkeyStyle(rawValue: rawValue) else { return }
                        var hk = reviseSettings.hotkey ?? ReviseSettings.defaultHotkey
                        hk.style = newStyle
                        reviseSettings.hotkey = hk
                        persistReviseSettings()
                    }
                ),
                options: [
                    (HotkeyStyle.hold.rawValue, L("长按", "Hold")),
                    (HotkeyStyle.toggle.rawValue, L("单击切换", "Toggle")),
                ]
            )
            .frame(width: 164)
        }
    }

    private func persistReviseSettings() {
        _ = try? ReviseSettingsStore.shared.save(reviseSettings)
        NotificationCenter.default.post(name: .reviseSettingsDidChange, object: nil)
    }

    private var preserveClipboardRow: some View {
        let policy = ClipboardOutputPolicy(rawValue: clipboardOutputPolicyRaw)
            ?? ClipboardOutputPolicy.defaultValue
        return settingsOptionRow(
            L("剪贴板保留", "Clipboard Retention"),
            subtitle: policy.detail
        ) {
            settingsDropdown(
                selection: $clipboardOutputPolicyRaw,
                options: ClipboardOutputPolicy.allCases.map { ($0.rawValue, $0.displayName) }
            )
        }
    }

    private var dockIconRow: some View {
        settingsToggleRow(
            L("显示 Dock 图标", "Show Dock Icon"),
            isOn: $showDockIcon
        )
    }

    private var languageRow: some View {
        settingsOptionRow(L("界面语言", "Primary Language")) {
            settingsDropdown(
                selection: $language,
                options: AppLanguage.allCases.map { ($0.rawValue, $0.displayName) },
                icon: "globe"
            )
        }
    }

    // MARK: - Permission Row

    private func permissionRow(
        name: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        settingsOptionRow(
            name,
            subtitle: granted ? L("已获得系统授权", "System permission granted") : L("需要系统授权", "System permission required"),
            controlWidth: 140
        ) {
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
    }

    // MARK: - Permissions

    private func checkPermissions() {
        hasMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAccessibility = AXIsProcessTrusted()
    }

    // MARK: - Login Item

    private func setLoginItem(enabled: Bool) {
        guard LoginItemRegistrationPolicy.supportsCurrentProcess else {
            launchAtLogin = false
            return
        }
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
        guard LoginItemRegistrationPolicy.supportsCurrentProcess else {
            launchAtLogin = false
            return
        }
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(L("麦克风优先级", "Microphone Priority"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(TF.settingsText)
                    Spacer()
                    Label(L("末尾跟随系统", "System fallback"), systemImage: "gearshape")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(TF.settingsCardAlt.opacity(0.75)))
                }

                Text(L("点一行加入或移除，箭头调整顺序。",
                       "Click a row to add or remove it; use arrows to reorder."))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
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
                }
                .padding(6)
            }
            .frame(height: listHeight)
            .background(RoundedRectangle(cornerRadius: 10).fill(TF.settingsCardAlt.opacity(0.35)))

            HStack(spacing: 10) {
                Text(selectionFooterText)
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(1)
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
        .padding(16)
        .frame(width: 460)
        .background(TF.settingsBg)
    }

    private var allEntries: [AudioInputDevicePreferenceEntry] {
        var result = orderedEntries
        for device in devices where !result.contains(where: { $0.uid == device.uid }) {
            result.append(AudioInputDevicePreferenceEntry(uid: device.uid, name: device.name))
        }
        return result
    }

    private var listHeight: CGFloat {
        guard !allEntries.isEmpty else {
            return 52
        }
        let visibleRows = min(allEntries.count, 5)
        let rowHeight: CGFloat = 40
        let rowSpacing: CGFloat = 5
        let verticalPadding: CGFloat = 12
        return CGFloat(visibleRows) * rowHeight
            + CGFloat(max(visibleRows - 1, 0)) * rowSpacing
            + verticalPadding
    }

    private var selectionFooterText: String {
        L("已选 \(orderedEntries.count) 个，最后自动跟随系统",
          "\(orderedEntries.count) selected, then system fallback")
    }

    private func deviceRow(_ entry: AudioInputDevicePreferenceEntry) -> some View {
        let selectedIndex = orderedEntries.firstIndex(where: { $0.uid == entry.uid })
        let device = devices.first { $0.uid == entry.uid }
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                if let selectedIndex {
                    Text("\(selectedIndex + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(TF.settingsNavActive))
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .frame(width: 22, height: 22)
                }

                Text(device?.name ?? entry.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(device.map { $0.category.displayName } ?? L("未连接", "Offline"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(TF.settingsBg.opacity(0.72)))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                toggleEntry(entry)
            }

            if let selectedIndex {
                HStack(spacing: 2) {
                    iconButton("chevron.up", disabled: selectedIndex == 0) {
                        moveEntry(from: selectedIndex, by: -1)
                    }
                    iconButton("chevron.down", disabled: selectedIndex == orderedEntries.count - 1) {
                        moveEntry(from: selectedIndex, by: 1)
                    }
                    iconButton("minus.circle", disabled: false) {
                        orderedEntries.remove(at: selectedIndex)
                    }
                }
            } else {
                iconButton("plus.circle", disabled: false) {
                    toggleEntry(entry)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selectedIndex == nil ? TF.settingsCardAlt.opacity(0.72) : TF.settingsCardAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selectedIndex == nil ? Color.clear : TF.settingsNavActive.opacity(0.22), lineWidth: 1)
        )
    }

    private func iconButton(_ systemName: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(disabled ? TF.settingsTextTertiary.opacity(0.4) : TF.settingsTextTertiary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
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

    private func toggleEntry(_ entry: AudioInputDevicePreferenceEntry) {
        if let index = orderedEntries.firstIndex(where: { $0.uid == entry.uid }) {
            orderedEntries.remove(at: index)
        } else {
            orderedEntries.append(entry)
        }
    }
}
