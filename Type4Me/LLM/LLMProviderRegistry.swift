import Foundation

enum LLMProviderRegistry {

    static let all: [LLMProvider: any LLMProviderConfig.Type] = [
        .doubao:      OpenAICompatibleLLMConfig<DoubaoLLMTag>.self,
        .minimaxCN:   OpenAICompatibleLLMConfig<MinimaxCNLLMTag>.self,
        .minimaxIntl: OpenAICompatibleLLMConfig<MinimaxIntlLLMTag>.self,
        .bailian:     OpenAICompatibleLLMConfig<BailianLLMTag>.self,
        .kimi:        OpenAICompatibleLLMConfig<KimiLLMTag>.self,
        .openrouter:  OpenAICompatibleLLMConfig<OpenRouterLLMTag>.self,
        .requesty:    OpenAICompatibleLLMConfig<RequestyLLMTag>.self,
        .apiRoute:    OpenAICompatibleLLMConfig<APIRouteLLMTag>.self,
        .openai:      OpenAICompatibleLLMConfig<OpenAILLMTag>.self,
        .gemini:      OpenAICompatibleLLMConfig<GeminiLLMTag>.self,
        .deepseek:    OpenAICompatibleLLMConfig<DeepSeekLLMTag>.self,
        .zhipu:       OpenAICompatibleLLMConfig<ZhipuLLMTag>.self,
        .mimo:        OpenAICompatibleLLMConfig<MiMoLLMTag>.self,
        .claude:      ClaudeLLMConfig.self,
        .codexCLI:    CodexCLILLMConfig.self,
        .ollama:      OpenAICompatibleLLMConfig<OllamaLLMTag>.self,
        .custom:      OpenAICompatibleLLMConfig<CustomLLMTag>.self,
    ]

    static func configType(for provider: LLMProvider) -> (any LLMProviderConfig.Type)? {
        all[provider]
    }
}
