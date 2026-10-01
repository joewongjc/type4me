import Foundation

// MARK: - Provider Enum

enum LLMProvider: String, CaseIterable, Codable, Sendable {
    case doubao
    case minimaxCN
    case minimaxIntl
    case bailian
    case kimi
    case openrouter
    case openai
    case gemini
    case deepseek
    case zhipu
    case mimo
    case claude
    case codexCLI
    case ollama
    case custom

    var displayName: String {
        switch self {
        case .doubao:      return L("豆包 (ByteDance ARK)", "Doubao (ByteDance ARK)")
        case .minimaxCN:   return L("MiniMax 国内", "MiniMax China")
        case .minimaxIntl: return L("MiniMax 海外", "MiniMax Global")
        case .bailian:     return L("百炼 (阿里云)", "Bailian (Alibaba Cloud)")
        case .kimi:        return L("Kimi (月之暗面)", "Kimi (Moonshot)")
        case .openrouter:  return "OpenRouter"
        case .openai:      return "OpenAI"
        case .gemini:      return "Gemini (Google)"
        case .deepseek:    return L("DeepSeek (深度求索)", "DeepSeek")
        case .zhipu:       return L("智谱 (GLM)", "Zhipu (GLM)")
        case .mimo:        return L("小米 MiMo", "Xiaomi MiMo")
        case .claude:      return "Claude (Anthropic)"
        case .codexCLI:    return L("Codex CLI（本地账号）", "Codex CLI (Local Account)")
        case .ollama:      return L("Ollama (本地模型)", "Ollama (Local)")
        case .custom:      return L("自定义 (OpenAI 兼容)", "Custom (OpenAI Compatible)")
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .doubao:      return "https://ark.cn-beijing.volces.com/api/v3"
        case .minimaxCN:   return "https://api.minimaxi.com/v1"
        case .minimaxIntl: return "https://api.minimax.io/v1"
        case .bailian:     return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .kimi:        return "https://api.moonshot.ai/v1"
        case .openrouter:  return "https://openrouter.ai/api/v1"
        case .openai:      return "https://api.openai.com/v1"
        case .gemini:      return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepseek:    return "https://api.deepseek.com"
        case .zhipu:       return "https://open.bigmodel.cn/api/paas/v4"
        case .mimo:        return "https://api.xiaomimimo.com/v1"
        case .claude:      return "https://api.anthropic.com/v1"
        case .codexCLI:    return ""
        case .ollama:      return "http://localhost:11434/v1"
        case .custom:      return ""
        }
    }

    // MARK: - Model Options

