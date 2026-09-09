import SwiftUI

/// Appearance preference for standard Type4Me windows. RecordingTheme remains independent.
enum SettingsTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "tf_settingsTheme"
    static let defaultValue = SettingsTheme.system
    var id: String { rawValue }

    static func resolve(_ rawValue: String) -> SettingsTheme {
        SettingsTheme(rawValue: rawValue) ?? defaultValue
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .system: language == .zh ? "跟随系统" : "Follow System"
        case .light: language == .zh ? "浅色" : "Light"
        case .dark: language == .zh ? "深色" : "Dark"
        }
    }

    var iconName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
}
