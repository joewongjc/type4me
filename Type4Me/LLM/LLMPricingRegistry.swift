import Foundation

/// Price rate per 1 Million Tokens in USD.
public struct ModelPriceRate: Sendable, Equatable {
    public let inputPricePerMTok: Double
    public let outputPricePerMTok: Double
    public let isFree: Bool

    public init(inputPricePerMTok: Double, outputPricePerMTok: Double, isFree: Bool = false) {
        self.inputPricePerMTok = inputPricePerMTok
        self.outputPricePerMTok = outputPricePerMTok
        self.isFree = isFree
    }
}

/// Central registry of pricing rates for mainstream LLM providers and models.
public enum LLMPricingRegistry {
    /// Fixed reference exchange rate for displaying CNY equivalence.
    public static let usdToCnyRate: Double = 7.20

    /// Matches provider and model string to its corresponding price rate.
    public static func rate(for model: String, provider: String) -> ModelPriceRate {
        let lowerModel = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerProvider = provider.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Local models / open-source engines are completely free
        if lowerProvider == "ollama" || lowerProvider == "mlx" || lowerProvider == "local" ||
           lowerModel.contains("local") || lowerModel.contains("ollama") || lowerModel.contains("mlx") {
            return ModelPriceRate(inputPricePerMTok: 0, outputPricePerMTok: 0, isFree: true)
        }

        // 2. DeepSeek series
        if lowerModel.contains("deepseek-reasoner") || lowerModel.contains("deepseek-r1") {
            return ModelPriceRate(inputPricePerMTok: 0.55, outputPricePerMTok: 2.19, isFree: false)
        }
        if lowerModel.contains("deepseek-chat") || lowerModel.contains("deepseek-v3") || lowerModel.contains("deepseek") {
            return ModelPriceRate(inputPricePerMTok: 0.14, outputPricePerMTok: 0.28, isFree: false)
        }

        // 3. Claude series (Anthropic)
        if lowerModel.contains("claude-3-5-sonnet") || lowerModel.contains("claude-3.5-sonnet") ||
           lowerModel.contains("claude-3-7-sonnet") || lowerModel.contains("claude-3.7-sonnet") {
            return ModelPriceRate(inputPricePerMTok: 3.00, outputPricePerMTok: 15.00, isFree: false)
        }
        if lowerModel.contains("claude-3-5-haiku") || lowerModel.contains("claude-3.5-haiku") {
            return ModelPriceRate(inputPricePerMTok: 0.80, outputPricePerMTok: 4.00, isFree: false)
        }
        if lowerModel.contains("claude-3-haiku") {
            return ModelPriceRate(inputPricePerMTok: 0.25, outputPricePerMTok: 1.25, isFree: false)
        }

        // 4. OpenAI series
        if lowerModel.contains("gpt-4o-mini") {
            return ModelPriceRate(inputPricePerMTok: 0.15, outputPricePerMTok: 0.60, isFree: false)
        }
        if lowerModel.contains("gpt-4o") {
            return ModelPriceRate(inputPricePerMTok: 2.50, outputPricePerMTok: 10.00, isFree: false)
        }
        if lowerModel.contains("o3-mini") {
            return ModelPriceRate(inputPricePerMTok: 1.10, outputPricePerMTok: 4.40, isFree: false)
        }
        if lowerModel.contains("o1") {
            return ModelPriceRate(inputPricePerMTok: 15.00, outputPricePerMTok: 60.00, isFree: false)
        }

        // 5. Doubao / Volcano Engine Ark (Converted to USD equivalents)
        // doubao-seed, doubao-lite, doubao-pro, etc.
        if lowerModel.contains("doubao-seed") || lowerModel.contains("doubao-lite") {
            return ModelPriceRate(inputPricePerMTok: 0.04, outputPricePerMTok: 0.08, isFree: false)
        }
        if lowerModel.contains("doubao-pro") || lowerModel.contains("doubao") {
            return ModelPriceRate(inputPricePerMTok: 0.12, outputPricePerMTok: 0.28, isFree: false)
        }

        // 6. Default / Unmatched custom model
        return ModelPriceRate(inputPricePerMTok: 0, outputPricePerMTok: 0, isFree: false)
    }

    /// Calculates total USD cost for a given model and token count.
    public static func calculateCostUSD(
        model: String,
        provider: String,
        promptTokens: Int,
        completionTokens: Int
    ) -> Double {
        let price = rate(for: model, provider: provider)
        guard !price.isFree else { return 0.0 }
        let inputCost = (Double(max(0, promptTokens)) / 1_000_000.0) * price.inputPricePerMTok
        let outputCost = (Double(max(0, completionTokens)) / 1_000_000.0) * price.outputPricePerMTok
        return inputCost + outputCost
    }
}