    /// Popular models for this provider, shown as dropdown options in settings.
    var modelOptions: [FieldOption] {
        switch self {
        case .doubao:
            return [
                FieldOption(value: "doubao-seed-2-1-turbo-260628", label: "doubao-seed-2-1-turbo-260628"),
                FieldOption(value: "doubao-seed-2-1-pro-260628", label: "doubao-seed-2-1-pro-260628"),
                FieldOption(value: "doubao-seed-2-0-lite-260428", label: "doubao-seed-2-0-lite-260428"),
                FieldOption(value: "doubao-seed-2-0-mini-260428", label: "doubao-seed-2-0-mini-260428"),
                FieldOption(value: "doubao-seed-2-0-pro-260215", label: "doubao-seed-2-0-pro-260215"),
            ]
        case .minimaxCN, .minimaxIntl:
            return [
                FieldOption(value: "MiniMax-M3", label: "MiniMax-M3"),
                FieldOption(value: "MiniMax-M2.7", label: "MiniMax-M2.7"),
                FieldOption(value: "MiniMax-M2.7-highspeed", label: "MiniMax-M2.7-highspeed"),
                FieldOption(value: "MiniMax-M2.5", label: "MiniMax-M2.5"),
                FieldOption(value: "MiniMax-M2.5-highspeed", label: "MiniMax-M2.5-highspeed"),
                FieldOption(value: "MiniMax-M2.1", label: "MiniMax-M2.1"),
                FieldOption(value: "MiniMax-M2.1-highspeed", label: "MiniMax-M2.1-highspeed"),
                FieldOption(value: "MiniMax-M2", label: "MiniMax-M2"),
            ]
        case .bailian:
            return [
                FieldOption(value: "qwen3.7-plus", label: "qwen3.7-plus"),
                FieldOption(value: "qwen3.7-max", label: "qwen3.7-max"),
                FieldOption(value: "qwen3.6-flash", label: "qwen3.6-flash"),
                FieldOption(value: "qwen-plus", label: "qwen-plus"),
                FieldOption(value: "qwen-turbo", label: "qwen-turbo"),
                FieldOption(value: "qwen-long", label: "qwen-long"),
            ]
        case .kimi:
            return [
                FieldOption(value: "kimi-k2.6", label: "kimi-k2.6"),
                FieldOption(value: "kimi-k2.7-code-highspeed", label: "kimi-k2.7-code-highspeed"),
                FieldOption(value: "kimi-k2.7-code", label: "kimi-k2.7-code"),
                FieldOption(value: "kimi-k2.5", label: "kimi-k2.5"),
                FieldOption(value: "moonshot-v1-128k", label: "moonshot-v1-128k"),
                FieldOption(value: "moonshot-v1-32k", label: "moonshot-v1-32k"),
                FieldOption(value: "moonshot-v1-8k", label: "moonshot-v1-8k"),
            ]
        case .openai:
            return [
                FieldOption(value: "gpt-5.4-mini", label: "gpt-5.4-mini"),
                FieldOption(value: "gpt-5.5", label: "gpt-5.5"),
                FieldOption(value: "gpt-5.5-pro", label: "gpt-5.5-pro"),
                FieldOption(value: "gpt-5.4", label: "gpt-5.4"),
                FieldOption(value: "gpt-5.4-pro", label: "gpt-5.4-pro"),
                FieldOption(value: "gpt-5.4-nano", label: "gpt-5.4-nano"),
            ]
        case .gemini:
            return [
                FieldOption(value: "gemini-3.5-flash", label: "gemini-3.5-flash"),
                FieldOption(value: "gemini-3.1-flash-lite", label: "gemini-3.1-flash-lite"),
                FieldOption(value: "gemini-3.1-pro-preview", label: "gemini-3.1-pro-preview"),
                FieldOption(value: "gemini-3-flash-preview", label: "gemini-3-flash-preview"),
                FieldOption(value: "gemini-2.5-flash", label: "gemini-2.5-flash"),
                FieldOption(value: "gemini-2.5-pro", label: "gemini-2.5-pro"),
                FieldOption(value: "gemini-2.5-flash-lite", label: "gemini-2.5-flash-lite"),
            ]
        case .deepseek:
            return [
                FieldOption(value: "deepseek-v4-flash", label: "deepseek-v4-flash"),
                FieldOption(value: "deepseek-v4-pro", label: "deepseek-v4-pro"),
            ]
        case .zhipu:
            return [
                FieldOption(value: "glm-5.2", label: "glm-5.2"),
                FieldOption(value: "glm-5.1", label: "glm-5.1"),
                FieldOption(value: "glm-5", label: "glm-5"),
                FieldOption(value: "glm-5-turbo", label: "glm-5-turbo"),
                FieldOption(value: "glm-4.7", label: "glm-4.7"),
                FieldOption(value: "glm-4.7-flashx", label: "glm-4.7-flashx"),
                FieldOption(value: "glm-4.7-flash", label: "glm-4.7-flash"),
                FieldOption(value: "glm-4.5-air", label: "glm-4.5-air"),
                FieldOption(value: "glm-4.5-airx", label: "glm-4.5-airx"),
                FieldOption(value: "glm-4-long", label: "glm-4-long"),
            ]
        case .mimo:
            return [
                FieldOption(value: "mimo-v2.6-flash", label: "mimo-v2.6-flash"),
                FieldOption(value: "mimo-v2.6-pro", label: "mimo-v2.6-pro"),
                FieldOption(value: "mimo-v2.6-pro-ultraspeed", label: "mimo-v2.6-pro-ultraspeed"),
                FieldOption(value: "mimo-v2.5-pro", label: "mimo-v2.5-pro"),
            ]
        case .claude:
            return [
                FieldOption(value: "claude-sonnet-5", label: "claude-sonnet-5"),
                FieldOption(value: "claude-fable-5", label: "claude-fable-5"),
                FieldOption(value: "claude-opus-4-8", label: "claude-opus-4-8"),
                FieldOption(value: "claude-haiku-4-5-20251001", label: "claude-haiku-4-5-20251001"),
            ]
        case .codexCLI:
            return [
                FieldOption(value: "gpt-5.6-luna", label: L("GPT-5.6 Luna（推荐）", "GPT-5.6 Luna (Recommended)")),
                FieldOption(value: "gpt-5.3-codex-spark", label: L("GPT-5.3 Codex Spark（极速实验）", "GPT-5.3 Codex Spark (Fast, Experimental)")),
            ]
        case .openrouter, .ollama, .custom:
            return []
        }
    }

