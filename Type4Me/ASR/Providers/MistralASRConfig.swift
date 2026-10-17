import Foundation

enum MistralVoxtralModel: String, CaseIterable, Sendable {
    case miniTranscribe2 = "voxtral-mini-2602"
    case small = "voxtral-small-2507"

    enum Endpoint: Sendable {
        case transcriptions
        case chatCompletions
    }

    var endpoint: Endpoint {
        switch self {
        case .miniTranscribe2: return .transcriptions
        case .small:           return .chatCompletions
        }
    }

    /// Longest recording sent in one request; nil when the provider limit is far above dictation use.
    var maxDuration: TimeInterval? {
        switch self {
        case .miniTranscribe2: return nil
        case .small:           return 15 * 60
        }
    }

    var optionLabel: String {
        switch self {
        case .miniTranscribe2: return "Voxtral Mini Transcribe 2 ($0.18/hr)"
        case .small:           return "Voxtral Small ($0.24/hr + tokens)"
        }
    }
}

struct MistralASRConfig: ASRProviderConfig, Sendable {
    static let provider = ASRProvider.mistral
    static let displayName = "Mistral AI"
    static let defaultModel = MistralVoxtralModel.miniTranscribe2

    /// Voxtral's 13 documented languages.
    static let supportedLanguages = [
        "", "zh", "en", "ja", "ko", "fr", "de", "es", "pt", "it", "nl", "ru", "ar", "hi",
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
            placeholder: L("Mistral API Key", "Mistral API key"),
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
            options: MistralVoxtralModel.allCases.map { FieldOption(value: $0.rawValue, label: $0.optionLabel) }
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
    let model: MistralVoxtralModel
    let language: String

    init?(credentials: [String: String]) {
        let key = credentials["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { return nil }

        self.apiKey = key
        let rawModel = credentials["model"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.model = MistralVoxtralModel(rawValue: rawModel) ?? Self.defaultModel
        let lang = credentials["language"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.language = Self.supportedLanguages.contains(lang) ? lang : ""
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
