import Foundation

/// Execution metrics captured during an LLM invocation.
public struct LLMExecutionMetrics: Sendable, Equatable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let durationSeconds: Double
    public let isEstimated: Bool

    public init(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        durationSeconds: Double = 0,
        isEstimated: Bool = false
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.durationSeconds = durationSeconds
        self.isEstimated = isEstimated
    }
}
