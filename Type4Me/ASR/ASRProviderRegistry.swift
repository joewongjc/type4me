import Foundation

enum ASRAudioInputKind: Sendable, Equatable {
    case pcmData
    case pcmBuffer
}

struct ASRProviderCapabilities: Sendable, Equatable {
    let isAvailable: Bool
    /// False for batch/REST providers that only produce results in endAudio().
    let isStreaming: Bool
    let audioInput: ASRAudioInputKind

    static func streaming(audioInput: ASRAudioInputKind = .pcmData) -> ASRProviderCapabilities {
        ASRProviderCapabilities(isAvailable: true, isStreaming: true, audioInput: audioInput)
    }

    static func batch(audioInput: ASRAudioInputKind = .pcmData) -> ASRProviderCapabilities {
        ASRProviderCapabilities(isAvailable: true, isStreaming: false, audioInput: audioInput)
    }

    static let unavailable = ASRProviderCapabilities(
        isAvailable: false,
        isStreaming: true,
        audioInput: .pcmData
    )
}

enum ASRProviderRegistry {

    struct ProviderEntry: Sendable {
        let configType: any ASRProviderConfig.Type
        let createClient: (@Sendable () -> any SpeechRecognizer)?
        let capabilities: ASRProviderCapabilities

        var isAvailable: Bool { createClient != nil }

        init(
            configType: any ASRProviderConfig.Type,
            createClient: (@Sendable () -> any SpeechRecognizer)?,
            capabilities: ASRProviderCapabilities = .unavailable
        ) {
            self.configType = configType
            self.createClient = createClient
            self.capabilities = capabilities
        }
    }

    static let all: [ASRProvider: ProviderEntry] = {
        var dict: [ASRProvider: ProviderEntry] = [
            .apple: ProviderEntry(
                configType: AppleASRConfig.self,
                createClient: { AppleASRClient() },
                capabilities: .streaming(audioInput: .pcmBuffer)
            ),
            .volcano: ProviderEntry(
                configType: VolcanoASRConfig.self,
                createClient: { VolcASRClient() },
                capabilities: .streaming()
            ),
            .deepgram: ProviderEntry(
                configType: DeepgramASRConfig.self,
                createClient: { DeepgramASRClient() },
                capabilities: .streaming()
            ),
            .assemblyai: ProviderEntry(
                configType: AssemblyAIASRConfig.self,
                createClient: { AssemblyAIASRClient() },
                capabilities: .streaming()
            ),
            .elevenlabs: ProviderEntry(
                configType: ElevenLabsASRConfig.self,
                createClient: { ElevenLabsASRClient() },
                capabilities: .streaming()
            ),
            .soniox: ProviderEntry(
                configType: SonioxASRConfig.self,
                createClient: { SonioxASRClient() },
                capabilities: .streaming()
            ),
            .bailian: ProviderEntry(
                configType: BailianASRConfig.self,
                createClient: { BailianASRClient() },
                capabilities: .streaming()
            ),
            .baidu: ProviderEntry(
                configType: BaiduASRConfig.self,
                createClient: { BaiduASRClient() },
                capabilities: .streaming()
            ),
            .openai: ProviderEntry(
                configType: OpenAIASRConfig.self,
                createClient: { OpenAIASRClient() },
                capabilities: .batch()
            ),
            .azure:   ProviderEntry(configType: AzureASRConfig.self,   createClient: nil),
            .google:  ProviderEntry(configType: GoogleASRConfig.self,  createClient: nil),
            .aws:     ProviderEntry(configType: AWSASRConfig.self,     createClient: nil),
            .aliyun:  ProviderEntry(configType: AliyunASRConfig.self,  createClient: nil),
            .tencent: ProviderEntry(configType: TencentASRConfig.self, createClient: nil),
            .iflytek: ProviderEntry(configType: IflytekASRConfig.self, createClient: nil),
            .custom:  ProviderEntry(configType: CustomASRConfig.self,  createClient: nil),
        ]
        #if HAS_SHERPA_ONNX
        dict[.sherpa] = ProviderEntry(
            configType: SherpaASRConfig.self,
            createClient: { SenseVoiceASRClient() },
            capabilities: .batch()
        )
        #else
        dict[.sherpa] = ProviderEntry(
            configType: SherpaASRConfig.self,
            createClient: nil
        )
        #endif
        return dict
    }()

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
        if mode.id == ProcessingMode.directId {
            return capabilities(for: provider).isAvailable
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
        return L(
            "当前引擎不可用于此模式。",
            "This engine is not available for this mode."
        )
    }
}
