import Foundation

enum BailianASRRegion: String, Sendable, CaseIterable {
    case china
    case international

    static let `default` = BailianASRRegion.china

    var displayName: String {
        switch self {
        case .china:
            return L("中国站（北京）", "China (Beijing)")
        case .international:
            return L("国际站（新加坡）", "International (Singapore)")
        }
    }

    var webSocketEndpoint: URL {
        switch self {
        case .china:
            return URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference")!
        case .international:
            return URL(string: "wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference")!
        }
    }

    var batchEndpoint: URL {
        switch self {
        case .china:
            return URL(string: "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")!
        case .international:
            return URL(string: "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")!
        }
    }
    var batchHost: String {
        switch self {
        case .china:
            return "dashscope.aliyuncs.com"
        case .international:
            return "dashscope-intl.aliyuncs.com"
        }
    }


    var healthEndpoint: String {
        switch self {
        case .china:
            return "https://dashscope.aliyuncs.com"
        case .international:
            return "https://dashscope-intl.aliyuncs.com"
        }
    }

    var modelsURL: URL {
        switch self {
        case .china:
            return URL(string: "https://help.aliyun.com/zh/model-studio/asr-model")!
        case .international:
            return URL(string: "https://www.alibabacloud.com/help/en/model-studio/asr-model")!
        }
    }

    var apiKeyURL: URL {
        switch self {
        case .china:
            return URL(string: "https://help.aliyun.com/zh/model-studio/get-api-key")!
        case .international:
            return URL(string: "https://www.alibabacloud.com/help/en/model-studio/get-api-key")!
        }
    }
}

struct BailianASRConfig: ASRRecognitionModeConfigurable, Sendable {
    static let provider = ASRProvider.bailian
    static let displayName = L("阿里云百炼", "Alibaba Cloud Bailian")
    static let defaultRegion = BailianASRRegion.default
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
            key: "region",
            label: L("API 站点", "API Site"),
            placeholder: "",
            isSecure: false,
            isOptional: false,
            defaultValue: defaultRegion.rawValue,
            options: BailianASRRegion.allCases.map {
                FieldOption(value: $0.rawValue, label: $0.displayName)
            }
        ),
        CredentialField(
            key: "apiKey",
            label: "API Key",
            placeholder: "sk-...",
            isSecure: true,
            isOptional: false,
            defaultValue: "",
            hint: L("阿里云百炼国内站 API Key", "Alibaba Cloud Bailian China API Key")
        ),
        CredentialField(
            key: "intlApiKey",
            label: "API Key",
            placeholder: "sk-...",
            isSecure: true,
            isOptional: false,
            defaultValue: "",
            hint: L("阿里云百炼国际站 API Key（新加坡）", "Alibaba Cloud Bailian International API Key (Singapore)")
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
            placeholder: L("可选，留空则根据所选站点自动使用官方接入点", "Optional, leave empty for site default"),
            isSecure: false,
            isOptional: true,
            defaultValue: ""
        ),
    ]}

    static func displayedCredentialFields(for values: [String: String]) -> [CredentialField] {
        let mode = ASRRecognitionMode(credentials: values)
        let region = BailianASRRegion(rawValue: values["region"] ?? "") ?? .default
        return credentialFields.filter { field in
            guard field.isVisible(in: mode) else { return false }
            switch field.key {
            case "apiKey":
                return region == .china
            case "intlApiKey":
                return region == .international
            default:
                return true
            }
        }
    }

    let recognitionMode: ASRRecognitionMode
    let region: BailianASRRegion
    let chinaApiKey: String
    let intlApiKey: String
    let model: String
    let batchModel: String
    let languageHint: String
    let vocabularyId: String
    let baseURL: String

    /// Active API key for the selected region.
    var apiKey: String {
        region == .international ? intlApiKey : chinaApiKey
    }

    init?(credentials: [String: String]) {
        let region = BailianASRRegion(rawValue: credentials["region"] ?? "") ?? Self.defaultRegion
        let chinaKey = Self.sanitized(credentials["apiKey"]) ?? ""
        let intlKey = Self.sanitized(credentials["intlApiKey"]) ?? ""

        let activeKey = region == .international ? intlKey : chinaKey
        guard !activeKey.isEmpty else { return nil }

        self.recognitionMode = ASRRecognitionMode(credentials: credentials)
        self.region = region
        self.chinaApiKey = chinaKey
        self.intlApiKey = intlKey
        self.model = Self.sanitized(credentials["model"]) ?? Self.defaultModel
        self.batchModel = Self.sanitized(credentials["batchModel"]) ?? Self.defaultBatchModel

        let rawLanguageHint = Self.sanitized(credentials["languageHint"])?.lowercased() ?? ""
        self.languageHint = Self.supportedLanguageHints.contains(rawLanguageHint) ? rawLanguageHint : ""
        self.vocabularyId = Self.sanitized(credentials["vocabularyId"]) ?? ""
        self.baseURL = Self.sanitized(credentials["baseURL"]) ?? ""
    }

    func toCredentials() -> [String: String] {
        var values = [
            ASRRecognitionMode.credentialKey: recognitionMode.rawValue,
            "region": region.rawValue,
            "model": model,
            "batchModel": batchModel,
            "languageHint": languageHint,
            "vocabularyId": vocabularyId,
            "baseURL": baseURL,
        ]
        if !chinaApiKey.isEmpty { values["apiKey"] = chinaApiKey }
        if !intlApiKey.isEmpty { values["intlApiKey"] = intlApiKey }
        return values
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
