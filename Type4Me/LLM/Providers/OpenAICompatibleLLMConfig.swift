import Foundation

// MARK: - Tag Protocol

/// Each OpenAI-compatible provider gets a zero-cost tag type
/// so the generic `OpenAICompatibleLLMConfig<Tag>` can map to the right `LLMProvider`.
protocol OpenAICompatibleLLMTag: Sendable {
    static var provider: LLMProvider { get }
}

// MARK: - Tags

enum DoubaoLLMTag:      OpenAICompatibleLLMTag { static let provider = LLMProvider.doubao }
enum MinimaxCNLLMTag:   OpenAICompatibleLLMTag { static let provider = LLMProvider.minimaxCN }
enum MinimaxIntlLLMTag: OpenAICompatibleLLMTag { static let provider = LLMProvider.minimaxIntl }
enum BailianLLMTag:     OpenAICompatibleLLMTag { static let provider = LLMProvider.bailian }
enum KimiLLMTag:        OpenAICompatibleLLMTag { static let provider = LLMProvider.kimi }
enum OpenRouterLLMTag:  OpenAICompatibleLLMTag { static let provider = LLMProvider.openrouter }
enum RequestyLLMTag:    OpenAICompatibleLLMTag { static let provider = LLMProvider.requesty }
enum APIRouteLLMTag:    OpenAICompatibleLLMTag { static let provider = LLMProvider.apiRoute }
enum OpenAILLMTag:      OpenAICompatibleLLMTag { static let provider = LLMProvider.openai }
enum GeminiLLMTag:      OpenAICompatibleLLMTag { static let provider = LLMProvider.gemini }
enum DeepSeekLLMTag:    OpenAICompatibleLLMTag { static let provider = LLMProvider.deepseek }
enum ZhipuLLMTag:       OpenAICompatibleLLMTag { static let provider = LLMProvider.zhipu }
enum MiMoLLMTag:        OpenAICompatibleLLMTag { static let provider = LLMProvider.mimo }
enum OllamaLLMTag:      OpenAICompatibleLLMTag { static let provider = LLMProvider.ollama }
enum CustomLLMTag:      OpenAICompatibleLLMTag { static let provider = LLMProvider.custom }

// MARK: - Generic Config

struct OpenAICompatibleLLMConfig<Tag: OpenAICompatibleLLMTag>: LLMProviderConfig, Sendable {

    static var provider: LLMProvider { Tag.provider }

    static var credentialFields: [CredentialField] {
        let p = Tag.provider
        let models = p.modelOptions
        let baseURLPlaceholder: String = {
            if p == .custom {
                return L("https://your-api.com/v1", "https://your-api.com/v1")
            }
            return p.defaultBaseURL
        }()
        return [
            CredentialField(
                key: "apiKey", label: L("API Key", "API Key"),
                placeholder: p.requiresAPIKey ? "sk-..." : L("可选", "Optional"),
                isSecure: true, isOptional: !p.requiresAPIKey, defaultValue: ""
            ),
            CredentialField(
                key: "model", label: L("模型", "Model"),
                placeholder: L("模型名称或 endpoint ID", "Model name or endpoint ID"),
                isSecure: false, isOptional: p == .custom,
                defaultValue: models.first?.value ?? "",
                options: models, allowCustomInput: true
            ),
            CredentialField(
                key: "baseURL", label: L("Base URL", "Base URL"),
                placeholder: baseURLPlaceholder,
                isSecure: false, isOptional: true, defaultValue: p.defaultBaseURL
            ),
        ]
    }

    let apiKey: String
    let model: String
    let baseURL: String

    init?(credentials: [String: String]) {
        let key = credentials["apiKey"] ?? ""
        if Tag.provider.requiresAPIKey {
            guard !key.isEmpty else { return nil }
        }
        let model = credentials["model"] ?? ""
        if Tag.provider != .custom {
            guard !model.isEmpty else { return nil }
        }
        self.apiKey = key
        self.model = model
        let url = credentials["baseURL"]?.isEmpty == false
            ? credentials["baseURL"]!
            : Tag.provider.defaultBaseURL
        self.baseURL = url
    }

    func toCredentials() -> [String: String] {
        ["apiKey": apiKey, "model": model, "baseURL": baseURL]
    }

    func toLLMConfig() -> LLMConfig {
        LLMConfig(apiKey: apiKey, model: model, baseURL: baseURL)
    }
}