    var isOpenAICompatible: Bool {
        self != .claude && self != .codexCLI
    }

    /// Whether this is a local provider bundled with the app (no external service).
    var isLocal: Bool {
        self == .ollama
    }

    /// Whether this provider requires an API key for authentication.
    var requiresAPIKey: Bool {
        self != .ollama && self != .codexCLI
    }


    /// Thinking/reasoning disable strategy for this provider.
    /// Each provider uses a different field name to turn off chain-of-thought.
    /// Returns nil for providers where no explicit disable is needed or possible.
    var thinkingDisableField: ThinkingDisableField? {
        thinkingDisableField(for: nil)
    }

    func thinkingDisableField(for model: String?) -> ThinkingDisableField? {
        switch self {
        case .doubao, .deepseek, .mimo:
            // thinking: { type: "disabled" }
            return .thinking
        case .kimi:
            let normalizedModel = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedModel.hasPrefix("kimi-k2.7-code") {
                return nil
            }
            // thinking: { type: "disabled" }
            return .thinking
        case .bailian:
            // enable_thinking: false (Qwen models)
            return .enableThinking
        case .zhipu:
            // thinking: { type: "disabled" } (GLM-5.x / GLM-4.7)
            return .thinking
        case .openrouter:
            // reasoning: { effort: "none" }
            return .reasoning
        case .ollama:
            // think: false
            return .think
        default:
            // OpenAI: defaults to none already for GPT-5.2+, risky for o3
            // Gemini: OpenAI-compat layer doesn't reliably support it
            // MiniMax: API doesn't support disabling reasoning (use needsReasoningSplit instead)
            return nil
        }
    }

    /// MiniMax M2+ models always reason and can't be turned off.
    /// reasoning_split=true separates thinking into reasoning_details field,
    /// keeping it out of delta.content so our SSE parser won't pick it up.
    var needsReasoningSplit: Bool {
        self == .minimaxCN || self == .minimaxIntl
    }
}

// MARK: - Thinking Disable Strategy

enum ThinkingDisableField: Equatable {
    /// `thinking: { type: "disabled" }` — Doubao, Kimi, DeepSeek, Zhipu
    case thinking
    /// `enable_thinking: false` — Bailian (Qwen)
    case enableThinking
    /// `reasoning_effort: "none"` — providers that still expose OpenAI-style effort control
    case reasoningEffort
    /// `reasoning: { effort: "none" }` — OpenRouter's unified reasoning control
    case reasoning
    /// `think: false` — Ollama
    case think
}

// MARK: - Thinking Preference

enum LLMThinkingPreference {
    private static let sharedKey = "tf_disableThinking"
    private static let openRouterKey = "tf_disableThinking_openrouter"

    /// OpenRouter fronts models with different reasoning requirements, including
    /// models where reasoning is mandatory. Keep its default provider-controlled
    /// until the user explicitly opts out, while preserving the existing default
    /// for direct providers.
    static func isDisabled(
        for provider: LLMProvider,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let key = provider == .openrouter ? openRouterKey : sharedKey
        guard let value = defaults.object(forKey: key) as? Bool else {
            return provider != .openrouter
        }
        return value
    }

    static func setDisabled(
        _ disabled: Bool,
        for provider: LLMProvider,
        defaults: UserDefaults = .standard
    ) {
        let key = provider == .openrouter ? openRouterKey : sharedKey
        defaults.set(disabled, forKey: key)
    }
}

// MARK: - Provider Config Protocol

protocol LLMProviderConfig: Sendable {
    static var provider: LLMProvider { get }
    static var credentialFields: [CredentialField] { get }

    init?(credentials: [String: String])
    func toCredentials() -> [String: String]
    func toLLMConfig() -> LLMConfig
}
