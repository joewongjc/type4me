import Foundation

/// Defines caller metadata attached to an LLM invocation (e.g. mode, feature source).
public struct LLMInvocationContext: Sendable, Equatable {
    public let featureSource: LLMFeatureSource
    public let modeName: String?

    public init(featureSource: LLMFeatureSource, modeName: String? = nil) {
        self.featureSource = featureSource
        self.modeName = modeName
    }

    public static let dictationPolish = LLMInvocationContext(featureSource: .dictationPolish)
    public static func dictation(modeName: String) -> LLMInvocationContext {
        LLMInvocationContext(featureSource: .dictationPolish, modeName: modeName)
    }
}
