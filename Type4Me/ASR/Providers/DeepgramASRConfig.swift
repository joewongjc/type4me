import Foundation

struct DeepgramASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.deepgram
    static let displayName = "Deepgram"
    static let defaultModel = "nova-3"
    static let defaultLanguage = "zh"

    static let supportedModels = [
        "nova-3",
        "nova-2",
        "nova-2-general",
        "nova-2-meeting",
        "nova-2-phonecall",
    ]

    static let supportedLanguages = [
        "zh", "zh-CN", "zh-TW", "zh-HK",
        "en", "en-US", "en-GB",
        "ja", "ko", "multi",
    ]

    static var credentialFields: [CredentialField] {[
        CredentialField(key: "apiKey", label: "API Key", placeholder: L("粘贴 API Key", "Paste your API Key"), isSecure: true, isOptional: false, defaultValue: ""),
        CredentialField(key: "model", label: "Model", placeholder: defaultModel, isSecure: false, isOptional: false, defaultValue: defaultModel,
            options: supportedModels.map { FieldOption(value: $0, label: $0) }),
        CredentialField(key: "language", label: "Language", placeholder: defaultLanguage, isSecure: false, isOptional: false, defaultValue: defaultLanguage,
            options: supportedLanguages.map { FieldOption(value: $0, label: $0) }),
        CredentialField(key: "numerals", label: L("数字转换", "Numerals"), placeholder: "false", isSecure: false, isOptional: true, defaultValue: "false",
            options: [FieldOption(value: "true", label: "On"), FieldOption(value: "false", label: "Off")]),
        CredentialField(key: "hotwords", label: L("热词", "Hotwords"), placeholder: L("word1, word2（逗号分隔）", "word1, word2 — comma separated"), isSecure: false, isOptional: true, defaultValue: "", isTextArea: true,
            note: L("受接口限制，热词仅取前 30 个", "Due to API limits, only the first 30 hotwords are used"),
            wordLimit: 30),
    ]}

    let apiKey: String
    let model: String
    let language: String
    let numerals: Bool
    let hotwords: [String]

    init?(credentials: [String: String]) {
        guard let apiKey = credentials["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else { return nil }

        let model = credentials["model"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = credentials["language"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.apiKey = apiKey
        self.model = model?.isEmpty == false ? model! : Self.defaultModel
        self.language = language?.isEmpty == false ? language! : Self.defaultLanguage
        self.numerals = credentials["numerals"] == "true"
        self.hotwords = (credentials["hotwords"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func toCredentials() -> [String: String] {
        [
            "apiKey": apiKey,
            "model": model,
            "language": language,
            "numerals": numerals ? "true" : "false",
            "hotwords": hotwords.joined(separator: ", "),
        ]
    }

    var isValid: Bool {
        !apiKey.isEmpty && !model.isEmpty && !language.isEmpty
    }
}
