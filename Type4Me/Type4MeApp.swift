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
                .environment(appDelegate.menuBarControlCenterModel)
                .environment(appDelegate.menuBarActionCoordinator)
        }

        Window(L("Type4Me 设置", "Type4Me Settings"), id: "settings") {
            SettingsView()
                .environment(appDelegate.appState)
                .environment(appDelegate.appUpdater)
                .environment(appDelegate.navigationModel)
                .environment(appDelegate.askAnythingCoordinator)
        }
        .defaultSize(width: 1200, height: 800)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: [])

        Window(L("Type4Me 设置向导", "Type4Me Setup"), id: "setup") {
            SetupWizardView()
                .environment(appDelegate.appState)
                .environment(appDelegate.appUpdater)
                .environment(appDelegate.permissionGuideModel)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: [])

        Window(L("Type4Me 授权引导", "Type4Me Permissions"), id: "permission-guide") {
            PermissionGuideView(model: appDelegate.permissionGuideModel)
                .frame(minWidth: 520, idealWidth: 560, minHeight: 460, idealHeight: 480)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: [])
    }
}

@MainActor
final class RecordingControlCoordinator {
    private let onFollowUpAction: (RecordingControlAction) -> Bool
    private let onStandardAction: (RecordingControlAction) -> Void

    init(
        onFollowUpAction: @escaping (RecordingControlAction) -> Bool,
        onStandardAction: @escaping (RecordingControlAction) -> Void
    ) {
        self.onFollowUpAction = onFollowUpAction
        self.onStandardAction = onStandardAction
    }

    func perform(_ action: RecordingControlAction) {
        if onFollowUpAction(action) { return }
        onStandardAction(action)
    }
}

struct SelectionAskFollowUpStartGate {
    private(set) var generation = 0

    mutating func begin() -> Int {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func allowsStart(
        token: Int,
        isFollowUpActive: Bool,
        phase: FloatingBarPhase
    ) -> Bool {
        token == generation
            && isFollowUpActive
            && (phase == .preparing || phase == .recording)
    }
}

struct RecordingStartGate {
    private(set) var generation = 0

    mutating func begin() -> Int {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func allowsStart(token: Int) -> Bool {
        token == generation
    }
}

enum RecordingStartSource: String {
    case hotkey
    case menuBar
    case reviseHotkey
    case reviseMenuBar
    case urlScheme

