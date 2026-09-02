import AppKit
import Foundation
import Observation
import SwiftUI

/// A menu-specific choice. It intentionally does not replace the persisted
/// priority-list model used by audio capture and Settings.
enum MicrophoneChoice: Equatable {
    case systemDefault
    case device(AudioInputDevice)
}

/// The generic application-window entries in the menu bar. Specific
/// workspace actions (History, Vocabulary, and so on) own their destinations
/// separately.
enum MenuBarApplicationDestination: Equatable {
    case home
    case settings
    case models

    var settingsTab: SettingsTab {
        switch self {
        case .home: .general
        case .settings: .preferences
        case .models: .models
        }
    }
}

struct MenuBarASRProviderItem: Identifiable, Equatable {
    let provider: ASRProvider

    var id: String { provider.rawValue }
    var title: String {
        let isBatch = !ASRProviderRegistry.capabilities(for: provider).supportsRealtimeRecognition
        if isBatch {
            return "\(provider.displayName) (\(L("非实时", "Batch")))"
        }
        return provider.displayName
    }
}

enum MenuBarPermissionIssue: Equatable {
    case microphone
    case accessibility

    var title: String {
        switch self {
        case .microphone:
            return L("麦克风权限未开启", "Microphone permission is off")
        case .accessibility:
            return L("辅助功能权限未开启", "Accessibility permission is off")
        }
    }
}

/// Converts independently-owned runtime state into small, privacy-safe menu
/// values. It never stores dictated text or credential material.
@MainActor
@Observable
final class MenuBarControlCenterModel {
    private let appState: AppState
    private var observers: [NSObjectProtocol] = []
    private var historyRefreshTask: Task<Void, Never>?

    private(set) var inputDevices: [AudioInputDevice] = []
    private(set) var configuredASRProviders: [MenuBarASRProviderItem] = []
    private(set) var canCopyLatestResult = false
    private(set) var permissionIssue: MenuBarPermissionIssue?
    private(set) var canStartRevise = false
    private(set) var lastActionFeedback: String?

    /// System permission APIs do not broadcast a Type4Me-specific change
    /// event. Refresh whenever the application regains focus after Settings.
    static let refreshNotificationNames: [Notification.Name] = [
        .audioInputDevicesDidChange,
        .audioInputDevicePreferenceDidChange,
        .asrProviderDidChange,
        .modesDidChange,
        .historyStoreDidChange,
        .reviseSettingsDidChange,
        NSApplication.didBecomeActiveNotification,
    ]

    init(appState: AppState) {
        self.appState = appState
        observeChanges()
        refresh()
    }

    var selectedMicrophoneLabel: String {
        effectiveInputDevice?.name ?? L("跟随系统", "Follow System")
    }

    var systemDefaultInputDevice: AudioInputDevice? {
        AudioInputDeviceMonitor.shared.currentSnapshot().systemDefaultInput
    }

    var effectiveInputDevice: AudioInputDevice? {
        AudioInputDevicePreferenceStore.activeInputDevice(
            devices: inputDevices,
            systemDefault: systemDefaultInputDevice
        )
    }

    var selectedPriorityMicrophoneUID: String? {
        guard AudioInputDevicePreferenceStore.mode() == .priority else { return nil }
        return AudioInputDevicePreferenceStore.resolvedDevice(devices: inputDevices)?.uid
    }

    var selectedProviderLabel: String {
        let provider = KeychainService.selectedASRProvider
        let isBatch = !ASRProviderRegistry.capabilities(for: provider).supportsRealtimeRecognition
        if isBatch {
            return "\(provider.displayName) (\(L("非实时", "Batch")))"
        }
        return provider.displayName
    }

    var translationMode: ProcessingMode? {
        appState.availableModes.first(where: { $0.id == ProcessingMode.translationModeId })
    }

