import SwiftUI

@main
struct Type4MeApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra(
            "Type4Me",
            systemImage: appDelegate.appState.barPhase == .hidden ? "mic" : "mic.fill"
        ) {
            MenuBarContent()
                .environment(appDelegate.appState)
                .environment(appDelegate.appUpdater)
        }

        Window(L("Type4Me 设置", "Type4Me Settings"), id: "settings") {
            SettingsView()
                .environment(appDelegate.appState)
                .environment(appDelegate.appUpdater)
        }
        .defaultSize(width: 1200, height: 800)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)

        Window(L("Type4Me 设置向导", "Type4Me Setup"), id: "setup") {
            SetupWizardView()
                .environment(appDelegate.appState)
                .environment(appDelegate.appUpdater)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let appState = AppState()
    let appUpdater = AppUpdater()
    /// Computed dynamically per recording based on audio device topology.
    private var floatingBarController: FloatingBarController?
    private let hotkeyManager = HotkeyManager()
    private let session = RecognitionSession()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[Type4Me] applicationDidFinishLaunching")
        // Show or hide Dock icon based on user preference
        let showDock = UserDefaults.standard.object(forKey: "tf_showDockIcon") as? Bool ?? true
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        KeychainService.migrateIfNeeded()
        HotwordStorage.migrateIfNeeded()
        SnippetStorage.migrateIfNeeded()

        // Sync hotwords to Volcengine cloud table (async, non-blocking)
        VolcHotwordSyncManager.syncIfNeeded()

        DebugFileLogger.startSession()
        DebugFileLogger.log("applicationDidFinishLaunching")
        floatingBarController = FloatingBarController(state: appState)

        // Bridge ASR events → AppState for floating bar display
        let session = self.session

        // 历史记录字数迁移（用 session 自带的 historyStore，迁移后 UI 能刷新）
        Task { await session.historyStore.migrateCharacterCounts() }
        let appState = self.appState

        SoundFeedback.warmUp()
        AudioKeepAliveManager.syncState()

        // Pre-warm audio subsystem so the first recording starts instantly
        Task { await session.warmUp() }

        // Bridge audio level → isolated meter (no SwiftUI observation overhead)
        Task {
            await session.setOnAudioLevel { level in
                appState.audioLevel.current = level
            }
        }

        Task {
            await session.setOnASREvent { event in
                Task { @MainActor in
                    switch event {
                    case .ready:
                        NSLog("[Type4Me] ready event received")
                        DebugFileLogger.log("ready event received, current barPhase=\(String(describing: appState.barPhase))")
                        appState.markRecordingReady()
                        Task { @MainActor in
                            guard appState.barPhase == .recording else {
                                DebugFileLogger.log("playStart aborted, barPhase=\(String(describing: appState.barPhase))")
                                return
                            }
                            NSLog("[Type4Me] playStart firing")
                            DebugFileLogger.log("playStart firing")
                            // BT wake-up preamble is baked into the sound buffer itself.
                            SoundFeedback.playStart()
                            // Lower volume after start sound finishes playing
                            let targetVolumePercent = UserDefaults.standard.integer(forKey: "tf_volumeReduction")
                            if targetVolumePercent >= 0 {
                                try? await Task.sleep(for: .milliseconds(500))
                                guard appState.barPhase == .recording else { return }
                                SystemVolumeManager.lower(to: Float(targetVolumePercent) / 100.0)
                            }
                        }
                    case .transcript(let transcript):
                        appState.setLiveTranscript(transcript)
                    case .completed:
                        appState.stopRecording()
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .processingLabelOverride(let label):
                        appState.processingLabelOverride = label
                    case .processingResult(let text):
                        appState.showProcessingResult(text)
                        self.hotkeyManager.isProcessing = true
                    case .finalized(let text, let injection):
                        appState.finalize(text: text, outcome: injection)
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .error(let error):
                        appState.showError(self.userFacingMessage(for: error))
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    }
                }
            }
        }

        // Start periodic update checking
        UpdateChecker.shared.startPeriodicChecking(appState: appState)
        appUpdater.checkPostUpdateStatus()

        // Reconcile current mode against the active provider before hotkeys are registered.
        refreshModeAvailability()

        // Re-register when modes change in Settings
        NotificationCenter.default.addObserver(
            forName: .modesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.refreshModeAvailability()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .asrProviderDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.refreshModeAvailability()
            }
        }

        // Suppress/resume hotkeys during hotkey recording
        NotificationCenter.default.addObserver(
            forName: .hotkeyRecordingDidStart,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.hotkeyManager.isSuppressed = true
            }
        }
        NotificationCenter.default.addObserver(
            forName: .hotkeyRecordingDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.hotkeyManager.isSuppressed = false
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.startHotkeyWithRetry()
        }

        // Show setup wizard on first launch
        if !appState.hasCompletedSetup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    _ = NSApp.sendAction(Selector(("showSetupWindow:")), to: nil, from: nil)
                }
            }
        }

        // Start SenseVoice Python server if local ASR is selected
        let needsLocalServer = KeychainService.selectedASRProvider == .sherpa
        if needsLocalServer {
            if ModelManager.isQwen3ASRBundled {
                Task {
                    do {
                        try await SenseVoiceServerManager.shared.start()
                    } catch {
                        NSLog("[App] SenseVoice server start failed: %@", String(describing: error))
                    }
                }
            } else if KeychainService.selectedASRProvider == .sherpa {
                // Cloud-only build: local ASR not available, switch to default cloud provider
                NSLog("[App] Local ASR not available (cloud build), switching to volcano")
                KeychainService.selectedASRProvider = .volcano
            }
        }

        // Check if menu bar icon is hidden by macOS 26+ "Allow in Menu Bar" setting
        checkMenuBarVisibility()

        // Listen for Dock icon preference changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dockIconPreferenceChanged(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    private func refreshModeAvailability() {
        let provider = KeychainService.selectedASRProvider
        appState.reconcileCurrentMode(for: provider)
        registerHotkeys(for: provider)
    }

    private func registerHotkeys(for provider: ASRProvider) {
        let availableModes = appState.availableModes
        let modes = ASRProviderRegistry.supportedModes(from: availableModes, for: provider)
        let bindings: [ModeBinding] = modes.compactMap { mode in
            guard let code = mode.hotkeyCode else { return nil }
            let modifiers = CGEventFlags(rawValue: mode.hotkeyModifiers ?? 0)
            let capturedMode = mode
            return ModeBinding(
                modeId: mode.id,
                keyCode: CGKeyCode(code),
                modifiers: modifiers,
                style: capturedMode.hotkeyStyle,
                onStart: { [weak self] in
                    guard let self else { return }

                    let phase = MainActor.assumeIsolated { self.appState.barPhase }

                    // Safety: if already recording, the toggle state is out of sync.
                    // Redirect to stop so we don't discard accumulated text.
                    if phase == .recording || phase == .preparing {
                        NSLog("[Type4Me] >>> HOTKEY: toggle desync – onStart while recording, redirecting to STOP")
                        DebugFileLogger.log("hotkey toggle desync: onStart while recording, redirecting to stop")
                        MainActor.assumeIsolated { self.hotkeyManager.resetActiveState() }
                        MainActor.assumeIsolated { self.appState.stopRecording() }
                        Task { await self.session.stopRecording() }
                        return
                    }

                    // Block new recording while LLM/injection is still in progress.
                    // The current session must finish (paste + history save) before a new one can start.
                    if phase == .processing {
                        NSLog("[Type4Me] >>> HOTKEY: onStart blocked – still processing")
                        DebugFileLogger.log("hotkey onStart blocked: still processing")
                        MainActor.assumeIsolated { self.hotkeyManager.resetActiveState() }
                        return
                    }

                    let selectedProvider = KeychainService.selectedASRProvider
                    let resolvedMode = ASRProviderRegistry.resolvedMode(for: capturedMode, provider: selectedProvider)
                    let effectiveMode = availableModes.first(where: { $0.id == resolvedMode.id }) ?? resolvedMode
                    NSLog("[Type4Me] >>> HOTKEY: Record START (mode: %@)", effectiveMode.name)
                    DebugFileLogger.log("hotkey record start mode=\(effectiveMode.name)")
                    Task { @MainActor in
                        self.appState.currentMode = effectiveMode
                        self.appState.startRecording()
                    }
                    Task { await self.session.startRecording(mode: effectiveMode) }
                },
                onStop: { [weak self] in
                    guard let self else { return }

                    NSLog("[Type4Me] >>> HOTKEY: Record STOP")
                    DebugFileLogger.log("hotkey record stop")
                    MainActor.assumeIsolated { self.appState.stopRecording() }
                    Task { await self.session.stopRecording() }
                }
            )
        }
        hotkeyManager.registerBindings(bindings)

        // Cross-mode stop: user pressed mode B's key while mode A was recording.
        // Switch to mode B and stop, so the recording is processed with mode B.
        hotkeyManager.onCrossModeStop = { [weak self] newModeId in
            guard let self else { return }
            guard let newMode = availableModes.first(where: { $0.id == newModeId }) else { return }
            let selectedProvider = KeychainService.selectedASRProvider
            let resolvedMode = ASRProviderRegistry.resolvedMode(for: newMode, provider: selectedProvider)
            let effectiveMode = availableModes.first(where: { $0.id == resolvedMode.id }) ?? resolvedMode
            NSLog("[Type4Me] >>> HOTKEY: Cross-mode stop → %@", effectiveMode.name)
            DebugFileLogger.log("hotkey cross-mode stop → \(effectiveMode.name)")
            MainActor.assumeIsolated {
                self.appState.currentMode = effectiveMode
                self.appState.stopRecording()
            }
            Task {
                await self.session.switchMode(to: effectiveMode)
                await self.session.stopRecording()
            }
        }

        // ESC abort: skip injection but let recognition/clipboard/history proceed.
        // Returns true if the abort was actually handled (ESC should be swallowed).
        hotkeyManager.onESCAbort = { [weak self] in
            guard let self else { return false }
            let phase = appState.barPhase
            guard phase == .recording || phase == .processing || phase == .preparing else {
                return false  // Not in an active session, let ESC pass through
            }
            NSLog("[Type4Me] >>> HOTKEY: ESC abort injection (phase=%@)", String(describing: phase))
            DebugFileLogger.log("hotkey ESC abort injection phase=\(phase)")
            MainActor.assumeIsolated { self.appState.stopRecording() }
            Task {
                await self.session.abortInjection()
                await self.session.stopRecording()
            }
            return true
        }

        // Sync ESC abort enabled setting to HotkeyManager
        syncESCAbortSetting()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.syncESCAbortSetting()
            }
        }
    }

    private func syncESCAbortSetting() {
        hotkeyManager.isESCAbortEnabled = true
    }

    private var retryTimer: Timer?
    private var hotkeyRetryCount = 0

    private func startHotkeyWithRetry() {
        let success = hotkeyManager.start()
        NSLog("[Type4Me] Hotkey setup: %@", success ? "OK" : "FAILED (need Accessibility permission)")

        if success {
            retryTimer?.invalidate()
            retryTimer = nil
            hotkeyRetryCount = 0
            return
        }

        // Prompt for accessibility and poll until granted
        PermissionManager.promptAccessibilityPermission()
        hotkeyRetryCount = 0
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(
            timeInterval: 2.0,
            target: self,
            selector: #selector(handleHotkeyRetry(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc
    private func handleHotkeyRetry(_ timer: Timer) {
        if PermissionManager.hasAccessibilityPermission {
            let ok = hotkeyManager.start()
            hotkeyRetryCount += 1
            NSLog("[Type4Me] Hotkey retry #%d: %@", hotkeyRetryCount, ok ? "OK" : "still failing")
            if ok {
                timer.invalidate()
                retryTimer = nil
                hotkeyRetryCount = 0
            } else if hotkeyRetryCount >= 5 {
                // Permission granted but event tap still fails (macOS caches denial at kernel level).
                // Suggest restart.
                timer.invalidate()
                retryTimer = nil
                hotkeyRetryCount = 0
                NSLog("[Type4Me] Accessibility granted but hotkey tap failed after retries. Suggesting restart.")
                showRestartAlert()
            }
        }
    }

    private func showRestartAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("辅助功能权限已开启，但快捷键未生效", comment: "")
        alert.informativeText = NSLocalizedString(
            "macOS 有时需要重启应用才能激活全局快捷键。点击「重启」自动重启 Type4Me。",
            comment: ""
        )
        alert.addButton(withTitle: NSLocalizedString("重启", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("稍后", comment: ""))
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            // Relaunch the app
            let url = Bundle.main.bundleURL
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-n", url.path]
            try? task.run()
            NSApp.terminate(nil)
        }
    }

    @objc
    private func dockIconPreferenceChanged(_ notification: Notification) {
        let showDock = UserDefaults.standard.object(forKey: "tf_showDockIcon") as? Bool ?? true
        let current = NSApp.activationPolicy()
        let desired: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        if current != desired {
            NSApp.setActivationPolicy(desired)
        }
    }

    // MARK: - Menu Bar Visibility Check (macOS 26+)

    /// On macOS 26 Tahoe, System Settings > Menu Bar > "Allow in Menu Bar" can hide
    /// third-party status items by rendering them offscreen. Detect this and alert the user.
    private func checkMenuBarVisibility() {
        // Only check on macOS 26+ where this feature exists
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { return }

        // Delay to give SwiftUI MenuBarExtra time to create the status item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.performMenuBarCheck()
            }
        }
    }

    private func performMenuBarCheck() {
        // Find status bar windows belonging to our app.
        // SwiftUI's MenuBarExtra creates an NSStatusBarWindow with a button inside.
        let statusBarWindows = NSApp.windows.filter {
            $0.className.contains("NSStatusBar")
        }

        let isVisible: Bool
        if statusBarWindows.isEmpty {
            // No status bar window at all — icon wasn't created
            isVisible = false
        } else {
            // Check if any status bar window is in a reasonable screen position.
            // macOS 26 moves hidden items far offscreen (e.g. y < -10000).
            // Check against ALL screens to handle multi-monitor setups correctly.
            let allScreens = NSScreen.screens
            isVisible = statusBarWindows.contains { window in
                let frame = window.frame
                return allScreens.contains { screen in
                    let sf = screen.frame
                    return frame.origin.x >= sf.minX - 100
                        && frame.origin.x <= sf.maxX + 100
                        && frame.origin.y >= sf.minY - 100
                }
            }
        }

        guard !isVisible else { return }

        NSLog("[Type4Me] Menu bar icon appears hidden by system settings")

        let alert = NSAlert()
        alert.messageText = L(
            "菜单栏图标被隐藏",
            "Menu Bar Icon Hidden"
        )
        alert.informativeText = L(
            "macOS 的菜单栏设置可能隐藏了 Type4Me 图标。\n\n请前往 系统设置 > 菜单栏，在「允许在菜单栏中显示」列表中开启 Type4Me。",
            "macOS may have hidden the Type4Me icon.\n\nGo to System Settings > Menu Bar and enable Type4Me in the 'Allow in Menu Bar' list."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("打开系统设置", "Open System Settings"))
        alert.addButton(withTitle: L("稍后处理", "Later"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Open Menu Bar settings (macOS 26+)
            if let url = URL(string: "x-apple.systempreferences:com.apple.MenuBar-Settings") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Stored by MenuBarContent so AppDelegate can open the settings window.
    static var openSettingsAction: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous kill: don't rely on async Task, app exits immediately after this returns
        SenseVoiceServerManager.killAllServerProcesses()
    }

    // MARK: - URL Scheme Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "type4me" else { continue }
            switch url.host {
            case "reload-vocabulary":
                NSLog("[Type4Me] URL command: reload-vocabulary")
                SenseVoiceServerManager.syncHotwordsAndRestart()
            case "auth":
                NSLog("[Type4Me] URL command: auth (no-op, code-based auth now)")
            default:
                NSLog("[Type4Me] Unknown URL command: \(url)")
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Self.openSettingsAction?()
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// Only reset hotkey state when no new recording is in progress.
    /// Prevents a stale finalized/completed event from corrupting the toggle
    /// state of a recording that started after the event was emitted.
    private func safeResetHotkeyState() {
        let phase = appState.barPhase
        if phase == .recording || phase == .preparing {
            DebugFileLogger.log("safeResetHotkeyState: skipped (barPhase=\(phase))")
            return
        }
        hotkeyManager.resetActiveState()
    }

    private func userFacingMessage(for error: Error) -> String {
        if let captureError = error as? AudioCaptureError,
           let description = captureError.errorDescription {
            return description
        }

        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }

        let nsError = error as NSError
        if let description = nsError.userInfo[NSLocalizedDescriptionKey] as? String,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }

        return L("录音启动失败", "Failed to start recording")
    }
}

