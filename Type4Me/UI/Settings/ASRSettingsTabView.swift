import SwiftUI

// MARK: - ASR Settings Tab View

struct ASRSettingsTabView: View, SettingsCardHelpers {

    @State private var selectedTab: ASRSettingsTab

    enum ASRSettingsTab: String, CaseIterable {
        case selfConfig
        case cloud
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: "tf_asrSettingsTab") ?? ASRSettingsTab.selfConfig.rawValue
        _selectedTab = State(initialValue: ASRSettingsTab(rawValue: stored) ?? .selfConfig)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Tab switcher
            tabPicker

            // Content
            switch selectedTab {
            case .selfConfig:
                ASRSettingsCard()
            case .cloud:
                cloudTabContent
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            UserDefaults.standard.set(newTab.rawValue, forKey: "tf_asrSettingsTab")
        }
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        settingsSegmentedPicker(
            selection: Binding(
                get: { selectedTab.rawValue },
                set: { if let tab = ASRSettingsTab(rawValue: $0) { selectedTab = tab } }
            ),
            options: [
                (ASRSettingsTab.selfConfig.rawValue, L("自行配置 API", "Self-Config API")),
                (ASRSettingsTab.cloud.rawValue, "Type4Me Cloud \(starSymbol)"),
            ]
        )
    }

    private var starSymbol: String { "\u{2605}" }

    // MARK: - Cloud Tab

    private var cloudTabContent: some View {
        settingsGroupCard(L("Type4Me Cloud", "Type4Me Cloud"), icon: "cloud.fill") {
            CloudAccountView()
        }
    }
}