    var translationTarget: TranslationLanguage? {
        guard let translationMode else { return nil }
        let code = translationMode.translationTargetLanguageCode ?? TranslationLanguage.english.rawValue
        return TranslationLanguage(rawValue: code)
    }

    func refresh() {
        let cached = AudioInputDeviceMonitor.shared.currentDevices()
        inputDevices = cached.isEmpty
            ? AudioInputDeviceMonitor.shared.refreshSynchronously()
            : cached
        configuredASRProviders = MenuBarASRProviderAvailability.configuredItems()
        permissionIssue = Self.currentPermissionIssue()
        refreshHistoryAvailability()
        refreshReviseAvailability()
    }

    func showActionFeedback(_ message: String) {
        lastActionFeedback = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.lastActionFeedback = nil
        }
    }

    private func observeChanges() {
        observers = Self.refreshNotificationNames.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        }
    }

    private func refreshHistoryAvailability() {
        historyRefreshTask?.cancel()
        historyRefreshTask = Task { [weak self] in
            let latest = await HistoryStore.shared.latestCopyableFinalText()
            guard !Task.isCancelled else { return }
            self?.canCopyLatestResult = latest != nil
        }
    }

    private func refreshReviseAvailability() {
        Task { [weak self] in
            let isAvailable = await ReviseCoordinator.shared.hasAvailableTarget()
            guard !Task.isCancelled else { return }
            self?.canStartRevise = isAvailable
        }
    }

    private static func currentPermissionIssue() -> MenuBarPermissionIssue? {
        if !PermissionManager.hasMicrophonePermission { return .microphone }
        if !PermissionManager.hasAccessibilityPermission { return .accessibility }
        return nil
    }
}

enum MenuBarASRProviderAvailability {
    static func configuredItems() -> [MenuBarASRProviderItem] {
        ASRProvider.allCases.compactMap { provider in
            guard ASRProviderRegistry.capabilities(for: provider).isAvailable else {
                return nil
            }
            if provider.isLocal {
                return MenuBarASRProviderItem(provider: provider)
            }
            guard KeychainService.loadASRConfig(for: provider)?.isValid == true else {
                return nil
            }
            return MenuBarASRProviderItem(provider: provider)
        }
    }
}

/// Routes all menu side effects through AppDelegate's existing runtime
/// ownership. The menu itself therefore never starts a second Session or
/// writes a parallel preference store.
@MainActor
@Observable
final class MenuBarActionCoordinator {
    private unowned let appDelegate: AppDelegate
    private let model: MenuBarControlCenterModel

    init(appDelegate: AppDelegate, model: MenuBarControlCenterModel) {
        self.appDelegate = appDelegate
        self.model = model
    }

    func startRecording(modeID: UUID) {
        appDelegate.requestMenuBarRecordingStart(modeID: modeID)
    }

    func finishRecording() {
        appDelegate.requestMenuBarRecordingControl(.finish)
    }

    func cancelRecording() {
        appDelegate.requestMenuBarRecordingControl(.cancel)
    }

    func setMicrophone(_ choice: MicrophoneChoice) {
        guard appDelegate.menuBarRuntimeSettingsAreEditable else { return }
        switch choice {
        case .systemDefault:
            AudioInputDevicePreferenceStore.resetToSystemDefault()
        case .device(let device):
            AudioInputDevicePreferenceStore.savePriorityEntries([
                AudioInputDevicePreferenceEntry(uid: device.uid, name: device.name)
            ])
        }
        model.refresh()
    }

    func setASRProvider(_ provider: ASRProvider) {
        appDelegate.selectASRProviderFromMenu(provider)
        model.refresh()
    }

    func setTranslationTarget(_ language: TranslationLanguage) {
        appDelegate.setTranslationTargetFromMenu(language)
        model.refresh()
    }

