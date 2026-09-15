import Foundation

/// Defines the functional feature originating the LLM call for usage analytics.
public enum LLMFeatureSource: String, Sendable, CaseIterable, Identifiable {
    case dictationPolish = "dictation_polish"   // 语音听写智能润色 (Intelli Sense)
    case voiceRevise     = "voice_revise"       // 局部改写 (Voice Revise)
    case askAnything     = "ask_anything"       // 随手问 (Ask Anything)
    case vocabSuggestion = "vocab_suggestion"   // 词库建议与纠错变体生成
    case macAction       = "mac_action"         // Mac Action 工具调用
    case batchCorrection = "batch_correction"   // 后台静默纠错
    case other           = "other"

    public var id: String { rawValue }

    public var localizedDisplayName: String {
        switch self {
        case .dictationPolish: return L("语音润色", "Dictation Polish")
        case .voiceRevise:     return L("局部改写", "Voice Revise")
        case .askAnything:     return L("随手问", "Ask Anything")
        case .vocabSuggestion: return L("词库建议", "Vocabulary Suggestion")
        case .macAction:       return L("系统操作", "Mac Action")
        case .batchCorrection: return L("批量纠错", "Batch Correction")
        case .other:           return L("其他", "Other")
        }
    }
}

/// Represents a single recorded LLM invocation with its token consumption and cost.
public struct LLMUsageRecord: Identifiable, Sendable, Equatable {
    public let id: String
    public let createdAt: Date
    public let featureSource: LLMFeatureSource
    public let provider: String
    public let model: String
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int
    public let durationSeconds: Double
    public let costUSD: Double
    public let status: String
    public let isEstimated: Bool
    public let modeName: String?

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        featureSource: LLMFeatureSource,
        provider: String,
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int? = nil,
        durationSeconds: Double,
        costUSD: Double,
        status: String = "success",
        isEstimated: Bool = false,
        modeName: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.featureSource = featureSource
        self.provider = provider
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens ?? (promptTokens + completionTokens)
        self.durationSeconds = durationSeconds
        self.costUSD = costUSD
        self.status = status
        self.isEstimated = isEstimated
        self.modeName = modeName
    }
}
