import Foundation

enum TranslationLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case brazilianPortuguese = "pt-BR"
    case italian = "it"
    case russian = "ru"
    case arabic = "ar"
    case hindi = "hi"
    case thai = "th"
    case vietnamese = "vi"
    case indonesian = "id"
    case turkish = "tr"
    case dutch = "nl"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return L("英语", "English")
        case .simplifiedChinese: return L("简体中文", "Chinese (Simplified)")
        case .traditionalChinese: return L("繁体中文", "Chinese (Traditional)")
        case .japanese: return L("日语", "Japanese")
        case .korean: return L("韩语", "Korean")
        case .spanish: return L("西班牙语", "Spanish")
        case .french: return L("法语", "French")
        case .german: return L("德语", "German")
        case .brazilianPortuguese: return L("葡萄牙语（巴西）", "Portuguese (Brazil)")
        case .italian: return L("意大利语", "Italian")
        case .russian: return L("俄语", "Russian")
        case .arabic: return L("阿拉伯语", "Arabic")
        case .hindi: return L("印地语", "Hindi")
        case .thai: return L("泰语", "Thai")
        case .vietnamese: return L("越南语", "Vietnamese")
        case .indonesian: return L("印度尼西亚语", "Indonesian")
        case .turkish: return L("土耳其语", "Turkish")
        case .dutch: return L("荷兰语", "Dutch")
        }
    }

    /// Stable English names for prompts. These must not vary with app locale.
    var promptName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "Simplified Chinese"
        case .traditionalChinese: return "Traditional Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .brazilianPortuguese: return "Brazilian Portuguese"
        case .italian: return "Italian"
        case .russian: return "Russian"
        case .arabic: return "Arabic"
        case .hindi: return "Hindi"
        case .thai: return "Thai"
        case .vietnamese: return "Vietnamese"
        case .indonesian: return "Indonesian"
        case .turkish: return "Turkish"
        case .dutch: return "Dutch"
        }
    }

    /// Raw identifiers returned by NLLanguageRecognizer.
    var naturalLanguageIdentifiers: Set<String> {
        switch self {
        case .simplifiedChinese: return ["zh-Hans", "zh"]
        case .traditionalChinese: return ["zh-Hant", "zh"]
        case .brazilianPortuguese: return ["pt-BR", "pt"]
        default: return [rawValue]
        }
    }
}