// MARK: - Menu Bar Content

struct MenuBarContent: View {

    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openWindow) private var openSettingsWindow
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }

        Divider()

        // Mode hotkey hints (click to open settings)
        ForEach(appState.availableModes) { mode in
            Button {
                openSettingsWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(
                    name: .navigateToMode, object: mode.id
                )
            } label: {
                let hotkey = mode.hotkeyCode.map {
                    HotkeyRecorderView.keyDisplayName(keyCode: $0, modifiers: mode.hotkeyModifiers)
                }
                Text("\(mode.name)  [\(hotkey ?? L("未绑定", "Unbound"))]")
            }
        }

        Divider()

        Button(L("历史记录...", "History...")) {
            openSettingsWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .navigateToHistory, object: nil)
        }

        Button(L("偏好设置...", "Preferences...")) {
            openSettingsWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button(L("退出 Type4Me", "Quit Type4Me")) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)

        // Force re-render when language changes
        let _ = language

        // Register the settings opener for Dock icon click
        let _ = {
            AppDelegate.openSettingsAction = { [openSettingsWindow] in
                openSettingsWindow(id: "settings")
            }
        }()
    }

    private var statusColor: Color {
        switch appState.barPhase {
        case .preparing: return TF.recording
        case .recording: return TF.recording
        case .processing: return TF.amber
        case .done: return TF.success
        case .error: return TF.settingsAccentRed
        case .hidden: return .secondary.opacity(0.4)
        }
    }

    private var statusText: String {
        switch appState.barPhase {
        case .preparing: return L("录制中", "Recording")
        case .recording: return L("录制中", "Recording")
        case .processing: return appState.effectiveProcessingLabel
        case .done: return L("完成", "Done")
        case .error: return L("错误", "Error")
        case .hidden: return L("就绪", "Ready")
        }
    }
}
