import Foundation

enum AppLanguage: String, CaseIterable {
    case zh
    case en

    var displayName: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        }
    }

    /// System language is Chinese? Default to zh, otherwise en.
    static var systemDefault: String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? "zh" : "en"
    }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "tf_language") ?? systemDefault) ?? .en
    }
}

/// Inline localization helper. Returns Chinese or English based on app language setting.
func L(_ zh: String, _ en: String) -> String {
    AppLanguage.current == .zh ? zh : en
}

extension String {
    /// Latin phonetic / pinyin representation for unified alphabetical sorting across Chinese and English.
    var pinyinSortingKey: String {
        let mutable = NSMutableString(string: self)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Compares strings alphabetically, handling Chinese pinyin collation consistently regardless of system locale.
    func localizedAlphabeticalCompare(_ other: String) -> ComparisonResult {
        let k1 = self.pinyinSortingKey
        let k2 = other.pinyinSortingKey
        if k1 != k2 {
            return k1.localizedCaseInsensitiveCompare(k2)
        }
        return self.localizedCaseInsensitiveCompare(other)
    }
}
