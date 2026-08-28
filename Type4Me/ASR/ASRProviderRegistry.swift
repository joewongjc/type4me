import Foundation

enum ASRAudioInputKind: Sendable, Equatable {
    case pcmData
    case pcmBuffer
}

struct ASRProviderCapabilities: Sendable, Equatable {
    let isAvailable: Bool
    /// Internal session behavior: false for batch/REST providers that only produce final results in endAudio().
    let isStreaming: Bool
    /// User-facing capability: true if recognition starts while speaking (streaming preview);
    /// false if the complete audio is submitted only after releasing the hotkey ("非实时").
    let supportsRealtimeRecognition: Bool
    let audioInput: ASRAudioInputKind

    static func streaming(
        audioInput: ASRAudioInputKind = .pcmData,
        supportsRealtimeRecognition: Bool = true
    ) -> ASRProviderCapabilities {
        ASRProviderCapabilities(
            isAvailable: true,
            isStreaming: true,
            supportsRealtimeRecognition: supportsRealtimeRecognition,
            audioInput: audioInput
        )
    }

    static func batch(
        audioInput: ASRAudioInputKind = .pcmData,
        supportsRealtimeRecognition: Bool = false
    ) -> ASRProviderCapabilities {
        ASRProviderCapabilities(
            isAvailable: true,
            isStreaming: false,
            supportsRealtimeRecognition: supportsRealtimeRecognition,
            audioInput: audioInput
        )
    }

    static let unavailable = ASRProviderCapabilities(
        isAvailable: false,
        isStreaming: true,
        supportsRealtimeRecognition: false,
        audioInput: .pcmData
    )
}

enum ASRProviderRegistry {

    struct ProviderEntry: Sendable {
        let configType: any ASRProviderConfig.Type
        let createClient: (@Sendable () -> any SpeechRecognizer)?
        let capabilities: ASRProviderCapabilities
        let validateCredentials: (@Sendable (any ASRProviderConfig, ASRRequestOptions) async throws -> Void)?

        var isAvailable: Bool { createClient != nil }

        init(
            configType: any ASRProviderConfig.Type,
            createClient: (@Sendable () -> any SpeechRecognizer)?,
            capabilities: ASRProviderCapabilities = .unavailable,
            validateCredentials: (@Sendable (any ASRProviderConfig, ASRRequestOptions) async throws -> Void)? = nil
        ) {
            self.configType = configType
            self.createClient = createClient
            self.capabilities = capabilities
            self.validateCredentials = validateCredentials
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
            .stepfun: ProviderEntry(
                configType: StepFunASRConfig.self,
                createClient: { StepFunASRClient() },
                capabilities: .streaming()
            ),
            .stepfunBatch: ProviderEntry(
                configType: StepFunBatchASRConfig.self,
                createClient: { StepFunBatchASRClient() },
                capabilities: .batch()
            ),
            .mimo: ProviderEntry(
                configType: MiMoASRConfig.self,
                createClient: { MiMoASRClient() },
                capabilities: .batch(),
                validateCredentials: { config, options in
                    guard let mimoConfig = config as? MiMoASRConfig else {
                        throw MiMoASRError.invalidConfig
                    }
                    try await MiMoASRProtocol.validateCredentials(config: mimoConfig, options: options)
                }
            ),
            .deepgram: ProviderEntry(
                configType: DeepgramASRConfig.self,
                createClient: { DeepgramASRClient() },
                capabilities: .streaming()
            ),
            .cartesia: ProviderEntry(
                configType: CartesiaASRConfig.self,
                createClient: { CartesiaASRClient() },
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
            .gemini: ProviderEntry(
                configType: GeminiASRConfig.self,
                createClient: { GeminiASRClient() },
                capabilities: .streaming()
            ),
            .grok: ProviderEntry(
                configType: GrokASRConfig.self,
                createClient: { GrokASRClient() },
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
            capabilities: .batch(supportsRealtimeRecognition: true)
        )
        #else
        dict[.sherpa] = ProviderEntry(
            configType: SherpaASRConfig.self,
            createClient: nil
        )
        #endif
        #if HAS_CLOUD_SUBSCRIPTION
        dict[.cloud] = ProviderEntry(
            configType: CloudASRConfig.self,
            createClient: { CloudASRClient() },
            capabilities: .streaming()
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

    static func validateCredentials(
        for provider: ASRProvider,
        config: any ASRProviderConfig,
        options: ASRRequestOptions
    ) async throws {
        if let validator = all[provider]?.validateCredentials {
            try await validator(config, options)
            return
        }
        guard let client = createClient(for: provider) else {
            throw MiMoASRError.invalidConfig
        }
        try await client.connect(config: config, options: options)
        await client.disconnect()
    }

    static func unsupportedReason(for mode: ProcessingMode, provider: ASRProvider) -> String? {
        guard !supports(mode, for: provider) else { return nil }
        return L(
            "当前引擎不可用于此模式。",
            "This engine is not available for this mode."
        )
    }
}
