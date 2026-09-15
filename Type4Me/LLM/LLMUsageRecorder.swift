import Foundation

/// A thread-safe / task-local recorder to easily capture LLM usage across the app.
public enum LLMUsageRecorder {

    /// Records an invocation with explicit token counts or heuristics fallback.
    public static func record(
        featureSource: LLMFeatureSource,
        provider: String,
        model: String,
        promptText: String,
        completionText: String,
        durationSeconds: Double,
        metrics: LLMExecutionMetrics? = nil,
        status: String = "success",
        modeName: String? = nil
    ) {
        let isEstimated: Bool
        let promptTokens: Int
        let completionTokens: Int

        if let p = metrics?.promptTokens, let c = metrics?.completionTokens {
            promptTokens = p
            completionTokens = c
            isEstimated = metrics?.isEstimated ?? false
        } else {
            // Heuristic fallback: ~0.7 tokens/char for CJK, ~1.3 tokens/word for English
            promptTokens = estimateTokens(for: promptText)
            completionTokens = estimateTokens(for: completionText)
            isEstimated = true
        }

        let costUSD = LLMPricingRegistry.calculateCostUSD(
            model: model,
            provider: provider,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )

        let record = LLMUsageRecord(
            featureSource: featureSource,
            provider: provider,
            model: model,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: promptTokens + completionTokens,
            durationSeconds: durationSeconds,
            costUSD: costUSD,
            status: status,
            isEstimated: isEstimated,
            modeName: modeName
        )

        Task {
            await HistoryStore.shared.insertLLMUsage(record)
        }
    }

    /// Fast heuristics to estimate token count from raw text.
    public static func estimateTokens(for text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        // Rough estimation: count CJK characters vs ASCII words
        var cjkCount = 0
        var asciiCount = 0

        for scalar in trimmed.unicodeScalars {
            // CJK Unified Ideographs block
            if (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF) ||
               (scalar.value >= 0x3400 && scalar.value <= 0x4DBF) ||
               (scalar.value >= 0x20000 && scalar.value <= 0x2A6DF) {
                cjkCount += 1
            } else {
                asciiCount += 1
            }
        }

        let cjkTokens = Double(cjkCount) * 0.7
        let asciiTokens = Double(asciiCount) / 4.0 // ~4 chars per token in English

        return max(1, Int(ceil(cjkTokens + asciiTokens)))
    }
}
