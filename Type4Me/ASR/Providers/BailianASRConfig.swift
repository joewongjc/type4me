import Foundation

struct BailianASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.bailian
    static let displayName = L("阿里云百炼", "Alibaba Cloud Bailian")
    static let defaultModel = "qwen-audio-3.1-asr-flash-streaming"
    static let supportedModels = [
        "qwen-audio-3.1-asr-flash-streaming",
        "qwen-audio-3.0-asr-flash-streaming",
        "qwen3-asr-flash-realtime",
        "fun-asr-realtime",
        "fun-asr-flash-8k-realtime",
    ]
    static let supportedLanguageHints = [
        "zh", "en", "ja", "ko", "yue",
        "fr", "de", "es", "ru", "it",
        "pt", "ar", "th", "vi", "id",
    ]

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "apiKey",
            label: L("API Key", "API Key"),
            placeholder: "sk-...",
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "model",
            label: L("模型", "Model"),
            placeholder: defaultModel,
            isSecure: false,
            isOptional: false,
            defaultValue: defaultModel,
            options: supportedModels.map { FieldOption(value: $0, label: $0) },
            allowCustomInput: true
        ),
        CredentialField(
            key: "languageHint",
            label: L("语言提示", "Language Hint"),
            placeholder: "zh / en / ja / ko / yue ...",
            isSecure: false,
            isOptional: true,
            defaultValue: ""
        ),
        CredentialField(
            key: "vocabularyId",
            label: L("热词词表 ID", "Vocabulary ID"),
            placeholder: L("热词词表 ID", "Hotword vocabulary ID"),
            isSecure: false,
            isOptional: true,
            defaultValue: ""
        ),
        CredentialField(
            key: "baseURL",
            label: L("Base URL", "Base URL"),
            placeholder: "wss://dashscope.aliyuncs.com/api-ws/v1/inference",
            isSecure: false,
            isOptional: true,
            defaultValue: ""
        ),
    ]}

    let apiKey: String
    let model: String
    let languageHint: String
    let vocabularyId: String
    let baseURL: String

    init?(credentials: [String: String]) {
        guard let apiKey = Self.sanitized(credentials["apiKey"]),
              !apiKey.isEmpty
        else { return nil }

        self.apiKey = apiKey
        self.model = Self.sanitized(credentials["model"]) ?? Self.defaultModel

        self.languageHint = Self.sanitized(credentials["languageHint"])?.lowercased() ?? ""
        self.vocabularyId = Self.sanitized(credentials["vocabularyId"]) ?? ""
        self.baseURL = Self.sanitized(credentials["baseURL"]) ?? ""
    }

    func toCredentials() -> [String: String] {
        [
            "apiKey": apiKey,
            "model": model,
            "languageHint": languageHint,
            "vocabularyId": vocabularyId,
            "baseURL": baseURL,
        ]
    }

    var isValid: Bool {
        !apiKey.isEmpty && !model.isEmpty
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
