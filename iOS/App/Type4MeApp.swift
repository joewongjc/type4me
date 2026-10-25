import AVFoundation
import SwiftUI
import Type4MeTransferCore

@main
struct Type4MeApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.session)
                .environmentObject(model.history)
                .environmentObject(model.log)
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.didBecomeActive() }
                }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let history = HistoryStore()
    let log = DiagnosticsLog()
    let session: VoiceSession

    @Published var onboardingCompleted = AppSettings.onboardingCompleted
    @Published var keyboardSeen = SharedSettings.keyboardLastSeen != nil
    /// A scanned sync waiting for the user to pick what to import.
    @Published var pendingImport: PendingImport?
    @Published var showsSessionStarted = false
    @Published var configVersion = 0
    @Published var tab: AppTab = .home
    /// Pages pushed on the Settings tab, so other tabs can open one directly.
    @Published var settingsPath: [SettingsRoute] = []
    @Published var showsScanner = false
    /// A code already scanned by the system camera, handed to the scanner.
    @Published var scannerSeed: String?
    /// Changing it rebuilds the interface in the new language.
    @Published private(set) var language = AppLanguage.current

    init() {
        session = VoiceSession(history: history, log: log)
        ConfigStore.refreshSharedFlags()
        DarwinNotifier.shared.observe(DarwinName.keyboardAppeared) { [weak self] in
            self?.keyboardSeen = true
        }
        #if DEBUG
        DemoSeed.apply(to: self)
        #endif
    }

    var hasConfig: Bool { ConfigStore.asr != nil }

    var micGranted: Bool { AVAudioApplication.shared.recordPermission == .granted }

    func handle(url: URL) {
        guard url.scheme == SharedContainer.urlScheme else { return }
        switch url.host {
        case Type4MeTransferCodec.urlHost:
            // A whole setup in one code goes straight to the import page. One
            // code of a series, or one that can't be read, continues in the
            // scanner, which collects the rest and explains failures.
            if let payload = try? Type4MeTransferCodec.decode(url.absoluteString) {
                pendingImport = PendingImport(payload: payload)
            } else {
                scannerSeed = url.absoluteString
                showsScanner = true
            }
        case "session":
            session.startSession(trigger: L("从键盘跳转", "opened from the keyboard"))
            if session.isActive { showsSessionStarted = true }
        default:
            break
        }
    }

    /// Opening the app is enough to arm dictation: the session starts here,
    /// in the foreground, and the keyboard can use it after the user leaves.
    /// nil follows the system language.
    func setLanguage(_ override: AppLanguage?) {
        AppLanguage.override = override
        language = AppLanguage.current
    }

    func didBecomeActive() {
        // The system language may have changed while we were away.
        if language != AppLanguage.current { language = AppLanguage.current }
        keyboardSeen = SharedSettings.keyboardLastSeen != nil
        session.appDidBecomeActive()
        guard onboardingCompleted, hasConfig, micGranted, !session.isActive else { return }
        session.startSession(trigger: L("打开 App", "app opened"))
    }

    func completeOnboarding() {
        AppSettings.onboardingCompleted = true
        onboardingCompleted = true
        didBecomeActive()
    }

    /// Opens Settings › Modes from anywhere.
    func showModeSettings() {
        tab = .settings
        settingsPath = [.modes]
    }

    func importConfig(_ payload: Type4MeTransferPayload) throws {
        try importConfig(payload, selection: ConfigStore.ImportSelection(all: payload))
    }

    func importConfig(_ payload: Type4MeTransferPayload, selection: ConfigStore.ImportSelection) throws {
        try ConfigStore.save(payload, selection: selection)
        let modes = (payload.modes ?? []).filter { selection.modes.contains($0.id) }
        if !modes.isEmpty { ModeStore.shared.applySync(modes) }
        configVersion += 1
        let asrCount = payload.allASRs.filter { selection.asrs.contains($0.provider) }.count
        let llmCount = payload.allLLMs.filter { selection.llms.contains($0.provider) }.count
        log.add(L(
            "已从 \(payload.sourceName ?? "Mac") 同步：识别服务 \(asrCount) 个，处理模型 \(llmCount) 个，模式 \(modes.count) 个",
            "Synced from \(payload.sourceName ?? "Mac"): \(asrCount) speech services, \(llmCount) text models, \(modes.count) modes"
        ))
        if onboardingCompleted { didBecomeActive() }
    }
}

enum AppTab: Hashable {
    case home, history, settings
}

struct PendingImport: Identifiable {
    let id = UUID()
    let payload: Type4MeTransferPayload
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.onboardingCompleted {
                // The Mac window's sidebar (Home, History, Settings) as the
                // iOS 26 Liquid Glass tab bar.
                TabView(selection: $model.tab) {
                    Tab(L("首页", "Home"), systemImage: "house", value: AppTab.home) {
                        NavigationStack { HomeView() }
                    }
                    Tab(L("历史", "History"), systemImage: "clock.arrow.circlepath", value: AppTab.history) {
                        NavigationStack { HistoryView() }
                    }
                    Tab(L("设置", "Settings"), systemImage: "gearshape", value: AppTab.settings) {
                        NavigationStack(path: $model.settingsPath) {
                            SettingsView()
                                .navigationDestination(for: SettingsRoute.self) { $0.destination }
                        }
                    }
                }
            } else {
                OnboardingView()
            }
        }
        .tint(T4.ink)
        .id(model.language)
        .environment(\.locale, model.language.locale)
        .sheet(item: $model.pendingImport) { pending in
            NavigationStack { ImportView(payload: pending.payload) }
        }
        .fullScreenCover(isPresented: $model.showsSessionStarted) {
            SessionStartedView()
        }
        .sheet(isPresented: $model.showsScanner, onDismiss: { model.scannerSeed = nil }) {
            ConfigScannerSheet(seed: model.scannerSeed) { payload in
                model.showsScanner = false
                model.scannerSeed = nil
                model.pendingImport = PendingImport(payload: payload)
            }
        }
    }
}
