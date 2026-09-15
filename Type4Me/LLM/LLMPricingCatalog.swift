import Foundation

/// Compile-time seed pricing catalog (USD per 1M tokens).
/// Captured from OpenRouter's public Models API; the sync service refreshes
/// these values at runtime, so this table only needs to cover curated models
/// and legacy identifiers referenced by existing tests.
public enum LLMPricingCatalog {

    public static let seedEntries: [ModelPriceEntry] = [
        // OpenAI
        ModelPriceEntry(key: "gpt-5.6-luna", inputPricePerMTok: 0.20, outputPricePerMTok: 1.20),
        ModelPriceEntry(key: "gpt-5.6-sol", inputPricePerMTok: 2.00, outputPricePerMTok: 10.00),
        ModelPriceEntry(key: "gpt-5.6-terra", inputPricePerMTok: 2.00, outputPricePerMTok: 12.00),
        ModelPriceEntry(key: "gpt-5.5", inputPricePerMTok: 5.00, outputPricePerMTok: 30.00),
        ModelPriceEntry(key: "gpt-5.5-pro", inputPricePerMTok: 30.00, outputPricePerMTok: 180.00),
        ModelPriceEntry(key: "gpt-5.4", inputPricePerMTok: 2.50, outputPricePerMTok: 15.00),
        ModelPriceEntry(key: "gpt-5.4-mini", inputPricePerMTok: 0.75, outputPricePerMTok: 4.50),
        ModelPriceEntry(key: "gpt-5.4-nano", inputPricePerMTok: 0.20, outputPricePerMTok: 1.25),
        ModelPriceEntry(key: "gpt-5.4-pro", inputPricePerMTok: 30.00, outputPricePerMTok: 180.00),
        ModelPriceEntry(key: "gpt-4o", inputPricePerMTok: 2.50, outputPricePerMTok: 10.00),
        ModelPriceEntry(key: "gpt-4o-mini", inputPricePerMTok: 0.15, outputPricePerMTok: 0.60),
        // Anthropic
        ModelPriceEntry(key: "claude-sonnet-5", inputPricePerMTok: 2.00, outputPricePerMTok: 10.00),
        ModelPriceEntry(key: "claude-opus-5", inputPricePerMTok: 5.00, outputPricePerMTok: 25.00),
        ModelPriceEntry(key: "claude-fable-5", inputPricePerMTok: 10.00, outputPricePerMTok: 50.00),
        ModelPriceEntry(key: "claude-3-5-sonnet", inputPricePerMTok: 3.00, outputPricePerMTok: 15.00),
        ModelPriceEntry(key: "claude-3-5-haiku", inputPricePerMTok: 0.80, outputPricePerMTok: 4.00),
        // Zhipu GLM
        ModelPriceEntry(key: "glm-5.3", inputPricePerMTok: 1.40, outputPricePerMTok: 4.40),
        ModelPriceEntry(key: "glm-5.3-flash", inputPricePerMTok: 0.075, outputPricePerMTok: 0.25),
        ModelPriceEntry(key: "glm-5.2", inputPricePerMTok: 1.40, outputPricePerMTok: 4.40),
        ModelPriceEntry(key: "glm-5.1", inputPricePerMTok: 0.966, outputPricePerMTok: 3.036),
        ModelPriceEntry(key: "glm-5-turbo", inputPricePerMTok: 1.20, outputPricePerMTok: 4.00),
        // DeepSeek
        ModelPriceEntry(key: "deepseek-flash", inputPricePerMTok: 0.15, outputPricePerMTok: 0.60),
        ModelPriceEntry(key: "deepseek-v4.1-flash", inputPricePerMTok: 0.15, outputPricePerMTok: 0.60),
        ModelPriceEntry(key: "deepseek-v4-pro", inputPricePerMTok: 1.60, outputPricePerMTok: 3.20),
        ModelPriceEntry(key: "deepseek-v4-flash", inputPricePerMTok: 0.08708, outputPricePerMTok: 0.17416),
        ModelPriceEntry(key: "deepseek-chat", inputPricePerMTok: 0.14, outputPricePerMTok: 0.28),
        ModelPriceEntry(key: "deepseek-reasoner", inputPricePerMTok: 0.55, outputPricePerMTok: 2.19),
        // Moonshot Kimi
        ModelPriceEntry(key: "kimi-k2.7-code", inputPricePerMTok: 0.71, outputPricePerMTok: 3.50),
        ModelPriceEntry(key: "kimi-k2.6", inputPricePerMTok: 0.95, outputPricePerMTok: 4.00),
        ModelPriceEntry(key: "kimi-k2.5", inputPricePerMTok: 0.45, outputPricePerMTok: 2.25),
        // Alibaba Qwen
        ModelPriceEntry(key: "qwen3.7-max", inputPricePerMTok: 1.475, outputPricePerMTok: 4.425),
        ModelPriceEntry(key: "qwen3.7-plus", inputPricePerMTok: 0.32, outputPricePerMTok: 1.28),
        ModelPriceEntry(key: "qwen3.7-flash", inputPricePerMTok: 0.03, outputPricePerMTok: 0.13),
        ModelPriceEntry(key: "minimax-m3", inputPricePerMTok: 0.30, outputPricePerMTok: 1.20),
        // Google Gemini
        ModelPriceEntry(key: "gemini-3.7-flash", inputPricePerMTok: 0.75, outputPricePerMTok: 3.75),
        ModelPriceEntry(key: "gemini-3.5-flash", inputPricePerMTok: 1.50, outputPricePerMTok: 9.00),
        ModelPriceEntry(key: "gemini-3.5-flash-lite", inputPricePerMTok: 0.30, outputPricePerMTok: 2.50),
        // ByteDance Doubao Seed (normalized keys, prefix stripped)
        ModelPriceEntry(key: "seed-2-1-turbo", inputPricePerMTok: 0.50, outputPricePerMTok: 2.50),
        ModelPriceEntry(key: "seed-2.0-code", inputPricePerMTok: 0.50, outputPricePerMTok: 3.00),
        ModelPriceEntry(key: "seed-2.0-lite", inputPricePerMTok: 0.25, outputPricePerMTok: 2.00),
        ModelPriceEntry(key: "seed-2.0-mini", inputPricePerMTok: 0.10, outputPricePerMTok: 0.40),
    ]
}