    func setLiveTranscript(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: LiveTranscriptDisplayPreference.storageKey)
    }

    func setPunctuationMode(_ mode: ModePunctuationMode) {
        appDelegate.setCurrentModePunctuationFromMenu(mode)
        model.refresh()
    }

    func setCJKSpacing(_ mode: CJKSpacingMode) {
        guard appDelegate.menuBarRuntimeSettingsAreEditable else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: CJKSpacingMode.storageKey)
    }

    func setCornerQuotes(_ enabled: Bool) {
        guard appDelegate.menuBarRuntimeSettingsAreEditable else { return }
        UserDefaults.standard.set(enabled, forKey: CornerQuotePreference.storageKey)
    }

    func setClipboardOutputPolicy(_ policy: ClipboardOutputPolicy) {
        guard appDelegate.menuBarRuntimeSettingsAreEditable else { return }
        UserDefaults.standard.set(policy.rawValue, forKey: ClipboardOutputPolicy.storageKey)
    }

    func copyLatestResult() {
        Task { [weak self] in
            guard let text = await HistoryStore.shared.latestCopyableFinalText() else {
                await MainActor.run {
                    self?.model.refresh()
                }
                return
            }
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self?.model.showActionFeedback(L("已复制上一条结果", "Copied last result"))
            }
        }
    }

    func startRevise() {
        appDelegate.requestMenuBarReviseStart()
    }

    func undoLatestRevise() {
        appDelegate.appState.performReviseUndo()
    }

    func openAskAnything() {
        appDelegate.presentAskAnything(sessionID: nil)
    }

    func openVocabulary() {
        appDelegate.navigationModel.selectedTab = .vocabulary
        appDelegate.presentSettings()
    }

    func openHistory() {
        appDelegate.navigationModel.selectedTab = .history
        appDelegate.presentSettings()
    }

    func openModes() {
        appDelegate.navigationModel.selectedTab = .modes
        appDelegate.presentSettings()
    }

    /// The app-level entry point is deliberately deterministic: it always
    /// opens the Home overview instead of restoring whichever workspace was
    /// last visible in the window.
    func openType4Me() {
        openApplication(.home)
    }

    func openSettings() {
        openApplication(.settings)
    }

    func openModels() {
        openApplication(.models)
    }

    private func openApplication(_ destination: MenuBarApplicationDestination) {
        appDelegate.navigationModel.selectedTab = destination.settingsTab
        appDelegate.presentSettings()
    }

    func openPermissionGuide() {
        appDelegate.presentPermissionGuide()
    }

    func performUpdateAction() {
        let updater = appDelegate.appUpdater
        switch updater.state {
        case .idle:
            if let release = appDelegate.appState.availableUpdates.first {
                updater.downloadUpdate(release: release)
            }
        case .downloading:
            updater.cancelDownload()
        case .readyToInstall:
            updater.installAndRestart()
        case .failed:
            updater.retryDownload()
        case .verifying, .installing:
            break
        }
    }
}

