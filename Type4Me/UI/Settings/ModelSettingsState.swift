import SwiftUI

// MARK: - Local ASR Engine Selection

struct LocalASREngineSelection: Equatable {
    var senseVoiceEnabled: Bool
    var qwen3Enabled: Bool

    func settingSenseVoice(_ enabled: Bool, qwen3Available: Bool) -> Self {
        guard !enabled, !qwen3Enabled else {
            return Self(senseVoiceEnabled: enabled, qwen3Enabled: qwen3Enabled)
        }
        guard qwen3Available else { return self }
        return Self(senseVoiceEnabled: false, qwen3Enabled: true)
    }

    func settingQwen3(_ enabled: Bool) -> Self {
        Self(
            senseVoiceEnabled: enabled ? senseVoiceEnabled : true,
            qwen3Enabled: enabled
        )
    }
}

// MARK: - Model Category (Segmented Capsule)

enum ModelCategory: String, CaseIterable, Identifiable, Hashable {
    case asr
    case llm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .asr:
            return L("语音识别", "Speech Recognition")
        case .llm:
            return L("文本处理", "Text Processing")
        }
    }

    var shortName: String {
        switch self {
        case .asr:
            return L("语音识别 (ASR)", "ASR")
        case .llm:
            return L("文本处理 (LLM)", "LLM")
        }
    }

    var icon: String {
        switch self {
        case .asr: return "mic.fill"
        case .llm: return "sparkles"
        }
    }
}

// MARK: - Model Provider Group

enum ModelProviderGroup: String, CaseIterable, Identifiable {
    case recommended
    case local
    case cloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recommended: return L("推荐", "Recommended")
        case .local:       return L("本地", "Local")
        case .cloud:       return L("云端服务", "Cloud Providers")
        }
    }
}

// MARK: - Model Settings State Helpers

enum ModelSettingsHelpers {

    // MARK: - ASR Groups & Checks

    static let recommendedASRProviders: [ASRProvider] = [.volcano, .soniox]

    #if HAS_SHERPA_ONNX
    static let localASRProviders: [ASRProvider] = ModelManager.isQwen3ASRBundled ? [.apple, .sherpa] : [.apple]
    #else
    static let localASRProviders: [ASRProvider] = [.apple]
    #endif

    static func availableASRProviders() -> [ASRProvider] {
        let localSet = Set(localASRProviders)
        return ASRProvider.allCases.filter { p in
            guard localSet.contains(p) || (ASRProviderRegistry.entry(for: p)?.isAvailable ?? false) else {
                return false
            }
            #if HAS_CLOUD_SUBSCRIPTION
            if p == .cloud { return false }
            #endif
            return true
        }
    }

    static func asrProviders(in group: ModelProviderGroup) -> [ASRProvider] {
        let all = availableASRProviders()
        let allSet = Set(all)
        switch group {
        case .recommended:
            return recommendedASRProviders.filter { allSet.contains($0) }
        case .local:
            return localASRProviders.filter { allSet.contains($0) }
        case .cloud:
            let recSet = Set(recommendedASRProviders)
            let locSet = Set(localASRProviders)
            return all
                .filter { !recSet.contains($0) && !locSet.contains($0) }
                .sorted { $0.displayName.localizedAlphabeticalCompare($1.displayName) == .orderedAscending }
        }
    }

    /// Checks whether the ASR provider has valid configured credentials or requires zero credentials.
    static func hasConfiguredCredentials(for provider: ASRProvider) -> Bool {
        if provider == .apple {
            return true
        }
        if provider == .sherpa {
            return ModelManager.isQwen3ASRBundled
        }
        guard let values = KeychainService.loadASRCredentials(for: provider) else {
            return false
        }
        if provider == .volcano {
            return VolcanoASRConfig(credentials: values) != nil
        }
        let fields = ASRProviderRegistry.configType(for: provider)?.credentialFields ?? []
        let required = fields.filter { !$0.isOptional }
        if required.isEmpty { return true }
        return required.allSatisfy { field in
            !(values[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }
    }

    // MARK: - LLM Groups & Checks

    static let recommendedLLMProviders: [LLMProvider] = [.doubao, .deepseek, .kimi, .openai, .gemini]
    static let localLLMProviders: [LLMProvider] = [.codexCLI, .ollama]

    static func llmProviders(in group: ModelProviderGroup) -> [LLMProvider] {
        switch group {
        case .recommended:
            return recommendedLLMProviders
        case .local:
            return localLLMProviders
        case .cloud:
            let recSet = Set(recommendedLLMProviders)
            let locSet = Set(localLLMProviders)
            return LLMProvider.allCases
                .filter { !recSet.contains($0) && !locSet.contains($0) }
                .sorted { $0.displayName.localizedAlphabeticalCompare($1.displayName) == .orderedAscending }
        }
    }

    /// Checks whether the LLM provider has valid configured credentials or requires zero credentials.
    static func hasConfiguredCredentials(for provider: LLMProvider) -> Bool {
        if provider == .codexCLI {
            return true
        }
        guard let values = KeychainService.loadLLMCredentials(for: provider) else {
            return false
        }
        if provider == .ollama {
            return !(values["model"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }
        let fields = LLMProviderRegistry.configType(for: provider)?.credentialFields ?? []
        let required = fields.filter { !$0.isOptional }
        if required.isEmpty { return true }
        return required.allSatisfy { field in
            !(values[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }
    }

    // MARK: - Provider Symbols & Icons

    static func icon(for provider: ASRProvider) -> String {
        switch provider {
        case .apple:       return "apple.logo"
        case .sherpa:      return "cpu"
        case .volcano:     return "flame.fill"
        case .soniox:      return "waveform.path.badge.plus"
        case .deepgram:    return "waveform.badge.waveform"
        case .cartesia:    return "sparkles"
        case .assemblyai:  return "waveform"
        case .elevenlabs:  return "waveform.path"
        case .gemini:      return "sparkles"
        case .grok:        return "brain.head.profile"
        case .stepfun, .stepfunBatch: return "bolt.horizontal.fill"
        case .mimo:        return "message.and.waveform.fill"
        case .bailian:     return "cloud.fill"
        case .baidu:       return "pawprint.fill"
        case .openai:      return "circle.grid.cross.fill"
        default:           return "mic.fill"
        }
    }

    static func icon(for provider: LLMProvider) -> String {
        switch provider {
        case .doubao:      return "sparkles"
        case .deepseek:    return "brain.fill"
        case .kimi:        return "moon.stars.fill"
        case .minimaxCN, .minimaxIntl: return "cube.fill"
        case .bailian:     return "cloud.fill"
        case .openrouter:  return "arrow.triangle.swap"
        case .openai:      return "circle.grid.cross.fill"
        case .gemini:      return "sparkles"
        case .zhipu:       return "lightbulb.fill"
        case .claude:      return "brain.head.profile"
        case .codexCLI:    return "terminal.fill"
        case .ollama:      return "server.rack"
        case .custom:      return "gearshape.fill"
        }
    }
}
