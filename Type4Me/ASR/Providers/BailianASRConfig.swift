import Foundation

struct BailianASRConfig: ASRRecognitionModeConfigurable, Sendable {

    static let provider = ASRProvider.bailian
    static let displayName = L("阿里云百炼", "Alibaba Cloud Bailian")
    static let defaultModel = "qwen-audio-3.1-asr-flash-streaming"
    static let supportedModels = [
        "qwen-audio-3.1-asr-flash-streaming",
        "qwen-audio-3.0-asr-flash-streaming",
        "fun-asr-realtime",
        "fun-asr-flash-8k-realtime",
    ]
    static let defaultBatchModel = "qwen-audio-3.1-asr-flash"
    static let supportedBatchModels = [
        "qwen-audio-3.1-asr-flash",
    ]
    static let supportedLanguageHints = [
        "zh", "en", "ja", "ko",
        "fr", "de", "es", "ru", "it",
        "pt", "ar", "th", "vi", "id",
    ]

    static var credentialFields: [CredentialField] {[
        ASRRecognitionMode.credentialField,
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
            allowCustomInput: true,
            visibleModes: [.streaming]
        ),
        CredentialField(
            key: "batchModel",
            label: L("模型", "Model"),
            placeholder: defaultBatchModel,
            isSecure: false,
            isOptional: false,
            defaultValue: defaultBatchModel,
            options: supportedBatchModels.map { FieldOption(value: $0, label: $0) },
            allowCustomInput: true,
            visibleModes: [.batch]
        ),
        CredentialField(
            key: "languageHint",
            label: L("语言提示", "Language Hint"),
            placeholder: "zh / en / ja / ko ...",
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

    let recognitionMode: ASRRecognitionMode
    let apiKey: String
    let model: String
    let batchModel: String
    let languageHint: String
    let vocabularyId: String
    let baseURL: String

    init?(credentials: [String: String]) {
        guard let apiKey = Self.sanitized(credentials["apiKey"]),
              !apiKey.isEmpty
        else { return nil }

        self.recognitionMode = ASRRecognitionMode(credentials: credentials)
        self.apiKey = apiKey
        self.model = Self.sanitized(credentials["model"]) ?? Self.defaultModel
        self.batchModel = Self.sanitized(credentials["batchModel"]) ?? Self.defaultBatchModel

        let rawLanguageHint = Self.sanitized(credentials["languageHint"])?.lowercased() ?? ""
        self.languageHint = Self.supportedLanguageHints.contains(rawLanguageHint) ? rawLanguageHint : ""
        self.vocabularyId = Self.sanitized(credentials["vocabularyId"]) ?? ""
        self.baseURL = Self.sanitized(credentials["baseURL"]) ?? ""
    }

    func toCredentials() -> [String: String] {
        [
            ASRRecognitionMode.credentialKey: recognitionMode.rawValue,
            "apiKey": apiKey,
            "model": model,
            "batchModel": batchModel,
            "languageHint": languageHint,
            "vocabularyId": vocabularyId,
            "baseURL": baseURL,
        ]
    }

    var isValid: Bool {
        !apiKey.isEmpty && !(recognitionMode == .batch ? batchModel : model).isEmpty
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