struct MenuBarControlCenterView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppUpdater.self) private var appUpdater
    @Environment(MenuBarActionCoordinator.self) private var actions
    @Environment(MenuBarControlCenterModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(LiveTranscriptDisplayPreference.storageKey)
    private var liveTranscriptEnabled = LiveTranscriptDisplayPreference.defaultValue
    @AppStorage(ClipboardOutputPolicy.storageKey)
    private var clipboardOutputPolicyRaw = ClipboardOutputPolicy.defaultValue.rawValue
    @AppStorage(CJKSpacingMode.storageKey) private var cjkSpacingRaw = CJKSpacingMode.defaultValue
    @AppStorage(CornerQuotePreference.storageKey) private var useCornerQuotes = CornerQuotePreference.defaultValue
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault

    var body: some View {
        switch appState.barPhase {
        case .preparing, .recording:
            activeRecordingActions
        case .processing, .recovering:
            processingActions
        case .error:
            errorFeedback
            Divider()
            readyActions
        case .hidden, .done:
            readyActions
        }

        Divider()
        runtimeControls
        Divider()
        workspaceActions
        conditionalSystemActions
        Divider()
        Button(L("打开 Type4Me", "Open Type4Me")) { actions.openType4Me() }
        Button(L("设置…", "Settings…")) { actions.openSettings() }
            .keyboardShortcut(",", modifiers: .command)
        Button(L("退出 Type4Me", "Quit Type4Me")) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)

        let _ = registerGlobalOpenActions()
    }

    @ViewBuilder
    private var readyActions: some View {
        startDictationMenu
        if appState.latestReviseUndoTicketID != nil {
            Button(L("撤销刚才的改口", "Undo last revision")) {
                actions.undoLatestRevise()
            }
        } else if model.canStartRevise {
            Button(L("改口上一条…", "Revise last result…")) {
                actions.startRevise()
            }
        }
    }

    @ViewBuilder
    private var activeRecordingActions: some View {
        Button(L("完成录音", "Finish Recording")) {
            actions.finishRecording()
        }
        Button(L("取消录音", "Cancel Recording")) {
            actions.cancelRecording()
        }
    }

    private var processingActions: some View {
        Label(
            appState.effectiveProcessingLabel,
            systemImage: appState.barPhase == .recovering
                ? "arrow.triangle.2.circlepath"
                : "circle.dotted"
        )
        .foregroundStyle(.secondary)
    }

    private var errorFeedback: some View {
        Label(appState.feedbackMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(TF.settingsAccentRed)
    }

    private var startDictationMenu: some View {
        Menu(L("开始口述", "Start Dictation")) {
            ForEach(appState.availableModes) { mode in
                Button {
                    actions.startRecording(modeID: mode.id)
                } label: {
                    HStack {
                        Text(modeMenuTitle(mode))
                        Spacer()
                        if let summary = hotkeySummary(for: mode) {
                            Text(summary).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            Button(L("管理模式…", "Manage Modes…")) {
                actions.openModes()
            }
        }
        .disabled(!canStartRecording)
    }

    @ViewBuilder
    private var runtimeControls: some View {
        microphoneMenu
        asrProviderMenu
        if model.translationMode != nil {
            translationTargetMenu
        }
        Toggle(
            L("实时展示文本", "Live Transcript"),
            isOn: Binding(
                get: { liveTranscriptEnabled },
                set: { actions.setLiveTranscript($0) }
            )
        )
        outputFormattingMenu
    }

    private var microphoneMenu: some View {
        Menu(L("麦克风", "Microphone")) {
            Button {
                actions.setMicrophone(.systemDefault)
            } label: {
                menuChoiceLabel(
                    systemDefaultMicrophoneTitle,
                    isSelected: AudioInputDevicePreferenceStore.mode() == .systemDefault
                )
            }
            if AudioInputDevicePreferenceStore.mode() == .priority,
               let effectiveInputDevice = model.effectiveInputDevice {
                Label(
                    L(
                        "当前使用：\(effectiveInputDevice.name)",
                        "Currently using: \(effectiveInputDevice.name)"
                    ),
                    systemImage: "waveform"
                )
                .foregroundStyle(.secondary)
            }
            if !model.inputDevices.isEmpty {
                Divider()
                ForEach(model.inputDevices) { device in
                    Button {
                        actions.setMicrophone(.device(device))
                    } label: {
                        menuChoiceLabel(
                            device.name,
                            isSelected: model.selectedPriorityMicrophoneUID == device.uid
                        )
                    }
                }
            }
            Divider()
            Button(L("管理麦克风优先级…", "Manage Microphone Priority…")) {
                actions.openSettings()
            }
        }
        .disabled(runtimeSettingsLocked)
    }

    private var systemDefaultMicrophoneTitle: String {
        guard let device = model.systemDefaultInputDevice else {
            return L("跟随系统", "Follow System")
        }
        return L(
            "跟随系统（当前：\(device.name)）",
            "Follow System (Current: \(device.name))"
        )
    }

    private var asrProviderMenu: some View {
        Menu(L("识别引擎", "Speech Recognition")) {
            if model.configuredASRProviders.isEmpty {
                Text(L("没有已配置的识别引擎", "No configured recognition engine"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.configuredASRProviders) { item in
                    Button {
                        actions.setASRProvider(item.provider)
                    } label: {
                        menuChoiceLabel(
                            item.title,
                            isSelected: item.provider == KeychainService.selectedASRProvider
                        )
                    }
                }
            }
            Divider()
            Button(L("配置识别引擎…", "Configure Recognition…")) {
                actions.openModels()
            }
        }
        .disabled(runtimeSettingsLocked)
    }

    private var translationTargetMenu: some View {
        Menu(L("翻译目标", "Translation Target")) {
            ForEach(TranslationLanguage.allCases) { language in
                Button {
                    actions.setTranslationTarget(language)
                } label: {
                    menuChoiceLabel(language.displayName, isSelected: language == model.translationTarget)
                }
            }
        }
        .disabled(runtimeSettingsLocked)
    }

    private var outputFormattingMenu: some View {
        Menu(L("输出格式", "Output Formatting")) {
            Menu(L("剪贴板保留", "Clipboard Retention")) {
                ForEach(ClipboardOutputPolicy.allCases) { policy in
                    Button {
                        actions.setClipboardOutputPolicy(policy)
                    } label: {
                        menuChoiceLabel(
                            policy.displayName,
                            isSelected: policy.rawValue == clipboardOutputPolicyRaw
                        )
                    }
                }
            }
            if appState.currentMode.supportsOutputFormatting {
                punctuationMenu
            }
            Menu(L("中英文间距", "CJK Spacing")) {
                ForEach(CJKSpacingMode.allCases, id: \.rawValue) { mode in
                    Button {
                        actions.setCJKSpacing(mode)
                    } label: {
                        menuChoiceLabel(cjkSpacingTitle(mode), isSelected: mode.rawValue == cjkSpacingRaw)
                    }
                }
            }
            Toggle(
                L("使用直角引号「」", "Use Corner Quotes 「」"),
                isOn: Binding(
                    get: { useCornerQuotes },
                    set: { actions.setCornerQuotes($0) }
                )
            )
            Divider()
            Button(L("更多输出设置…", "More Output Settings…")) {
                actions.openSettings()
            }
        }
        .disabled(runtimeSettingsLocked)
    }

    private var punctuationMenu: some View {
        Menu(L("当前模式标点", "Current Mode Punctuation")) {
            ForEach(ModePunctuationMode.allCases, id: \.rawValue) { mode in
                Button {
                    actions.setPunctuationMode(mode)
                } label: {
                    menuChoiceLabel(
                        punctuationTitle(mode),
                        isSelected: mode == appState.currentMode.punctuationMode
                    )
                }
            }
        }
    }

    private var workspaceActions: some View {
        Group {
            if let feedback = model.lastActionFeedback {
                Label(feedback, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Button(L("复制上一条结果", "Copy Last Result")) {
                actions.copyLatestResult()
            }
            .disabled(!model.canCopyLatestResult)
            Button(L("打开随便问…", "Open Ask Anything…")) {
                actions.openAskAnything()
            }
            Button(L("词汇…", "Vocabulary…")) {
                actions.openVocabulary()
            }
            Button(L("历史记录…", "History…")) {
                actions.openHistory()
            }
        }
    }

    @ViewBuilder
    private var conditionalSystemActions: some View {
        if let issue = model.permissionIssue {
            Divider()
            Button {
                actions.openPermissionGuide()
            } label: {
                Label(issue.title, systemImage: "exclamationmark.triangle.fill")
            }
        }
        if shouldShowUpdate {
            Divider()
            Button(updateActionTitle) {
                actions.performUpdateAction()
            }
        }
    }

    private var canStartRecording: Bool {
        MenuBarPresentation.canStartRecording(in: appState.barPhase)
    }

    private var runtimeSettingsLocked: Bool {
        MenuBarPresentation.locksRuntimeSettings(in: appState.barPhase)
    }

    private var shouldShowUpdate: Bool {
        if !appState.availableUpdates.isEmpty { return true }
        switch appUpdater.state {
        case .idle: return false
        case .downloading, .verifying, .readyToInstall, .installing, .failed: return true
        }
    }

    private var updateActionTitle: String {
        switch appUpdater.state {
        case .idle:
            if let release = appState.availableUpdates.first {
                return L("有新版本 \(release.version)…", "Update \(release.version)…")
            }
            return L("检查更新…", "Check for Updates…")
        case .downloading(let progress):
            return L("取消更新下载（\(Int(progress * 100))%）", "Cancel Update Download (\(Int(progress * 100))%)")
        case .verifying:
            return L("正在验证更新…", "Verifying Update…")
        case .readyToInstall:
            return L("安装更新并重启", "Install Update and Restart")
        case .installing:
            return L("正在安装更新…", "Installing Update…")
        case .failed:
            return L("重试更新下载", "Retry Update Download")
        }
    }

    private func modeMenuTitle(_ mode: ProcessingMode) -> String {
        guard mode.id == ProcessingMode.translationModeId,
              let target = model.translationTarget
        else { return localizedModeName(mode) }
        return "\(localizedModeName(mode)) → \(target.displayName)"
    }

    private func localizedModeName(_ mode: ProcessingMode) -> String {
        // MenuBarExtra can remain visible while language changes in Settings;
        // reading the preference makes its labels refresh without a relaunch.
        _ = language
        return mode.localizedDisplayName
    }

    private func hotkeySummary(for mode: ProcessingMode) -> String? {
        guard !mode.hotkeyBindings.isEmpty else { return nil }
        return mode.hotkeyBindings
            .map { HotkeyRecorderView.keyDisplayName(keyCode: $0.keyCode, modifiers: $0.modifiers) }
            .joined(separator: " / ")
    }

    @ViewBuilder
    private func menuChoiceLabel(_ title: String, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            if isSelected {
                Image(systemName: "checkmark")
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
            Text(title)
        }
    }

    private func punctuationTitle(_ mode: ModePunctuationMode) -> String {
        switch mode {
        case .inherit: return L("跟随通用设置", "Follow General Settings")
        case .preserve: return L("保留标点", "Keep Punctuation")
        case .stripTrailing: return L("去除句末标点", "Strip Trailing Punctuation")
        case .questionsAndExclamationsOnly: return L("只保留问号和感叹号", "Keep ? and ! Only")
        case .removeAll: return L("去除所有标点", "Remove All Punctuation")
        }
    }

    private func cjkSpacingTitle(_ mode: CJKSpacingMode) -> String {
        switch mode {
        case .pangu: return L("盘古之白", "Pangu Spacing")
        case .off: return L("保持原样", "Keep As Is")
        case .remove: return L("移除空格", "Remove Spaces")
        }
    }

    private func registerGlobalOpenActions() {
        // `presentSettings()` invokes these as a fallback after its standard
        // AppKit action. They must open the SwiftUI scene directly rather than
        // route back through the coordinator, or the fallback recursively
        // re-enters `presentSettings()`.
        AppDelegate.openSettingsAction = { [openWindow] in
            openWindow(id: "settings")
        }
        AppDelegate.openPermissionGuideAction = { [openWindow] in
            openWindow(id: "permission-guide")
        }
        AppDelegate.openSetupAction = { [openWindow] in
            openWindow(id: "setup")
        }
    }
}

enum MenuBarPresentation {
    static func canStartRecording(in phase: FloatingBarPhase) -> Bool {
        switch phase {
        case .hidden, .done, .error:
            return true
        case .preparing, .recording, .processing, .recovering:
            return false
        }
    }

    static func locksRuntimeSettings(in phase: FloatingBarPhase) -> Bool {
        phase == .preparing || phase == .recording
    }
}
