import SwiftUI

/// Global holder of the active theme. `TF`'s computed tokens read from here.
/// Views that need live theme switching observe this and re-`.id(...)` on change.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    private static let defaultsKey = "tf_theme"

    @Published var current: AppTheme {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: Self.defaultsKey)
            AppIconThemeSync.apply(current)
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey)
        current = saved.flatMap(AppTheme.init(rawValue:)) ?? .warm
    }
}