    /// Only ordinary user-controlled recording entry points may opt into the
    /// recording-end target. Specialized and automated flows keep their current
    /// target contract even if the global preference is changed.
    var allowsConfiguredInjectionTarget: Bool {
        self == .hotkey || self == .menuBar
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let appState = AppState()
    let appUpdater = AppUpdater()
    let permissionGuideModel = PermissionGuideModel()
    let navigationModel = AppNavigationModel()
    /// Computed dynamically per recording based on audio device topology.
    private var floatingBarController: FloatingBarController?
    let askAnythingStore = AskAnythingStore()
    lazy var askAnythingCoordinator = AskAnythingCoordinator(store: askAnythingStore)
    private var selectionAskController: SelectionAskController?
    private lazy var recordingControlCoordinator = RecordingControlCoordinator(
        onFollowUpAction: { [weak self] action in
            self?.selectionAskController?.handleActiveRecordingAction(action) == true
        }
    ) { [weak self] action in
        self?.performStandardRecordingAction(action, capturesManualEndTarget: true)
    }
    private let hotkeyManager = HotkeyManager()
    private let session = RecognitionSession()
    private var selectionAskFollowUpStartGate = SelectionAskFollowUpStartGate()
    private var recordingStartGate = RecordingStartGate()
    /// Set when the app is launched/activated by a headless URL recording command,
    /// so the first-run setup wizard is not force-presented over a background
    /// recording the user triggered via Stream Deck / Shortcuts / etc.
    private var suppressSetupWizardForHeadlessLaunch = false
    private var recognitionEventTask: Task<Void, Never>?
    private var recognitionEventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var inputDeviceChangeObservers: [NSObjectProtocol] = []
    private var preciseTargetActivationObserver: NSObjectProtocol?
    /// Frozen with the current manual recording so changing Settings mid-session
    /// cannot change which stop behavior the hotkey uses.
    private var activeInjectionTargetPreference: InjectionTargetPreference = .recordingStart
    private var effectiveInputDevice: AudioInputDevice?
    private var hasEstablishedInputDeviceBaseline = false
    lazy var menuBarControlCenterModel = MenuBarControlCenterModel(appState: appState)
    lazy var menuBarActionCoordinator = MenuBarActionCoordinator(
        appDelegate: self,
        model: menuBarControlCenterModel
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[Type4Me] applicationDidFinishLaunching")
        // Restore system volume if previous session crashed while volume was lowered
        SystemVolumeManager.restoreIfNeeded()
        #if HAS_CLOUD_SUBSCRIPTION
        AppEditionMigration.migrateIfNeeded()
        Task { await RegionDetector.detect() }
        #endif
        // Show or hide Dock icon based on user preference
        let showDock = UserDefaults.standard.object(forKey: "tf_showDockIcon") as? Bool ?? true
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        KeychainService.migrateIfNeeded()
        HotwordStorage.migrateIfNeeded()
        SnippetStorage.migrateIfNeeded()
        AudioInputDevicePreferenceStore.migrateIfNeeded()
        CJKSpacingMode.migrateIfNeeded()
        ClipboardOutputPolicy.migrateIfNeeded()
        RecordingVisualStyle.migrateLegacyPreferenceIfNeeded()

        // Sync hotwords to Volcengine cloud table (async, non-blocking)
        VolcHotwordSyncManager.syncIfNeeded()

        // Deploy bundled models (local variant) before anything touches model paths
        ModelManager.deployBundledModelsIfNeeded()

        DebugFileLogger.startSession()
        DebugFileLogger.log("applicationDidFinishLaunching")
        floatingBarController = FloatingBarController(state: appState)
        appState.onRecordingControlAction = { [weak self] action in
            self?.recordingControlCoordinator.perform(action)
        }

        // Bridge ASR events → AppState for floating bar display
        let session = self.session

        // 历史记录字数迁移（用 session 自带的 historyStore，迁移后 UI 能刷新）
        Task { await session.historyStore.migrateCharacterCounts() }
        Task { await askAnythingCoordinator.restoreAfterLaunch() }
        let appState = self.appState

        SoundFeedback.warmUp()
        AudioInputDeviceMonitor.shared.start()
        observeEffectiveInputDeviceChanges()
        observePreciseTargetApplicationActivation()
        AudioKeepAliveManager.syncState()

        // Pre-warm audio subsystem and ASR connection so the first recording starts instantly
        Task { await session.warmUp() }
        session.warmUpASRConnection()

        // Bridge audio level → isolated meter (no SwiftUI observation overhead)
        Task {
            await session.setOnAudioLevel { level in
                appState.audioLevel.current = level
            }
        }

        let (recognitionEvents, recognitionEventContinuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.recognitionEventContinuation = recognitionEventContinuation
        Task {
            await session.setOnASREvent { event in
                recognitionEventContinuation.yield(event)
            }
        }
        recognitionEventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in recognitionEvents {
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
                                let delayMs = SoundFeedback.startSoundDurationMs()
                                if delayMs > 0 {
                                    try? await Task.sleep(for: .milliseconds(delayMs))
                                }
                                guard appState.barPhase == .recording else { return }
                                SystemVolumeManager.lower(to: Float(targetVolumePercent) / 100.0)
                            }
                        }
                    case .transcript(let transcript):
                        appState.setLiveTranscript(transcript)
                    case .completed:
                        self.selectionAskController?.recordingDidEnd(.finish)
                        appState.stopRecording()
                        if await session.stoppedByMaxDuration {
                            appState.processingLabelOverride = L("已达最大时长", "Max duration reached")
                        }
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .processingLabelOverride(let label):
                        appState.processingLabelOverride = label
                    case .processingResult(let text):
                        appState.showProcessingResult(text)
                        self.hotkeyManager.isProcessing = true
                    case .recoveryStarted(let text, let message):
                        appState.showRecovery(text: text, message: message)
                        self.hotkeyManager.isProcessing = false
                        self.hotkeyManager.resetActiveState()
                    case .recoveryPrompt(let text, let message):
                        appState.showRecoveryPrompt(text: text, message: message)
                        self.hotkeyManager.isProcessing = false
                        self.hotkeyManager.resetActiveState()
                    case .recoverySucceeded(let text, let message):
                        appState.showRecoveryResult(text: text, message: message)
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .recoveryFailed(let text, let message):
                        appState.showRecoveryResult(text: text, message: message)
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .recoveryInterrupted(let text, let message):
                        if appState.barPhase == .recovering {
                            appState.showRecoveryResult(text: text, message: message)
                        }
                        self.hotkeyManager.isProcessing = false
                        self.hotkeyManager.resetActiveState()
                    case .finalized(let text, let injection):
                        appState.finalize(text: text, outcome: injection)
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .macActionResult(let message, let status):
                        appState.showMacActionResult(message: message, status: status)
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .selectionAskStarted(
                        let requestID,
                        let question,
                        let selectedText,
                        let contextWasTruncated
                    ):
                        appState.cancel()
                        self.ensureSelectionAskController().begin(
                            requestID: requestID,
                            question: question,
                            selectedText: selectedText,
                            contextWasTruncated: contextWasTruncated
                        )
                        self.hotkeyManager.isProcessing = true
                    case .selectionAskAnswerDelta(let requestID, let delta):
                        self.selectionAskController?.appendAnswerDelta(requestID: requestID, delta: delta)
                    case .selectionAskAnswerCompleted(let requestID):
                        self.selectionAskController?.completeAnswer(requestID: requestID)
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .selectionAskAnswerFailed(let requestID, let message):
                        self.selectionAskController?.showError(requestID: requestID, message: message)
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .reviseProcessing:
                        appState.showReviseProcessing()
                        self.hotkeyManager.isProcessing = true
                    case .reviseCompleted(let text, let message, let undoTicketID):
                        appState.finalizeRevise(text: text, message: message, undoTicketID: undoTicketID)
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .reviseFailed(let failure):
                        appState.showReviseError(failure)
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .reviseCancelled:
                        appState.cancel()
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .reviseUndone(let text):
                        appState.showReviseUndone(text: text)
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .error(let error):
                        appState.showError(self.userFacingMessage(for: error))
                        self.selectionAskController?.recordingDidEnd(.cancel)
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    }
            }
        }

        appState.onReviseUndo = { [weak self] ticketID in
            Task {
                let result = await ReviseCoordinator.shared.undo(ticketID: ticketID)
                await MainActor.run {
                    switch result {
                    case .success(let restoredText):
                        self?.appState.showReviseUndone(text: restoredText)
                    case .failure(let err):
                        self?.appState.showReviseError(err)
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
            forName: .reviseSettingsDidChange,
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
        #if HAS_CLOUD_SUBSCRIPTION
        let needsSetup = !appState.hasCompletedSetup || appState.appEdition == nil
        #else
        let needsSetup = !appState.hasCompletedSetup
        #endif
        // Only auto-present the first-run setup wizard on a normal, foreground
        // launch. A `type4me://` URL command may cold-launch the app; in that case
        // `application(open:)` sets `suppressSetupWizardForHeadlessLaunch` so the
        // wizard doesn't steal focus over the headless recording.
        if needsSetup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated {
                    if self?.suppressSetupWizardForHeadlessLaunch == true {
                        DebugFileLogger.log("setup wizard suppressed: headless URL launch")
                        return
                    }
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

        // UI iteration can open Settings directly without depending on the menu bar
        // status item's visibility. This launch argument is Debug-only and has no
        // effect on normal or release launches.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--open-settings") {
            NSApp.setActivationPolicy(.regular)
            presentSettingsWhenReady(remainingAttempts: 20)
        } else {
            checkMenuBarVisibility()
        }
        #else
        // Check if menu bar icon is hidden by macOS 26+ "Allow in Menu Bar" setting
        checkMenuBarVisibility()
        #endif

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
        updateSelectionAskShortcutHint()
        registerHotkeys(for: provider)
    }

    // MARK: - Actual input device notification

    /// The configured microphone policy and the actual device can differ: a
    /// priority device may be unavailable, while Follow System delegates to
    /// CoreAudio's default input. Notify only when that effective device moves.
    private func observeEffectiveInputDeviceChanges() {
        updateEffectiveInputDevice(notify: false)
        inputDeviceChangeObservers = [
            .audioInputDevicesDidChange,
            .audioInputDevicePreferenceDidChange,
        ].map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateEffectiveInputDevice(notify: true)
                }
            }
        }
    }

