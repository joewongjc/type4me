import SwiftUI

// MARK: - Navigation Item

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case models
    case vocabulary
    case modes
    case history
    case about
    #if HAS_CLOUD_SUBSCRIPTION
    case account
    #endif

    var id: String { rawValue }

    #if HAS_CLOUD_SUBSCRIPTION
    static func tabs(for edition: AppEdition?) -> [SettingsTab] {
        switch edition {
        case .member:
            return [.general, .modes, .vocabulary, .history, .about]
        case .byoKey, .none:
            return allCases.map { $0 }
        }
    }
    #endif

    var displayName: String {
        switch self {
        case .general:     return L("通用", "General")
        case .models:      return L("模型", "Models")
        case .vocabulary:  return L("词汇", "Vocabulary")
        case .modes:       return L("模式", "Modes")
        case .history:     return L("历史", "History")
        case .about:       return L("关于", "About")
        #if HAS_CLOUD_SUBSCRIPTION
        case .account:     return L("账户", "Account")
        #endif
        }
    }

    var subtitle: String {
        switch self {
        case .general:    return L("偏好与系统权限", "Preferences & permissions")
        case .models:      return L("语音识别与 LLM 引擎", "ASR & LLM engines")
        case .vocabulary:  return L("热词与片段替换", "Hotwords & snippets")
        case .modes:       return L("推理与默认行为", "Processing & defaults")
        case .history:     return L("会话与日志保留", "Sessions & logs")
        case .about:       return L("版本、许可证与支持", "Version, license & support")
        #if HAS_CLOUD_SUBSCRIPTION
        case .account:     return L("登录与订阅管理", "Login & subscription")
        #endif
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {

    @Environment(AppState.self) private var appState
    @State private var selectedTab: SettingsTab = .general
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault
    #if HAS_CLOUD_SUBSCRIPTION
    @State private var showDeviceConflict = false
    @AppStorage("tf_app_edition") private var editionRaw: String?
    private var edition: AppEdition? { editionRaw.flatMap { AppEdition(rawValue: $0) } }
    #endif

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .id(language)
        .frame(minWidth: 700, minHeight: 480)
        .background(TF.settingsBg)
        .preferredColorScheme(.light)
        #if HAS_CLOUD_SUBSCRIPTION
        .onAppear {
            if (selectedTab == .models && edition == .member) ||
               (selectedTab == .account && edition != .member) {
                selectedTab = .general
            }
        }
        .onChange(of: editionRaw) { _, _ in
            if (selectedTab == .models && edition == .member) ||
               (selectedTab == .account && edition != .member) {
                selectedTab = .general
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudDeviceConflict)) { _ in
            showDeviceConflict = true
        }
        .alert(L("设备冲突", "Device Conflict"), isPresented: $showDeviceConflict) {
            Button("OK") { if edition == .member { selectedTab = .account } }
        } message: {
            Text(L("你的账户已在其他设备登录，当前设备已自动登出。",
                    "Your account has been logged in on another device. This device has been signed out."))
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .navigateToMode)) { note in
            selectedTab = .modes
            if let modeId = note.object as? UUID {
                NotificationCenter.default.post(name: .selectMode, object: modeId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToHistory)) { _ in
            selectedTab = .history
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand
            VStack(alignment: .leading, spacing: 2) {
                Text("TYPE4ME")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text(L("偏好设置", "Preferences"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(TF.settingsText)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Nav items
            VStack(spacing: 2) {
                #if HAS_CLOUD_SUBSCRIPTION
                ForEach(SettingsTab.tabs(for: edition)) { tab in
                    navItem(tab)
                }
                #else
                ForEach(SettingsTab.allCases) { tab in
                    navItem(tab)
                }
                #endif
            }
            .padding(.horizontal, 10)

            Spacer()

            #if HAS_CLOUD_SUBSCRIPTION
            if edition == .member {
                navItem(.account)
                    .padding(.horizontal, 10)
            }
            EditionSwitchLink()
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            #endif
        }
        .frame(width: 180)
        .background(TF.settingsBg)
    }

    private func navItem(_ tab: SettingsTab) -> some View {
        let isActive = selectedTab == tab
        let showBadge = tab == .about && appState.hasUnseenUpdate
        return Button {
            selectedTab = tab
            if tab == .about {
                UpdateChecker.shared.markAsSeen(appState: appState)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isActive ? .white : TF.settingsText)
                    Text(tab.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(isActive ? .white.opacity(0.7) : TF.settingsTextTertiary)
                }
                Spacer()
                if showBadge {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? TF.settingsNavActive : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    private var content: some View {
        ZStack {
            tabPage(.general)    { GeneralSettingsTab() }
            #if HAS_CLOUD_SUBSCRIPTION
            if edition != .member {
                tabPage(.models) { ModelSettingsTab() }
            }
            #else
            tabPage(.models)     { ModelSettingsTab() }
            #endif
            tabPage(.vocabulary) { VocabularyTab() }
            tabPage(.modes)      { ModesSettingsTab() }
            fixedPage(.history)  { HistoryTab(isActive: selectedTab == .history) }
            tabPage(.about)      { AboutTab() }
            #if HAS_CLOUD_SUBSCRIPTION
            if edition == .member {
                tabPage(.account) { AccountTab() }
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TF.settingsCard)
    }

    /// Scrollable tab page (most tabs).
    private func tabPage<V: View>(_ tab: SettingsTab, @ViewBuilder content: () -> V) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .opacity(selectedTab == tab ? 1 : 0)
        .allowsHitTesting(selectedTab == tab)
    }

    /// Fixed-height tab page (no outer scroll, content manages its own scroll).
    private func fixedPage<V: View>(_ tab: SettingsTab, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(selectedTab == tab ? 1 : 0)
        .allowsHitTesting(selectedTab == tab)
    }
}

// MARK: - Reusable Components

struct SettingsSectionHeader: View {
    let label: String
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(TF.settingsTextTertiary)
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(TF.settingsText)
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextTertiary)
                .lineSpacing(2)
        }
        .padding(.bottom, 16)
    }
}

struct SettingsRow: View {
    let label: String
    let value: String
    var statusColor: Color? = nil

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(statusColor ?? TF.settingsTextSecondary)
        }
        .padding(.vertical, 10)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.vertical, 2)
    }
}
