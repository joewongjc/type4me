import SwiftUI

/// Defines the three primary views of the History & Analytics section.
public enum HistorySubtab: String, CaseIterable, Identifiable, Sendable {
    case transcripts
    case asrEngines
    case llmAnalytics

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .transcripts:  return L("听写记录", "Transcripts")
        case .asrEngines:   return L("语音引擎", "Speech Engines")
        case .llmAnalytics: return L("大模型用量", "LLM Analytics")
        }
    }

    public var icon: String {
        switch self {
        case .transcripts:  return "text.bubble"
        case .asrEngines:   return "waveform"
        case .llmAnalytics: return "sparkles"
        }
    }
}
