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
        }

        Window(L("Type4Me 设置", "Type4Me Settings"), id: "settings") {
            SettingsView()
                .environment(appDelegate.appState)
        }
        .defaultSize(width: 1200, height: 800)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)

        Window(L("Type4Me 设置向导", "Type4Me Setup"), id: "setup") {
            SetupWizardView()
                .environment(appDelegate.appState)
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
    private let startSoundDelay: Duration = .milliseconds(200)
    private var floatingBarController: FloatingBarController?
    private let hotkeyManager = HotkeyManager()
    private let session = RecognitionSession()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[Type4Me] applicationDidFinishLaunching")
        KeychainService.migrateIfNeeded()
        HotwordStorage.seedIfNeeded()
        DebugFileLogger.startSession()
        DebugFileLogger.log("applicationDidFinishLaunching")
        floatingBarController = FloatingBarController(state: appState)

        // Bridge ASR events → AppState for floating bar display
        let session = self.session
        let appState = self.appState
        let startSoundDelay = self.startSoundDelay

        SoundFeedback.warmUp()

        // Pre-warm audio subsystem so the first recording starts instantly
        Task { await session.warmUp() }

        // Bridge audio level → isolated meter (no SwiftUI observation overhead)
        Task {
            await session.setOnAudioLevel { level in
                Task { @MainActor in
                    appState.audioLevel.current = level
                }
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
                            NSLog("[Type4Me] playStart scheduled")
                            DebugFileLogger.log("playStart scheduled delayMs=200")
                            try? await Task.sleep(for: startSoundDelay)
                            guard appState.barPhase == .recording else {
                                DebugFileLogger.log("playStart aborted, barPhase=\(String(describing: appState.barPhase))")
                                return
                            }
                            NSLog("[Type4Me] playStart firing")
                            DebugFileLogger.log("playStart firing")
                            SoundFeedback.playStart()
                        }
                    case .transcript(let transcript):
                        appState.setLiveTranscript(transcript)
                    case .completed:
                        appState.stopRecording()
                    case .processingResult(let text):
                        appState.showProcessingResult(text)
                    case .finalized(let text, let injection):
                        appState.finalize(text: text, outcome: injection)
                    case .error(let error):
                        appState.showError(self.userFacingMessage(for: error))
                    }
                }
            }
        }

        // Start periodic update checking
        UpdateChecker.shared.startPeriodicChecking(appState: appState)

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

        // Dynamic activation policy: show dock icon when windows are open
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleManagedWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleManagedWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
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
                    Task { @MainActor in self.appState.stopRecording() }
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
            Task { @MainActor in
                self.appState.currentMode = effectiveMode
                self.appState.stopRecording()
            }
            Task {
                await self.session.switchMode(to: effectiveMode)
                await self.session.stopRecording()
            }
        }
    }

    private var retryTimer: Timer?

    private func startHotkeyWithRetry() {
        let success = hotkeyManager.start()
        NSLog("[Type4Me] Hotkey setup: %@", success ? "OK" : "FAILED (need Accessibility permission)")

        if success {
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }

        // Prompt for accessibility and poll until granted
        PermissionManager.promptAccessibilityPermission()
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
            NSLog("[Type4Me] Hotkey retry: %@", ok ? "OK" : "still failing")
            if ok {
                timer.invalidate()
                retryTimer = nil
            }
        }
    }

    @objc
    private func handleManagedWindowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier?.rawValue == "settings" ||
              window.identifier?.rawValue == "setup" ||
              window.title.contains("Type4Me") else { return }
        NSApp.setActivationPolicy(.regular)
    }

    @objc
    private func handleManagedWindowWillClose(_ notification: Notification) {
        Timer.scheduledTimer(
            timeInterval: 0.3,
            target: self,
            selector: #selector(updateActivationPolicyAfterWindowClose(_:)),
            userInfo: nil,
            repeats: false
        )
    }

    @objc
    private func updateActivationPolicyAfterWindowClose(_ timer: Timer) {
        let hasVisibleWindow = NSApp.windows.contains {
            $0.isVisible && !$0.className.contains("StatusBar") && !$0.className.contains("Panel")
            && $0.level == .normal
        }
        if !hasVisibleWindow {
            NSApp.setActivationPolicy(.accessory)
            // Resign active so menu bar or previous app gets focus
            NSApp.hide(nil)
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        if let captureError = error as? AudioCaptureError,
           let description = captureError.errorDescription {
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

        Button(L("设置向导...", "Setup Wizard...")) {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "setup")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button(L("偏好设置...", "Preferences...")) {
            NSApp.setActivationPolicy(.regular)
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
        case .processing: return appState.currentMode.processingLabel
        case .done: return L("完成", "Done")
        case .error: return L("错误", "Error")
        case .hidden: return L("就绪", "Ready")
        }
    }
}
