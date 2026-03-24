import Foundation

struct ASRProviderCapabilities: Sendable, Equatable {
    let supportsQuickMode: Bool
    let supportsPerformanceMode: Bool
    let performanceModeReason: String?

    static let full = ASRProviderCapabilities(
        supportsQuickMode: true,
        supportsPerformanceMode: true,
        performanceModeReason: nil
    )

    static let quickOnly = ASRProviderCapabilities(
        supportsQuickMode: true,
        supportsPerformanceMode: false,
        performanceModeReason: L(
            "当前引擎仅支持实时识别，不支持整段识别。",
            "This engine only supports real-time recognition, not full-audio recognition."
        )
    )

    static let unavailable = ASRProviderCapabilities(
        supportsQuickMode: false,
        supportsPerformanceMode: false,
        performanceModeReason: L(
            "当前引擎尚未提供可用的语音识别实现。",
            "This engine does not currently provide an available speech recognition implementation."
        )
    )
}

enum ASRProviderRegistry {

    struct ProviderEntry: Sendable {
        let configType: any ASRProviderConfig.Type
        let createClient: (@Sendable () -> any SpeechRecognizer)?
        let capabilities: ASRProviderCapabilities

        var isAvailable: Bool { createClient != nil }
    }

    static let all: [ASRProvider: ProviderEntry] = [
        .volcano: ProviderEntry(
            configType: VolcanoASRConfig.self,
            createClient: { VolcASRClient() },
            capabilities: .full
        ),
        .openai: ProviderEntry(
            configType: OpenAIASRConfig.self,
            createClient: nil,
            capabilities: .unavailable
        ),
        .azure: ProviderEntry(
            configType: AzureASRConfig.self,
            createClient: nil,
            capabilities: .unavailable
        ),
        .google: ProviderEntry(
            configType: GoogleASRConfig.self,
            createClient: nil,
            capabilities: .unavailable
        ),
        .aws: ProviderEntry(
            configType: AWSASRConfig.self,
            createClient: nil,
            capabilities: .unavailable
        ),
        .deepgram: ProviderEntry(
            configType: DeepgramASRConfig.self,
            createClient: { DeepgramASRClient() },
            capabilities: .quickOnly
        ),
        .aliyun: ProviderEntry(
            configType: AliyunASRConfig.self,
            createClient: nil,
            capabilities: .unavailable
        ),
        .bailian: ProviderEntry(
            configType: BailianASRConfig.self,
            createClient: { BailianASRClient() },
            capabilities: .quickOnly
        ),
        .tencent: ProviderEntry(
            configType: TencentASRConfig.self,
            createClient: nil,
            capabilities: .unavailable
        ),
        .iflytek: ProviderEntry(
            configType: IflytekASRConfig.self,
            createClient: nil,
            capabilities: .unavailable
        ),
        .custom: ProviderEntry(
            configType: CustomASRConfig.self,
            createClient: nil,
            capabilities: .unavailable
        ),
    ]

    static func entry(for provider: ASRProvider) -> ProviderEntry? {
        all[provider]
    }

    static func configType(for provider: ASRProvider) -> (any ASRProviderConfig.Type)? {
        all[provider]?.configType
    }

    static func createClient(for provider: ASRProvider) -> (any SpeechRecognizer)? {
        all[provider]?.createClient?()
    }

    static func capabilities(for provider: ASRProvider) -> ASRProviderCapabilities {
        all[provider]?.capabilities ?? .unavailable
    }

    static func supports(_ mode: ProcessingMode, for provider: ASRProvider) -> Bool {
        let capabilities = capabilities(for: provider)

        guard capabilities.supportsQuickMode else { return false }
        if mode.id == ProcessingMode.performanceId {
            return capabilities.supportsPerformanceMode
        }
        if mode.id == ProcessingMode.directId {
            return capabilities.supportsQuickMode
        }
        return true
    }

    static func supportedModes(from modes: [ProcessingMode], for provider: ASRProvider) -> [ProcessingMode] {
        modes.filter { supports($0, for: provider) }
    }

    static func resolvedMode(for mode: ProcessingMode, provider: ASRProvider) -> ProcessingMode {
        supports(mode, for: provider) ? mode : .direct
    }

    static func unsupportedReason(for mode: ProcessingMode, provider: ASRProvider) -> String? {
        guard !supports(mode, for: provider) else { return nil }

        if mode.id == ProcessingMode.performanceId {
            return capabilities(for: provider).performanceModeReason
        }

        return L(
            "当前引擎不可用于此模式。",
            "This engine is not available for this mode."
        )
    }

    static func supportedModesSummary(for provider: ASRProvider) -> String {
        let capabilities = capabilities(for: provider)
        switch (capabilities.supportsQuickMode, capabilities.supportsPerformanceMode) {
        case (true, true):
            return L("支持：快速模式、性能模式", "Supports: Quick Mode, Performance Mode")
        case (true, false):
            return L("支持：快速模式", "Supports: Quick Mode")
        default:
            return L("支持：无", "Supports: None")
        }
    }
}
