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

    typealias Validator = @Sendable (any ASRProviderConfig, ASRRequestOptions) async throws -> Void

    /// Alternative client used when a provider's recognition mode is `.batch`.
    struct BatchVariant: Sendable {
        let createClient: @Sendable () -> any SpeechRecognizer
        let capabilities: ASRProviderCapabilities
        let validateCredentials: Validator?

        init(
            createClient: @escaping @Sendable () -> any SpeechRecognizer,
            capabilities: ASRProviderCapabilities = .batch(),
            validateCredentials: Validator? = nil
        ) {
            self.createClient = createClient
            self.capabilities = capabilities
            self.validateCredentials = validateCredentials
        }

        /// Variant backed by the shared buffered client; credentials are tested with one second of silence.
        static func buffered(_ transcriber: any BatchASRTranscriber) -> BatchVariant {
            BatchVariant(
                createClient: { BufferedBatchASRClient(transcriber: transcriber) },
                validateCredentials: { config, options in
                    try await BatchASRHTTP.validate(with: transcriber, config: config, options: options)
                }
            )
        }
    }

    struct ProviderEntry: Sendable {
        let configType: any ASRProviderConfig.Type
        let createClient: (@Sendable () -> any SpeechRecognizer)?
        let capabilities: ASRProviderCapabilities
        let validateCredentials: Validator?
        /// Present when the provider lets users choose between streaming and batch recognition.
        let batch: BatchVariant?

        var isAvailable: Bool { createClient != nil }
        var supportsRecognitionModeSelection: Bool { batch != nil }

        init(
            configType: any ASRProviderConfig.Type,
            createClient: (@Sendable () -> any SpeechRecognizer)?,
            capabilities: ASRProviderCapabilities = .unavailable,
            validateCredentials: Validator? = nil,
            batch: BatchVariant? = nil
        ) {
            self.configType = configType
            self.createClient = createClient
            self.capabilities = capabilities
            self.validateCredentials = validateCredentials
            self.batch = batch
        }

        func createClient(mode: ASRRecognitionMode) -> (any SpeechRecognizer)? {
            if mode == .batch, let batch { return batch.createClient() }
            return createClient?()
        }

        func capabilities(mode: ASRRecognitionMode) -> ASRProviderCapabilities {
            if mode == .batch, let batch { return batch.capabilities }
            return capabilities
        }

        func validator(mode: ASRRecognitionMode) -> Validator? {
            if mode == .batch, let batch { return batch.validateCredentials }
            return validateCredentials
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
                capabilities: .streaming(),
                validateCredentials: { config, options in
                    try await VolcASRClient.validateCredentials(config: config, options: options)
                }
            ),
            .stepfun: ProviderEntry(
                configType: StepFunASRConfig.self,
                createClient: { StepFunASRClient() },
                capabilities: .streaming(),
                batch: BatchVariant(createClient: { StepFunBatchASRClient() })
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
                capabilities: .streaming(),
                batch: .buffered(ElevenLabsBatchTranscriber())
            ),
            .gemini: ProviderEntry(
                configType: GeminiASRConfig.self,
                createClient: { GeminiASRClient() },
                capabilities: .streaming(),
                batch: .buffered(GeminiBatchTranscriber())
            ),
            .grok: ProviderEntry(
                configType: GrokASRConfig.self,
                createClient: { GrokASRClient() },
                capabilities: .streaming(),
                batch: .buffered(GrokBatchTranscriber())
            ),
            .soniox: ProviderEntry(
                configType: SonioxASRConfig.self,
                createClient: { SonioxASRClient() },
                capabilities: .streaming()
            ),
            .metaMuse: ProviderEntry(
                configType: MetaMuseASRConfig.self,
                createClient: { MetaMuseASRClient() },
                capabilities: .streaming()
            ),
            .bailian: ProviderEntry(
                configType: BailianASRConfig.self,
                createClient: { BailianASRClient() },
                capabilities: .streaming(),
                batch: .buffered(BailianBatchTranscriber())
            ),
            .baidu: ProviderEntry(
                configType: BaiduASRConfig.self,
                createClient: { BaiduASRClient() },
                capabilities: .streaming()
            ),
            .azure: ProviderEntry(
                configType: AzureASRConfig.self,
                createClient: { AzureMAIASRClient() },
                capabilities: .streaming(),
                validateCredentials: { config, options in
                    try await AzureMAIASRClient.validateCredentials(config: config, options: options)
                },
                batch: .buffered(AzureMAIBatchTranscriber())
            ),
            .openai: ProviderEntry(
                configType: OpenAIASRConfig.self,
                createClient: { OpenAIASRClient() },
                capabilities: .batch()
            ),
            .google:  ProviderEntry(configType: GoogleASRConfig.self,  createClient: nil),
            .aws:     ProviderEntry(configType: AWSASRConfig.self,     createClient: nil),
            .aliyun:  ProviderEntry(configType: AliyunASRConfig.self,  createClient: nil),
            .tencent: ProviderEntry(configType: TencentASRConfig.self, createClient: nil),
            .iflytek: ProviderEntry(configType: IflytekASRConfig.self, createClient: nil),
            .custom: ProviderEntry(
                configType: CustomASRConfig.self,
                createClient: { BufferedBatchASRClient(transcriber: CustomHTTPBatchTranscriber()) },
                capabilities: .batch(),
                validateCredentials: { config, options in
                    try await BatchASRHTTP.validate(with: CustomHTTPBatchTranscriber(), config: config, options: options)
                }
            ),
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

    static func supportsRecognitionModeSelection(for provider: ASRProvider) -> Bool {
        all[provider]?.supportsRecognitionModeSelection ?? false
    }

    /// The saved recognition mode. Providers without a choice report `.streaming`.
    static func recognitionMode(for provider: ASRProvider) -> ASRRecognitionMode {
        guard supportsRecognitionModeSelection(for: provider) else { return .default }
        return ASRRecognitionMode(
            credentialValue: KeychainService.loadASRPlaintextValue(
                for: provider,
                key: ASRRecognitionMode.credentialKey
            )
        )
    }

    static func recognitionMode(of config: any ASRProviderConfig) -> ASRRecognitionMode {
        (config as? any ASRRecognitionModeConfigurable)?.recognitionMode ?? .default
    }

    /// Client for the saved recognition mode.
    static func createClient(for provider: ASRProvider) -> (any SpeechRecognizer)? {
        all[provider]?.createClient(mode: recognitionMode(for: provider))
    }

    /// Client matching the recognition mode carried by `config`.
    static func createClient(for provider: ASRProvider, config: any ASRProviderConfig) -> (any SpeechRecognizer)? {
        all[provider]?.createClient(mode: recognitionMode(of: config))
    }

    /// Capabilities for the saved recognition mode.
    static func capabilities(for provider: ASRProvider) -> ASRProviderCapabilities {
        capabilities(for: provider, mode: recognitionMode(for: provider))
    }

    static func capabilities(for provider: ASRProvider, mode: ASRRecognitionMode) -> ASRProviderCapabilities {
        all[provider]?.capabilities(mode: mode) ?? .unavailable
    }

    static func capabilities(for provider: ASRProvider, config: (any ASRProviderConfig)?) -> ASRProviderCapabilities {
        guard let config else { return capabilities(for: provider) }
        return capabilities(for: provider, mode: recognitionMode(of: config))
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
        if let validator = all[provider]?.validator(mode: recognitionMode(of: config)) {
            try await validator(config, options)
            return
        }
        guard let client = createClient(for: provider, config: config) else {
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
