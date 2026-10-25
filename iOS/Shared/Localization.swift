import Foundation

/// Interface language, shared by the app and the keyboard through the App
/// Group. Follows the system by default: Chinese when the first preferred
/// language is Chinese, English for everything else. Same `tf_language` key
/// and `L(zh, en)` helper as the Mac app.
enum AppLanguage: String, CaseIterable, Identifiable {
    case zh
    case en

    static let storageKey = "tf_language"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        }
    }

    static var systemDefault: AppLanguage {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? .zh : .en
    }

    /// nil means "follow the system".
    static var override: AppLanguage? {
        get { SharedContainer.defaults?.string(forKey: storageKey).flatMap(AppLanguage.init(rawValue:)) }
        set {
            if let newValue {
                SharedContainer.defaults?.set(newValue.rawValue, forKey: storageKey)
            } else {
                SharedContainer.defaults?.removeObject(forKey: storageKey)
            }
        }
    }

    static var current: AppLanguage { override ?? systemDefault }

    var locale: Locale { Locale(identifier: self == .zh ? "zh_CN" : "en_US") }
}

/// Returns the Chinese or English string for the current interface language.
func L(_ zh: String, _ en: String) -> String {
    AppLanguage.current == .zh ? zh : en
}