    private func updateEffectiveInputDevice(notify: Bool) {
        let current = AudioInputDevicePreferenceStore.activeCachedInputDevice()
        guard hasEstablishedInputDeviceBaseline else {
            effectiveInputDevice = current
            hasEstablishedInputDeviceBaseline = true
            return
        }
        guard current?.uid != effectiveInputDevice?.uid else { return }

        let previous = effectiveInputDevice
        effectiveInputDevice = current
        DebugFileLogger.log(
            "audio input changed effective=\(previous?.uid ?? "none") → \(current?.uid ?? "none")"
        )
        guard notify else { return }

        let message: String
        if let current {
            message = L(
                "输入设备已切换至 \(current.name)",
                "Input device switched to \(current.name)"
            )
        } else {
            message = L("未找到可用输入设备", "No input device available")
        }
        appState.showTransientNotification(message)
    }

    // MARK: - Menu bar control center

    /// Runtime settings which affect the next recording are deliberately
    /// locked while a recording is being prepared or captured. The controls
    /// are available again during processing because that session has already
    /// frozen its own context.
    var menuBarRuntimeSettingsAreEditable: Bool {
        switch appState.barPhase {
        case .preparing, .recording:
            return false
        case .hidden, .processing, .recovering, .done, .error:
            return true
        }
    }

    func requestMenuBarRecordingStart(modeID: UUID) {
        guard let mode = appState.availableModes.first(where: { $0.id == modeID }) else {
            return
        }
        requestRecordingStart(mode: mode, source: .menuBar)
    }

    func requestMenuBarRecordingControl(_ action: RecordingControlAction) {
        recordingControlCoordinator.perform(action)
    }

    func requestMenuBarReviseStart() {
        requestReviseRecordingStart(source: .reviseMenuBar)
    }

    func selectASRProviderFromMenu(_ provider: ASRProvider) {
        guard menuBarRuntimeSettingsAreEditable,
              ASRProviderRegistry.capabilities(for: provider).isAvailable
        else { return }

        if !provider.isLocal,
           KeychainService.loadASRConfig(for: provider)?.isValid != true {
            return
        }

        let previousProvider = KeychainService.selectedASRProvider
        guard provider != previousProvider else { return }

        KeychainService.selectedASRProvider = provider

        if previousProvider == .sherpa, provider != .sherpa {
            Task {
                await SenseVoiceServerManager.shared.stopQwen3()
                #if HAS_SHERPA_ONNX
                SenseVoiceASRClient.releaseCachedModels()
                #endif
            }
        }

        if provider == .sherpa {
            let defaults = UserDefaults.standard
            let senseVoiceEnabled = defaults.object(forKey: "tf_sensevoiceEnabled") as? Bool ?? true
            let qwen3FinalEnabled = defaults.object(forKey: "tf_qwen3FinalEnabled") as? Bool ?? true
            if !senseVoiceEnabled && !qwen3FinalEnabled {
                defaults.set(true, forKey: "tf_qwen3FinalEnabled")
            }
            Task {
                do {
                    try await SenseVoiceServerManager.shared.start()
                } catch {
                    await MainActor.run {
                        self.appState.showError(
                            L("本地识别服务启动失败", "Failed to start local recognition service")
                        )
                    }
                }
            }
        }
    }

    func setTranslationTargetFromMenu(_ language: TranslationLanguage) {
        guard menuBarRuntimeSettingsAreEditable,
              let index = appState.availableModes.firstIndex(
                where: { $0.id == ProcessingMode.translationModeId }
              )
        else { return }

        var modes = appState.availableModes
        modes[index].translationTargetLanguageCode = language.rawValue
        persistModesFromMenu(modes)
    }

    func setCurrentModePunctuationFromMenu(_ punctuationMode: ModePunctuationMode) {
        guard menuBarRuntimeSettingsAreEditable,
              let index = appState.availableModes.firstIndex(
                where: { $0.id == appState.currentMode.id }
              )
        else { return }

        var modes = appState.availableModes
        modes[index].punctuationMode = punctuationMode
        persistModesFromMenu(modes)
    }

    private func persistModesFromMenu(_ modes: [ProcessingMode]) {
        do {
            try ModeStorage().save(modes)
            appState.availableModes = modes
            if let selected = modes.first(where: { $0.id == appState.currentMode.id }) {
                appState.currentMode = selected
            }
            NotificationCenter.default.post(name: .modesDidChange, object: nil)
            refreshModeAvailability()
        } catch {
            NSLog("[Type4Me] Failed to save menu bar mode setting: %@", String(describing: error))
            appState.showError(L("保存模式设置失败", "Failed to save mode settings"))
        }
    }

    private func requestRecordingStart(mode: ProcessingMode, source: RecordingStartSource) {
        switch appState.barPhase {
        case .hidden, .done, .error:
            break
        case .preparing, .recording, .processing, .recovering:
            DebugFileLogger.log("\(source.rawValue) record start blocked phase=\(appState.barPhase)")
            return
        }

        let selectedProvider = KeychainService.selectedASRProvider
        let resolvedMode = ASRProviderRegistry.resolvedMode(for: mode, provider: selectedProvider)
        let effectiveMode = appState.availableModes.first(where: { $0.id == resolvedMode.id }) ?? resolvedMode
        let injectionTargetPreference = freezeInjectionTargetPreference(
            for: source,
            mode: effectiveMode
        )
        if effectiveMode.executionKind == .selectionAsk {
            askAnythingCoordinator.prepareForExternalNewQuestion()
        }

        let startToken = recordingStartGate.begin()
        let recordingRequestedAt = ContinuousClock.now
        NSLog("[Type4Me] >>> %@: Record START (mode: %@)", source.rawValue, effectiveMode.name)
        DebugFileLogger.log("\(source.rawValue) record start mode=\(effectiveMode.name)")
        appState.selectModeForRecording(effectiveMode)
        appState.startRecording()

        Task {
            // Keep the existing session as the only recording owner and wait
            // for its previous teardown before starting a new capture.
            let ready = await self.session.awaitIdle()
            if !ready {
                NSLog("[Type4Me] >>> %@: previous session did not reach idle in time", source.rawValue)
                DebugFileLogger.log("\(source.rawValue) start: awaitIdle timed out")
            }
            let canStart = await MainActor.run {
                self.recordingStartGate.allowsStart(token: startToken)
            }
            guard canStart else {
                NSLog("[Type4Me] >>> %@: start aborted by start gate token invalidation", source.rawValue)
                DebugFileLogger.log("\(source.rawValue) start aborted by start gate token invalidation")
                return
            }
            await self.session.startRecording(
                mode: effectiveMode,
                requestedAt: recordingRequestedAt,
                injectionTargetPreference: injectionTargetPreference
            )
        }
    }

