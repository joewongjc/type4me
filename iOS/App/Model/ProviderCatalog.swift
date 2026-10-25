import Foundation
import Type4MeTransferCore

/// What the iPhone needs to set up a text model by hand, read from the Mac's
/// own `LLMProvider` (compiled from the Mac sources): the same base URLs,
/// suggested models and thinking switch, so a service entered here behaves
/// like one exported from the Mac.
struct LLMProviderPreset: Identifiable, Hashable {
    let provider: LLMProvider

    var id: String { provider.rawValue }
    var name: String { provider.displayName }
    var baseURL: String { provider.defaultBaseURL }
    var models: [String] { provider.modelOptions.map(\.value) }
    var reasoningSplit: Bool { provider.needsReasoningSplit }
    var isCustom: Bool { provider == .custom }
    /// Anthropic's Messages API instead of OpenAI's chat completions.
    var usesMessagesAPI: Bool { !provider.isOpenAICompatible }

    /// Recommended first, in the Mac's order, then the rest by name with Custom last.
    static let all: [LLMProviderPreset] = {
        let cloud = Type4MeTransferSupport.llmProviders.compactMap(LLMProvider.init(rawValue:))
        let recommended: [LLMProvider] = [.bailian, .doubao, .deepseek, .kimi, .openai, .gemini]
        let rest = cloud.filter { !recommended.contains($0) && $0 != .custom }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return (recommended.filter(cloud.contains) + rest + [.custom]).map(LLMProviderPreset.init(provider:))
    }()

    static func preset(for id: String) -> LLMProviderPreset {
        all.first { $0.id == id } ?? all.last!
    }

    /// Request field that turns thinking off (`LLMHint.thinkingOff`). Like the
    /// Mac default, thinking is off for every provider except OpenRouter.
    func thinkingOff(for model: String) -> String? {
        guard provider != .openrouter else { return nil }
        switch provider.thinkingDisableField(for: model) {
        case .thinking: return "thinking"
        case .enableThinking: return "enableThinking"
        case .reasoningEffort: return "reasoningEffort"
        case .reasoning: return "reasoning"
        case .think, .lowestReasoningEffort, nil: return nil
        }
    }

    func endpoint(apiKey: String, model: String, baseURL: String) -> Type4MeTransferPayload.Endpoint {
        var fields = [
            "apiKey": apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines),
            "baseURL": baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        if let hint = thinkingOff(for: fields["model"] ?? "") {
            fields[Type4MeTransferSupport.LLMHint.thinkingOff] = hint
        }
        if reasoningSplit { fields[Type4MeTransferSupport.LLMHint.reasoningSplit] = "1" }
        return .init(provider: id, fields: fields)
    }
}
