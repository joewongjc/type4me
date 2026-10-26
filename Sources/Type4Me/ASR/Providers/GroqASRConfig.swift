import Foundation

enum GroqWhisperModel: String, CaseIterable, Sendable {
    case largeV3Turbo = "whisper-large-v3-turbo"
    case largeV3 = "whisper-large-v3"

    var optionLabel: String {
        switch self {
        case .largeV3Turbo: return "Whisper Large v3 Turbo ($0.04/hr)"
        case .largeV3:      return "Whisper Large v3 ($0.111/hr)"
        }
    }
}

struct GroqASRConfig: ASRProviderConfig, Sendable {
    static let provider = ASRProvider.groq
    static let displayName = "Groq"
    static let defaultModel = GroqWhisperModel.largeV3Turbo

    static let supportedLanguages = [
        "", "zh", "en", "ja", "ko",
        "fr", "de", "es", "it", "pt", "ru", "ar", "hi", "id", "th", "vi", "tr", "nl", "pl",
    ]

    static func languageLabel(_ code: String) -> String {
        switch code {
        case "":   return L("自动检测", "Auto-detect")
        case "zh": return L("中文（简体）", "Chinese (Simplified)")
        case "en": return L("英文", "English")
        case "ja": return L("日语", "Japanese")
        case "ko": return L("韩语", "Korean")
        default:   return code.uppercased()
        }
    }

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "apiKey",
            label: "API Key",
            placeholder: "gsk_...",
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "model",
            label: L("模型", "Model"),
            placeholder: defaultModel.rawValue,
            isSecure: false,
            isOptional: true,
            defaultValue: defaultModel.rawValue,
            options: GroqWhisperModel.allCases.map { FieldOption(value: $0.rawValue, label: $0.optionLabel) }
        ),
        CredentialField(
            key: "language",
            label: L("语言", "Language"),
            placeholder: "auto",
            isSecure: false,
            isOptional: true,
            defaultValue: "",
            options: supportedLanguages.map { FieldOption(value: $0, label: languageLabel($0)) }
        ),
    ]}

    let apiKey: String
    let model: GroqWhisperModel
    let language: String

    init?(credentials: [String: String]) {
        let key = credentials["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { return nil }

        self.apiKey = key
        let rawModel = credentials["model"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.model = GroqWhisperModel(rawValue: rawModel) ?? Self.defaultModel
        self.language = credentials["language"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func toCredentials() -> [String: String] {
        var creds: [String: String] = [
            "apiKey": apiKey,
            "model": model.rawValue,
        ]
        if !language.isEmpty {
            creds["language"] = language
        }
        return creds
    }

    var isValid: Bool {
        !apiKey.isEmpty
    }
}
