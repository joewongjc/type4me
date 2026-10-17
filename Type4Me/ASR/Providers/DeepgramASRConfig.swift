import Foundation

struct DeepgramASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.deepgram
    static let displayName = "Deepgram"
    static let defaultModel = "nova-3"
    static let defaultLanguage = "zh"
    static let defaultBaseURL = "wss://api.deepgram.com/v1/listen"

    static func isFluxModel(_ model: String) -> Bool {
        model.localizedCaseInsensitiveContains("flux")
    }

    static let supportedModels = [
        "nova-3",
        "nova-3-general",
        "flux-general-multi",
        "flux-general-en",
        "nova-3-medical",
        "nova-2",
        "nova-2-general",
        "nova-2-meeting",
        "nova-2-phonecall",
    ]

    static let modelOptions: [FieldOption] = [
        FieldOption(value: "nova-3", label: "Nova-3 (Multilingual)"),
        FieldOption(value: "nova-3-general", label: "Nova-3 General"),
        FieldOption(value: "flux-general-multi", label: "Deepgram Flux (Multilingual)"),
        FieldOption(value: "flux-general-en", label: "Deepgram Flux (English)"),
        FieldOption(value: "nova-3-medical", label: "Nova-3 Medical"),
        FieldOption(value: "nova-2", label: "Nova-2"),
        FieldOption(value: "nova-2-general", label: "Nova-2 General"),
        FieldOption(value: "nova-2-meeting", label: "Nova-2 Meeting"),
        FieldOption(value: "nova-2-phonecall", label: "Nova-2 Phonecall"),
    ]

    static let supportedLanguages = [
        "zh", "zh-CN", "zh-TW", "zh-HK",
        "en", "en-US", "en-GB",
        "ja", "ko", "multi",
    ]

    static var credentialFields: [CredentialField] {[
        CredentialField(key: "apiKey", label: L("API Key", "API Key"), placeholder: L("粘贴 API Key", "Paste your API Key"), isSecure: true, isOptional: false, defaultValue: ""),
        CredentialField(key: "baseURL", label: "Base URL", placeholder: defaultBaseURL, isSecure: false, isOptional: false, defaultValue: defaultBaseURL),
        CredentialField(key: "model", label: L("模型", "Model"), placeholder: defaultModel, isSecure: false, isOptional: false, defaultValue: defaultModel,
            options: modelOptions, allowCustomInput: true),
        CredentialField(key: "language", label: L("语言", "Language"), placeholder: defaultLanguage, isSecure: false, isOptional: false, defaultValue: defaultLanguage,
            options: supportedLanguages.map { FieldOption(value: $0, label: $0) }),
        CredentialField(key: "numerals", label: L("数字转换", "Numerals"), placeholder: "false", isSecure: false, isOptional: true, defaultValue: "false",
            options: [FieldOption(value: "true", label: L("开", "On")), FieldOption(value: "false", label: L("关", "Off"))]),
    ]}

    let apiKey: String
    let baseURL: String
    let model: String
    let language: String
    let numerals: Bool

    init?(credentials: [String: String]) {
        guard let apiKey = credentials["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else { return nil }

        let model = credentials["model"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = credentials["language"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.apiKey = apiKey
        let configuredBaseURL = credentials["baseURL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.baseURL = configuredBaseURL.isEmpty ? Self.defaultBaseURL : configuredBaseURL
        self.model = model?.isEmpty == false ? model! : Self.defaultModel
        self.language = language?.isEmpty == false ? language! : Self.defaultLanguage
        self.numerals = credentials["numerals"] == "true"
    }

    func toCredentials() -> [String: String] {
        [
            "apiKey": apiKey,
            "baseURL": baseURL,
            "model": model,
            "language": language,
            "numerals": numerals ? "true" : "false",
        ]
    }

    var isValid: Bool {
        !apiKey.isEmpty && !model.isEmpty && !language.isEmpty
    }
}
