import SwiftUI
import UIKit

/// Home Screen icons the user can pick in Settings. Each alternate is an
/// app icon set in Assets.xcassets, listed under
/// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` in project.yml, and has a
/// small `AppIconPreview-*` image because iOS won't hand the app its icons.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case system, light, dark, red, keycapLight, keycapDark, keycapRed

    var id: String { rawValue }

    /// How the Settings page groups the icons.
    enum Group: CaseIterable, Identifiable {
        case classic, keycap

        var id: Self { self }

        var title: String {
            switch self {
            case .classic: L("简版", "Classic")
            case .keycap: L("键帽", "Keycap")
            }
        }

        var choices: [AppIconChoice] { AppIconChoice.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .system, .light, .dark, .red: .classic
        case .keycapLight, .keycapDark, .keycapRed: .keycap
        }
    }

    /// The name `setAlternateIconName` takes; nil is the primary icon, which
    /// follows the system's light, dark and tinted Home Screen.
    var iconName: String? {
        switch self {
        case .system: nil
        case .light: "AppIcon-Light"
        case .dark: "AppIcon-Dark"
        case .red: "AppIcon-Red"
        case .keycapLight: "AppIcon-KeycapLight"
        case .keycapDark: "AppIcon-KeycapDark"
        case .keycapRed: "AppIcon-KeycapRed"
        }
    }

    var preview: Image {
        switch self {
        case .system: Image("AppIconPreview-System")
        case .light: Image("AppIconPreview-Light")
        case .dark: Image("AppIconPreview-Dark")
        case .red: Image("AppIconPreview-Red")
        case .keycapLight: Image("AppIconPreview-KeycapLight")
        case .keycapDark: Image("AppIconPreview-KeycapDark")
        case .keycapRed: Image("AppIconPreview-KeycapRed")
        }
    }

    var title: String {
        switch self {
        case .system: L("跟随系统", "Automatic")
        case .light: L("浅色", "Light")
        case .dark: L("深色", "Dark")
        case .red: L("红底", "Red")
        case .keycapLight: L("键帽 · 浅", "Keycap Light")
        case .keycapDark: L("键帽 · 深", "Keycap Dark")
        case .keycapRed: L("键帽 · 红", "Keycap Red")
        }
    }

    /// The name under its preview, where the group heading already says
    /// "Keycap".
    var shortTitle: String {
        switch self {
        case .keycapLight: L("浅色", "Light")
        case .keycapDark: L("深色", "Dark")
        case .keycapRed: L("红色", "Red")
        default: title
        }
    }

    init(iconName: String?) {
        self = Self.allCases.first { $0.iconName == iconName } ?? .system
    }
}

/// The icon in use. Read from UIKit rather than stored, so it can't drift
/// from what the Home Screen shows.
@MainActor
final class AppIconStore: ObservableObject {
    static let shared = AppIconStore()

    @Published private(set) var current = AppIconChoice(iconName: UIApplication.shared.alternateIconName)

    var isSupported: Bool { UIApplication.shared.supportsAlternateIcons }

    /// iOS shows its own "icon changed" alert; there is no way to skip it.
    func select(_ choice: AppIconChoice) async throws {
        guard choice != current else { return }
        try await UIApplication.shared.setAlternateIconName(choice.iconName)
        current = choice
    }
}
