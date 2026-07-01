import Foundation

/// Common interface for LLM clients (OpenAI-compatible and Claude).
protocol LLMClient: AnyObject, Sendable {
    func process(text: String, prompt: String, config: LLMConfig) async throws -> String
    func processStreaming(
        text: String,
        prompt: String,
        config: LLMConfig,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String
    func warmUp(baseURL: String) async
    func invalidate() async
}

extension LLMClient {
    func processStreaming(
        text: String,
        prompt: String,
        config: LLMConfig,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let result = try await process(text: text, prompt: prompt, config: config)
        if !result.isEmpty {
            await onDelta(result)
        }
        return result
    }

    func invalidate() async {}
}

extension String {
    /// Remove `<think>...</think>` reasoning blocks emitted by models like DeepSeek.
    /// Handles both closed tags and unclosed/truncated tags.
    func strippingThinkTags() -> String {
        self
            .replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<think>[\\s\\S]*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