    private func injectionTargetPreference(
        for source: RecordingStartSource,
        mode: ProcessingMode
    ) -> InjectionTargetPreference {
        guard source.allowsConfiguredInjectionTarget, mode.supportsOutputFormatting else {
            return .recordingStart
        }
        return InjectionTargetPreference.current()
    }

    private func freezeInjectionTargetPreference(
        for source: RecordingStartSource,
        mode: ProcessingMode
    ) -> InjectionTargetPreference {
        let preference = injectionTargetPreference(for: source, mode: mode)
        activeInjectionTargetPreference = preference
        if preference == .recordingEnd,
           let frontmostApp = NSWorkspace.shared.frontmostApplication {
            TextInjectionEngine.preparePreciseTargetCapture(for: frontmostApp)
        }
        return preference
    }

    private func observePreciseTargetApplicationActivation() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        preciseTargetActivationObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      self.activeInjectionTargetPreference == .recordingEnd,
                      self.appState.barPhase == .preparing || self.appState.barPhase == .recording,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication
                else { return }
                TextInjectionEngine.preparePreciseTargetCapture(for: app)
            }
        }
    }

    private var shouldCapturePreciseEndTarget: Bool {
        activeInjectionTargetPreference == .recordingEnd
    }

    private func requestReviseRecordingStart(source: RecordingStartSource) {
        guard menuBarRuntimeSettingsAreEditable else {
            DebugFileLogger.log("\(source.rawValue) revise start blocked phase=\(appState.barPhase)")
            return
        }

        let startToken = recordingStartGate.begin()
        DebugFileLogger.log("\(source.rawValue) revise start")
        Task {
            let prepResult = await ReviseCoordinator.shared.prepareForRecording()
            let canStart = await MainActor.run {
                self.recordingStartGate.allowsStart(token: startToken)
            }
            guard canStart else {
                if case .success(let prepared) = prepResult {
                    await ReviseCoordinator.shared.cancel(transactionID: prepared.transactionID)
                }
                return
            }

            switch prepResult {
            case .success(let prepared):
                await MainActor.run {
                    self.appState.startReviseRecording()
                }
                await self.session.startReviseRecording(prepared)
            case .failure(let failure):
                await MainActor.run {
                    SoundFeedback.playError()
                    self.appState.showReviseError(failure)
                    self.hotkeyManager.resetActiveState()
                }
            }
        }
    }

    private func updateSelectionAskShortcutHint() {
        let hint = appState.availableModes
            .first(where: { $0.id == ProcessingMode.selectionAskId })?
            .hotkeyBindings
            .map { HotkeyRecorderView.keyDisplayName(keyCode: $0.keyCode, modifiers: $0.modifiers) }
            .joined(separator: " / ") ?? ""
        askAnythingCoordinator.updateFollowUpShortcutHint(hint)
    }

    @discardableResult
    private func ensureSelectionAskController() -> SelectionAskController {
        if let selectionAskController { return selectionAskController }
        let controller = SelectionAskController(
            coordinator: askAnythingCoordinator,
            onStartFollowUp: { [weak self] requestContext in
                self?.startSelectionAskFollowUp(requestContext: requestContext) ?? false
            },
            onStartNewQuestion: { [weak self] requestContext in
                self?.startSelectionAskFollowUp(requestContext: requestContext) ?? false
            },
            onFinishFollowUp: { [weak self] in
                self?.finishSelectionAskFollowUp()
            },
            onCancelFollowUp: { [weak self] in
                self?.cancelSelectionAskFollowUp()
            },
            onOpenInType4Me: { [weak self] sessionID in
                self?.presentAskAnything(sessionID: sessionID)
            },
            onBecameReleasable: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.releaseSelectionAskControllerIfPossible()
                }
            }
        )
        selectionAskController = controller
        return controller
    }

    private func releaseSelectionAskControllerIfPossible() {
        guard selectionAskController?.isReleasable == true else { return }
        selectionAskController?.releasePanelResources()
        selectionAskController = nil
        Task { await askAnythingStore.shrinkMemory() }
    }

    private func registerHotkeys(for provider: ASRProvider) {
        let availableModes = appState.availableModes
        let modes = ASRProviderRegistry.supportedModes(from: availableModes, for: provider)
        var bindings: [ModeBinding] = modes.flatMap { mode -> [ModeBinding] in
            let capturedMode = mode
            let onStart: @Sendable () -> Void = { [weak self] in
                guard let self else { return }

                if capturedMode.executionKind == .selectionAsk,
                   MainActor.assumeIsolated({ self.selectionAskController?.isVisible == true }) {
                    let wasRecording = MainActor.assumeIsolated {
                        self.selectionAskController?.isRecordingFollowUp == true
                    }
                    let handled = MainActor.assumeIsolated {
                        self.selectionAskController?.performPrimaryFollowUpAction() == true
                    }
                    if !handled || wasRecording {
                        MainActor.assumeIsolated { self.hotkeyManager.resetActiveState() }
                    }
                    return
                }

                if capturedMode.executionKind == .selectionAsk,
                   MainActor.assumeIsolated({
                       NSApp.isActive && self.navigationModel.selectedTab == .askAnything
                   }) {
                    let handled = MainActor.assumeIsolated {
                        if self.askAnythingCoordinator.hasActiveConversation {
                            return self.askAnythingCoordinator.performPrimaryFollowUpAction()
                        }
                        return self.askAnythingCoordinator.startNewQuestionRecording()
                    }
                    if !handled {
                        MainActor.assumeIsolated { self.hotkeyManager.resetActiveState() }
                    }
                    return
                }

                let phase = MainActor.assumeIsolated { self.appState.barPhase }

                // Safety: if already recording, the toggle state is out of sync.
                // Redirect to stop so we don't discard accumulated text.
                if phase == .recording || phase == .preparing {
                    NSLog("[Type4Me] >>> HOTKEY: toggle desync – onStart while recording, redirecting to STOP (phase=%@)", String(describing: phase))
                    DebugFileLogger.log("hotkey toggle desync: onStart while recording, redirecting to stop phase=\(phase)")
                    let capturesPreciseTarget = MainActor.assumeIsolated {
                        self.shouldCapturePreciseEndTarget
                    }
                    let confirmedEndTarget = phase == .recording && capturesPreciseTarget
                        ? TextInjectionEngine.captureConfirmedInjectionTarget()
                        : nil
                    MainActor.assumeIsolated {
                        if phase == .preparing {
                            self.recordingStartGate.invalidate()
                            self.selectionAskFollowUpStartGate.invalidate()
                        }
                        self.hotkeyManager.resetActiveState()
                        self.appState.stopRecording()
                    }
                    if phase == .preparing {
                        Task { await self.session.cancelRecording() }
                    } else {
                        Task {
                            await self.session.stopRecording(
                                confirmedEndTarget: confirmedEndTarget
                            )
                        }
                    }
                    return
                }

                if phase == .recovering {
                    NSLog("[Type4Me] >>> HOTKEY: recovery press")
                    DebugFileLogger.log("hotkey recovery press")
                    MainActor.assumeIsolated { self.hotkeyManager.resetActiveState() }
                    let selectedProvider = KeychainService.selectedASRProvider
                    let resolvedMode = ASRProviderRegistry.resolvedMode(for: capturedMode, provider: selectedProvider)
                    let effectiveMode = availableModes.first(where: { $0.id == resolvedMode.id }) ?? resolvedMode
                    Task {
                        let action = await self.session.handleRecoveryHotkeyPress()
                        guard action == .interrupted else { return }
                        let injectionTargetPreference = await MainActor.run {
                            self.appState.selectModeForRecording(effectiveMode)
                            self.appState.startRecording()
                            return self.freezeInjectionTargetPreference(
                                for: .hotkey,
                                mode: effectiveMode
                            )
                        }
                        await self.session.startRecording(
                            mode: effectiveMode,
                            injectionTargetPreference: injectionTargetPreference
                        )
                    }
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

                MainActor.assumeIsolated {
                    self.requestRecordingStart(mode: capturedMode, source: .hotkey)
                }
            }
            let onStop: @Sendable () -> Void = { [weak self] in
                guard let self else { return }

                if capturedMode.executionKind == .selectionAsk,
                   MainActor.assumeIsolated({ self.askAnythingCoordinator.isRecordingFollowUp }) {
                    _ = MainActor.assumeIsolated {
                        self.selectionAskController?.handleActiveRecordingAction(.finish)
                    }
                    return
                }

                let phase = MainActor.assumeIsolated { self.appState.barPhase }
                NSLog("[Type4Me] >>> HOTKEY: Record STOP (phase=%@)", String(describing: phase))
                DebugFileLogger.log("hotkey record stop phase=\(phase)")
                if phase == .recovering {
                    MainActor.assumeIsolated { self.hotkeyManager.resetActiveState() }
                    Task { _ = await self.session.handleRecoveryHotkeyPress() }
                    return
                }
                let capturesPreciseTarget = MainActor.assumeIsolated {
                    self.shouldCapturePreciseEndTarget
                }
                let confirmedEndTarget = phase == .recording && capturesPreciseTarget
                    ? TextInjectionEngine.captureConfirmedInjectionTarget()
                    : nil
                MainActor.assumeIsolated {
                    if phase == .preparing {
                        self.recordingStartGate.invalidate()
                        self.selectionAskFollowUpStartGate.invalidate()
                    }
                    self.appState.stopRecording()
                }
                if phase == .preparing {
                    Task { await self.session.cancelRecording() }
                } else {
                    Task {
                        await self.session.stopRecording(
                            confirmedEndTarget: confirmedEndTarget
                        )
                    }
                }
            }
            let onAbort: @Sendable () -> Void = { [weak self] in
                guard let self else { return }

                if capturedMode.executionKind == .selectionAsk {
                    let isAskVisible = MainActor.assumeIsolated { self.selectionAskController?.isVisible == true }
                    let isFollowUp = MainActor.assumeIsolated { self.selectionAskController?.isRecordingFollowUp == true }
                    if isAskVisible && isFollowUp {
                        _ = MainActor.assumeIsolated {
                            self.selectionAskController?.handleActiveRecordingAction(.cancel)
                        }
                        return
                    }

                    let isCoordinatorFollowUp = MainActor.assumeIsolated { self.askAnythingCoordinator.isRecordingFollowUp }
                    if isCoordinatorFollowUp {
                        _ = MainActor.assumeIsolated {
                            self.askAnythingCoordinator.cancelActiveFollowUp()
                        }
                        return
                    }
                }

                NSLog("[Type4Me] >>> HOTKEY: Record ABORT (full discard)")
                DebugFileLogger.log("hotkey record abort: full discard")

                MainActor.assumeIsolated {
                    self.recordingStartGate.invalidate()
                    self.selectionAskFollowUpStartGate.invalidate()
                    self.appState.cancel()
                }
                SoundFeedback.cancelActiveFeedback()
                Task {
                    await self.session.cancelRecording()
                }
            }

            // Fan out: one ModeBinding per hotkey binding, all sharing this mode's callbacks.
            return mode.hotkeyBindings.map { hk in
                ModeBinding(
                    bindingId: hk.id,
                    modeId: mode.id,
                    keyCode: CGKeyCode(hk.keyCode),
                    modifiers: CGEventFlags(rawValue: hk.modifiers ?? 0),
                    style: hk.style,
                    onStart: onStart,
                    onStop: onStop,
                    onAbort: onAbort
                )
            }
        }

        let reviseSettings = ReviseSettingsStore.shared.load()
        if reviseSettings.enabled && ReviseSettingsStore.isRuntimeEnabled,
           let hk = reviseSettings.hotkey {
            let reviseOnStart: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.requestReviseRecordingStart(source: .reviseHotkey)
                }
            }
            let reviseOnStop: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                let phase = MainActor.assumeIsolated { self.appState.barPhase }
                MainActor.assumeIsolated {
                    if phase == .preparing {
                        self.recordingStartGate.invalidate()
                        self.selectionAskFollowUpStartGate.invalidate()
                    }
                    self.appState.stopRecording()
                }
                if phase == .preparing {
                    Task { await self.session.cancelRecording() }
                } else {
                    Task { await self.session.stopRecording() }
                }
            }
            let reviseOnAbort: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                NSLog("[Type4Me] >>> HOTKEY: Revise ABORT (full discard)")
                DebugFileLogger.log("hotkey revise abort: full discard")

                MainActor.assumeIsolated {
                    self.recordingStartGate.invalidate()
                    self.appState.cancel()
                }
                SoundFeedback.cancelActiveFeedback()
                Task {
                    await ReviseCoordinator.shared.cancelActiveTransaction()
                    await self.session.cancelRecording()
                }
            }
            let reviseBinding = ModeBinding(
                bindingId: hk.id,
                owner: .globalAction(.revise),
                keyCode: CGKeyCode(hk.keyCode),
                modifiers: CGEventFlags(rawValue: hk.modifiers ?? 0),
                style: hk.style,
                onStart: reviseOnStart,
                onStop: reviseOnStop,
                onAbort: reviseOnAbort,
                onBusyConflict: { [weak self] in
                    Task { @MainActor [weak self] in
                        SoundFeedback.playError()
                        self?.appState.showError(L("请先完成当前操作", "Please finish current operation"))
                    }
                }
            )
            bindings.append(reviseBinding)
        }

        hotkeyManager.registerBindings(bindings)

        // Cross-mode finish: user pressed mode B's key while mode A was recording.
        // The preference decides whether mode A or mode B processes the recording.
        hotkeyManager.onCrossModeFinish = { [weak self] newModeId in
            guard let self else { return }
            guard let newMode = availableModes.first(where: { $0.id == newModeId }) else { return }
            let phase = MainActor.assumeIsolated { self.appState.barPhase }
            if phase == .recovering {
                MainActor.assumeIsolated { self.hotkeyManager.resetActiveState() }
                Task { _ = await self.session.handleRecoveryHotkeyPress() }
                return
            }
            let startingMode = MainActor.assumeIsolated { self.appState.currentMode }
            let allowsModeSwitch = CrossModeFinishPreference.isEnabled()
            let endingMode: ProcessingMode
            if allowsModeSwitch {
                let selectedProvider = KeychainService.selectedASRProvider
                let resolvedMode = ASRProviderRegistry.resolvedMode(for: newMode, provider: selectedProvider)
                endingMode = availableModes.first(where: { $0.id == resolvedMode.id }) ?? resolvedMode
            } else {
                // Avoid provider resolution entirely when the starting mode must be retained.
                endingMode = newMode
            }
            let processingMode = CrossModeFinishPreference.processingMode(
                startingMode: startingMode,
                endingMode: endingMode,
                isEnabled: allowsModeSwitch
            )
            NSLog(
                "[Type4Me] >>> HOTKEY: Cross-mode finish (start=%@, end=%@, process=%@)",
                startingMode.name,
                newMode.name,
                processingMode.name
            )
            DebugFileLogger.log(
                "hotkey cross-mode finish start=\(startingMode.name) end=\(newMode.name) process=\(processingMode.name)"
            )
            let capturesPreciseTarget = MainActor.assumeIsolated {
                self.shouldCapturePreciseEndTarget
            }
            let confirmedEndTarget = capturesPreciseTarget
                ? TextInjectionEngine.captureConfirmedInjectionTarget()
                : nil
            MainActor.assumeIsolated {
                if allowsModeSwitch {
                    self.appState.currentMode = processingMode
                }
                self.appState.stopRecording()
            }
            Task {
                if allowsModeSwitch {
                    await self.session.switchMode(to: processingMode)
                }
                await self.session.stopRecording(
                    confirmedEndTarget: confirmedEndTarget
                )
            }
        }

        // ESC abort: skip injection but let recognition/clipboard/history proceed.
        // Returns true if the abort was actually handled (ESC should be swallowed).
        hotkeyManager.onESCAbort = { [weak self] in
            guard let self else { return false }
            if MainActor.assumeIsolated({
                self.askAnythingCoordinator.isRecordingFollowUp
            }) {
                return MainActor.assumeIsolated {
                    self.selectionAskController?.handleActiveRecordingAction(.cancel) == true
                }
            }
            let phase = appState.barPhase
            guard phase == .recording || phase == .processing || phase == .preparing else {
                return false  // Not in an active session, let ESC pass through
            }
            NSLog("[Type4Me] >>> HOTKEY: ESC abort injection (phase=%@)", String(describing: phase))
            DebugFileLogger.log("hotkey ESC abort injection phase=\(phase)")
            if phase == .preparing {
                MainActor.assumeIsolated {
                    self.recordingStartGate.invalidate()
                    self.selectionAskFollowUpStartGate.invalidate()
                    self.appState.stopRecording()
                }
                Task { await self.session.cancelRecording() }
            } else {
                Task {
                    let suppressProcessingUI = await self.session.cancellationHidesProcessingUI()
                    await MainActor.run {
                        self.appState.stopRecording(
                            suppressProcessingUI: suppressProcessingUI
                        )
                    }
                    await self.session.abortInjection()
                    await self.session.stopRecording()
                }
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

    private func startSelectionAskFollowUp(requestContext: SelectionAskRequestContext) -> Bool {
        let phase = appState.barPhase
        guard phase != .processing else {
            DebugFileLogger.log("selectionAsk follow-up blocked: still processing")
            return false
        }
        guard phase != .recording, phase != .preparing else {
            DebugFileLogger.log("selectionAsk follow-up blocked: another recording is active")
            return false
        }

        let selectedProvider = KeychainService.selectedASRProvider
        let availableModes = appState.availableModes
        let resolvedMode = ASRProviderRegistry.resolvedMode(for: .selectionAsk, provider: selectedProvider)
        let effectiveMode = availableModes.first(where: { $0.id == resolvedMode.id }) ?? resolvedMode

        let recordingRequestedAt = ContinuousClock.now
        DebugFileLogger.log("selectionAsk follow-up start")
        let generation = selectionAskFollowUpStartGate.begin()
        appState.selectModeForRecording(effectiveMode)
        appState.startRecording()
        Task {
            let ready = await self.session.awaitIdle()
            if !ready {
                DebugFileLogger.log("selectionAsk follow-up start: awaitIdle timed out")
            }
            let shouldStart = await MainActor.run {
                self.selectionAskFollowUpStartGate.allowsStart(
                    token: generation,
                    isFollowUpActive: self.askAnythingCoordinator.isRecordingFollowUp,
                    phase: self.appState.barPhase
                )
            }
            guard shouldStart else {
                DebugFileLogger.log("selectionAsk follow-up start: cancelled before session start")
                return
            }
            await self.session.setSelectionAskRequestContext(requestContext)
            await self.session.startRecording(
                mode: effectiveMode,
                requestedAt: recordingRequestedAt,
                injectionTargetPreference: .recordingStart
            )
        }
        return true
    }

    private func finishSelectionAskFollowUp() {
        let phase = appState.barPhase
        DebugFileLogger.log("selectionAsk follow-up finish phase=\(phase)")
        selectionAskFollowUpStartGate.invalidate()
        hotkeyManager.resetActiveState()

        switch phase {
        case .recording:
            appState.stopRecording()
            Task { await self.session.stopRecording() }
        case .preparing:
            // No ASR session is ready to finalize yet, so there is no usable
            // question to process. Tear down the pending start deterministically.
            appState.cancel()
            Task { await self.session.cancelRecording() }
        case .processing, .recovering, .done, .error, .hidden:
            break
        }
    }

    private func cancelSelectionAskFollowUp() {
        let phase = appState.barPhase
        DebugFileLogger.log("selectionAsk follow-up cancel phase=\(phase)")
        selectionAskFollowUpStartGate.invalidate()
        appState.cancel()
        hotkeyManager.resetActiveState()
        Task { await self.session.cancelRecording() }
    }

    private func performStandardRecordingAction(
        _ action: RecordingControlAction,
        capturesManualEndTarget: Bool
    ) {
        let phase = appState.barPhase
        guard phase == .preparing || phase == .recording else { return }

        DebugFileLogger.log("floating indicator: \(action) recording phase=\(phase)")
        hotkeyManager.resetActiveState()

        switch action {
        case .finish:
            if phase == .preparing {
                recordingStartGate.invalidate()
                selectionAskFollowUpStartGate.invalidate()
                appState.stopRecording()
                Task { await session.cancelRecording() }
            } else {
                let confirmedEndTarget = capturesManualEndTarget && shouldCapturePreciseEndTarget
                    ? TextInjectionEngine.captureConfirmedInjectionTarget()
                    : nil
                appState.stopRecording()
                Task {
                    await session.stopRecording(
                        confirmedEndTarget: confirmedEndTarget
                    )
                }
            }
        case .cancel:
            if phase == .preparing {
                recordingStartGate.invalidate()
                selectionAskFollowUpStartGate.invalidate()
                appState.stopRecording()
                Task { await session.cancelRecording() }
            } else {
                Task {
                    let suppressProcessingUI = await session.cancellationHidesProcessingUI()
                    await MainActor.run {
                        appState.stopRecording(suppressProcessingUI: suppressProcessingUI)
                    }
                    await session.abortInjection()
                    await session.stopRecording()
                }
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

        // Surface the unified permission guide. Skip on first launch when
        // the setup wizard will walk the user through permissions inline —
        // otherwise we'd stack the guide on top of the wizard.
        let showWizard: Bool = {
            #if HAS_CLOUD_SUBSCRIPTION
            return !appState.hasCompletedSetup || appState.appEdition == nil
            #else
            return !appState.hasCompletedSetup
            #endif
        }()
        if !showWizard {
            presentPermissionGuide()
        }

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
        alert.messageText = L("辅助功能权限已开启，但快捷键未生效", "Accessibility is enabled, but the hotkey is not working")
        alert.informativeText = L(
            "macOS 有时需要重启应用才能激活全局快捷键。点击「重启」自动重启 Type4Me。",
            "macOS sometimes requires an app restart before global hotkeys take effect. Click Restart to relaunch Type4Me."
        )
        alert.addButton(withTitle: L("重启", "Restart"))
        alert.addButton(withTitle: L("稍后", "Later"))
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
        // `UserDefaults.didChangeNotification` is delivered on whatever thread
        // performed the change. When another process (e.g. System Settings /
        // tccd while the user grants a permission) triggers a cross-process
        // preferences sync, this fires on a background thread. Touching NSApp
        // off the main thread is unsafe and crashes the app, so always hop to
        // main before reading/mutating the activation policy.
        if Thread.isMainThread {
            Self.applyDockIconPreference()
        } else {
            DispatchQueue.main.async { Self.applyDockIconPreference() }
        }
    }

    private static func applyDockIconPreference() {
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

    /// Stored by MenuBarContent so AppDelegate can open the unified
    /// permission guide window from anywhere (startup, hotkey failure path,
    /// etc.). If the action isn't wired yet (e.g. very early in launch
    /// before the first MenuBarExtra render), calls are retried on the next
    /// runloop.
    static var openPermissionGuideAction: (() -> Void)?

    /// Present the permission guide window, activating the app and retrying
    /// until the SwiftUI scene registers its open action.
    func presentPermissionGuide() {
        if let action = Self.openPermissionGuideAction {
            action()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.presentPermissionGuide()
        }
    }

    /// Present the settings window from anywhere (URL command, Dock reopen,
    /// etc.). Uses the standard SwiftUI settings-open selector so it works
    /// even before the MenuBarExtra scene has registered `openSettingsAction`,
    /// and retries on the next runloop until a window is visible.
    func presentSettings(remainingAttempts: Int = 25) {
        let hasVisibleAppWindow = NSApp.windows.contains {
            $0.isVisible
                && !$0.className.contains("NSStatusBar")
                && !($0 is NSPanel)
                && $0.styleMask.contains(.titled)
        }
        if hasVisibleAppWindow {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        Self.openSettingsAction?()
        NSApp.activate(ignoringOtherApps: true)
        guard remainingAttempts > 1 else {
            NSLog("[Type4Me] Timed out while opening Settings")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.presentSettings(remainingAttempts: remainingAttempts - 1)
        }
    }

    func presentAskAnything(sessionID: UUID?) {
        navigationModel.selectedTab = .askAnything
        navigationModel.pendingAskAnythingSessionID = sessionID
        askAnythingCoordinator.presentInMainWindow()
        selectionAskController?.hide()
        presentSettings()
    }

    #if DEBUG
    private func presentSettingsWhenReady(remainingAttempts: Int) {
        let hasVisibleAppWindow = NSApp.windows.contains {
            $0.isVisible
                && !$0.className.contains("NSStatusBar")
                && !($0 is NSPanel)
                && $0.styleMask.contains(.titled)
        }
        if hasVisibleAppWindow {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        if let action = Self.openSettingsAction {
            action()
        }
        guard remainingAttempts > 1 else {
            NSLog("[Type4Me] Timed out while opening Settings for UI preview")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.presentSettingsWhenReady(remainingAttempts: remainingAttempts - 1)
        }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        inputDeviceChangeObservers.forEach(NotificationCenter.default.removeObserver)
        inputDeviceChangeObservers.removeAll()
        if let preciseTargetActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(preciseTargetActivationObserver)
            self.preciseTargetActivationObserver = nil
        }
        recognitionEventContinuation?.finish()
        recognitionEventTask?.cancel()
        SystemVolumeManager.restore()
        // Synchronous kill: don't rely on async Task, app exits immediately after this returns
        SenseVoiceServerManager.killAllServerProcesses()
    }

    // MARK: - URL Scheme Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        let acceptedSchemes = Self.registeredURLSchemes()
        for url in urls {
            guard let scheme = url.scheme?.lowercased(), acceptedSchemes.contains(scheme) else {
                NSLog("[Type4Me] Ignored URL with unregistered scheme")
                continue
            }
            switch url.host?.lowercased() {
            case "start", "stop", "toggle":
                handleRecordingURL(url, acceptedSchemes: acceptedSchemes)
            case "vocabulary":
                handleVocabularyURL(url, acceptedSchemes: acceptedSchemes)
            case "reload-vocabulary":
                NSLog("[Type4Me] URL command: reload-vocabulary")
                SnippetStorage.invalidateCache()
                HotwordStorage.invalidateCache()
                NotificationCenter.default.post(name: SnippetStorage.didChangeNotification, object: nil)
                NotificationCenter.default.post(name: HotwordStorage.didChangeNotification, object: nil)
                SenseVoiceServerManager.syncHotwordsAndRestart()
            case "auth":
                NSLog("[Type4Me] URL command: auth (no-op, code-based auth now)")
            case "settings", "preferences":
                NSLog("[Type4Me] URL command: settings")
                presentSettings()
            default:
                NSLog("[Type4Me] Unknown URL command: \(url)")
            }
        }
    }

    private static func registeredURLSchemes(bundle: Bundle = .main) -> Set<String> {
        guard let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            return ["type4me"]
        }
        let schemes = types
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }
            .flatMap { $0 }
            .map { $0.lowercased() }
        return schemes.isEmpty ? ["type4me"] : Set(schemes)
    }

    private func handleRecordingURL(_ url: URL, acceptedSchemes: Set<String>) {
        switch RecordingURLCommandParser.parse(url, allowedSchemes: acceptedSchemes) {
        case .failure(let error):
            NSLog("[Type4Me] Recording URL rejected: \(String(describing: error))")
            DebugFileLogger.log("url recording command rejected: \(error)")
        case .success(let command):
            // This is a headless automation command; if it cold-launched the app,
            // do not force the first-run setup wizard over the recording.
            suppressSetupWizardForHeadlessLaunch = true
            handleRecordingURLCommand(command)
        }
    }

    func handleRecordingURLCommand(_ command: RecordingURLCommand) {
        let phase = appState.barPhase
        let decision = RecordingURLDecision.decide(for: command, phase: phase)
        NSLog("[Type4Me] URL command: %@ -> decision: %@", command.rawValue, String(describing: decision))
        switch decision {
        case .start:
            // Only a real start yields focus. no-op commands must not touch window
            // state, per the product spec ("safe no-op, do not steal focus").
            yieldFocusToPreviousApp()
            requestURLRecordingStart()
        case .finish:
            requestURLRecordingStop()
        case .ignore:
            DebugFileLogger.log("url \(command.rawValue) ignored phase=\(phase)")
        }
    }

    /// Hide Type4Me if a URL command activated it, so the previously focused app
    /// regains focus before recording (and later injection) begins. The deferred
    /// re-check covers activation that lands just after this handler runs.
    private func yieldFocusToPreviousApp() {
        if NSApp.isActive {
            NSApp.hide(nil)
        }
        DispatchQueue.main.async {
            if NSApp.isActive {
                NSApp.hide(nil)
            }
        }
    }

    private func requestURLRecordingStart() {
        requestRecordingStart(
            mode: appState.currentMode,
            source: .urlScheme
        )
    }

    private func requestURLRecordingStop() {
        performStandardRecordingAction(.finish, capturesManualEndTarget: false)
    }

    private func handleVocabularyURL(_ url: URL, acceptedSchemes: Set<String>) {
        switch VocabularyURLCommandParser.parse(url, allowedSchemes: acceptedSchemes) {
        case .failure(let error):
            NSLog("[Type4Me] Vocabulary URL rejected: \(String(describing: error))")
        case .success(let command):
            guard command.silent else {
                VocabularyNavigationCenter.shared.submit(command.navigationRequest)
                presentSettings()
                return
            }

            let result: VocabularyCommandResult
            switch command.section {
            case .hotwords:
                guard let word = command.word else { return }
                result = VocabularyCommandService.live.addHotword(word)
            case .snippets:
                guard let trigger = command.trigger, let replacement = command.replacement else { return }
                result = VocabularyCommandService.live.addSnippet(
                    trigger: trigger,
                    replacement: replacement
                )
            }
            NSLog("[Type4Me] Silent vocabulary URL result: \(String(describing: result))")
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
    var body: some View {
        MenuBarControlCenterView()
    }
}
