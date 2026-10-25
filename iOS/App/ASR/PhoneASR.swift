import Foundation
import Type4MeTransferCore

/// The cloud speech services the iPhone runs: the cloud part of the Mac's
/// `ASRProviderRegistry`, with the same configs and clients. On-device
/// engines (Apple Speech, SenseVoice) stay on the Mac.
enum PhoneASR {
    typealias Validator = @Sendable (any ASRProviderConfig, ASRRequestOptions) async throws -> Void

    struct Variant: Sendable {
        let createClient: @Sendable () -> any SpeechRecognizer
        /// False when the whole recording is uploaded after the user lets go.
        let isStreaming: Bool
        let validate: Validator?

        static func streaming(_ create: @escaping @Sendable () -> any SpeechRecognizer, validate: Validator? = nil) -> Variant {
            Variant(createClient: create, isStreaming: true, validate: validate)
        }

        static func batch(_ create: @escaping @Sendable () -> any SpeechRecognizer, validate: Validator? = nil) -> Variant {
            Variant(createClient: create, isStreaming: false, validate: validate)
        }

        /// The shared buffered client; credentials are tested with one second of silence.
        static func buffered(_ transcriber: any BatchASRTranscriber) -> Variant {
            .batch({ BufferedBatchASRClient(transcriber: transcriber) }, validate: { config, options in
                try await BatchASRHTTP.validate(with: transcriber, config: config, options: options)
            })
        }
    }

    struct Entry: Sendable {
        let provider: ASRProvider
        let configType: any ASRProviderConfig.Type
        let main: Variant
        /// Present when the provider lets users choose batch recognition.
        let batch: Variant?

        func variant(for config: any ASRProviderConfig) -> Variant {
            let mode = (config as? any ASRRecognitionModeConfigurable)?.recognitionMode ?? .default
            return mode == .batch ? (batch ?? main) : main
        }
    }

    private static let table: [ASRProvider: Entry] = {
        func entry(_ provider: ASRProvider, _ type: any ASRProviderConfig.Type, _ main: Variant, batch: Variant? = nil) -> (ASRProvider, Entry) {
            (provider, Entry(provider: provider, configType: type, main: main, batch: batch))
        }
        return Dictionary(uniqueKeysWithValues: [
            entry(.volcano, VolcanoASRConfig.self, .streaming({ VolcASRClient() }, validate: { config, options in
                try await VolcASRClient.validateCredentials(config: config, options: options)
            })),
            entry(.stepfun, StepFunASRConfig.self, .streaming({ StepFunASRClient() }),
                  batch: .batch({ StepFunBatchASRClient() }, validate: { config, options in
                      guard let config = config as? StepFunASRConfig else { throw StepFunBatchASRError.invalidConfig }
                      try await StepFunBatchASRProtocol.validate(config: config, options: options)
                  })),
            entry(.mimo, MiMoASRConfig.self, .batch({ MiMoASRClient() }, validate: { config, options in
                guard let config = config as? MiMoASRConfig else { throw MiMoASRError.invalidConfig }
                try await MiMoASRProtocol.validateCredentials(config: config, options: options)
            })),
            entry(.deepgram, DeepgramASRConfig.self, .streaming({ DeepgramASRClient() })),
            entry(.cartesia, CartesiaASRConfig.self, .streaming({ CartesiaASRClient() })),
            entry(.assemblyai, AssemblyAIASRConfig.self, .streaming({ AssemblyAIASRClient() })),
            entry(.elevenlabs, ElevenLabsASRConfig.self, .streaming({ ElevenLabsASRClient() }),
                  batch: .buffered(ElevenLabsBatchTranscriber())),
            entry(.gemini, GeminiASRConfig.self, .streaming({ GeminiASRClient() }),
                  batch: .buffered(GeminiBatchTranscriber())),
            entry(.grok, GrokASRConfig.self, .streaming({ GrokASRClient() }),
                  batch: .buffered(GrokBatchTranscriber())),
            entry(.groq, GroqASRConfig.self, .buffered(GroqBatchTranscriber())),
            entry(.mistral, MistralASRConfig.self, .buffered(MistralBatchTranscriber())),
            entry(.soniox, SonioxASRConfig.self, .streaming({ SonioxASRClient() })),
            entry(.metaMuse, MetaMuseASRConfig.self, .streaming({ MetaMuseASRClient() })),
            entry(.bailian, BailianASRConfig.self, .streaming({ BailianASRClient() }),
                  batch: .buffered(BailianBatchTranscriber())),
            entry(.azure, AzureASRConfig.self, .streaming({ AzureMAIASRClient() }, validate: { config, options in
                try await AzureMAIASRClient.validateCredentials(config: config, options: options)
            }), batch: .buffered(AzureMAIBatchTranscriber())),
            entry(.openai, OpenAIASRConfig.self, .batch({ OpenAIASRClient() })),
            entry(.tencent, TencentASRConfig.self, .streaming({ TencentASRClient() }, validate: { config, options in
                try await TencentASRClient.validateCredentials(config: config, options: options)
            }), batch: .buffered(TencentRecTaskTranscriber())),
            entry(.custom, CustomASRConfig.self, .buffered(CustomHTTPBatchTranscriber())),
        ])
    }()

    /// Recommended first, in the Mac's order, then the rest by name with Custom last.
    static let providers: [ASRProvider] = {
        let all = Type4MeTransferSupport.asrProviders.compactMap(ASRProvider.init(rawValue:)).filter { table[$0] != nil }
        let recommended: [ASRProvider] = [.volcano, .mimo, .bailian, .soniox]
        let rest = all.filter { !recommended.contains($0) && $0 != .custom }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return recommended.filter(all.contains) + rest + (all.contains(.custom) ? [.custom] : [])
    }()

    static func entry(for provider: ASRProvider) -> Entry? { table[provider] }

    static func entry(for id: String) -> Entry? {
        ASRProvider(rawValue: id).flatMap { table[$0] }
    }

    /// The display name for a provider ID that arrived from the Mac.
    static func name(_ id: String) -> String {
        ASRProvider(rawValue: id)?.displayName ?? id
    }

    /// nil when the provider isn't supported here or required fields are missing.
    static func config(for endpoint: Type4MeTransferPayload.Endpoint) -> (any ASRProviderConfig)? {
        guard let entry = entry(for: endpoint.provider),
              let config = entry.configType.init(credentials: endpoint.fields),
              config.isValid
        else { return nil }
        return config
    }

    static func requestOptions(for endpoint: Type4MeTransferPayload.Endpoint) -> ASRRequestOptions {
        var options = ASRRequestOptions()
        options.boostingTableID = endpoint.fields["boostingTableID"]
        return options
    }

    /// Short description of the configured model, for lists.
    static func summary(for endpoint: Type4MeTransferPayload.Endpoint) -> String {
        guard let entry = entry(for: endpoint.provider) else { return "" }
        let fields = endpoint.fields
        var parts: [String] = []
        if entry.batch != nil {
            parts.append(ASRRecognitionMode(credentials: fields).displayName)
        }
        let mode = ASRRecognitionMode(credentials: fields)
        let shown = entry.configType.credentialFields.filter { $0.isVisible(in: mode) }
        for key in ["resourceId", "model", "batchModel"] {
            guard let field = shown.first(where: { $0.key == key }),
                  let value = fields[key], !value.isEmpty
            else { continue }
            parts.append(field.options.first { $0.value == value }?.label ?? value)
            break
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Connection test

    /// Uses the provider's own credential check when it has one; otherwise
    /// connects, sends 0.2 s of silence and waits briefly for a rejection,
    /// since several services report bad keys only after audio arrives.
    static func test(_ endpoint: Type4MeTransferPayload.Endpoint) async -> ConnectionTest.State {
        guard let entry = entry(for: endpoint.provider), let config = config(for: endpoint) else {
            return .failed(L("配置不完整", "The setup is incomplete"))
        }
        let variant = entry.variant(for: config)
        let options = requestOptions(for: endpoint)
        let started = Date()
        do {
            if let validate = variant.validate {
                try await validate(config, options)
                return .passed(ms: Int(Date().timeIntervalSince(started) * 1000))
            }
            let client = variant.createClient()
            try await client.connect(config: config, options: options)
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            let events = await client.events
            try? await client.sendAudio(Data(count: 6_400))
            let failure: String? = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    for await event in events {
                        if case .error(let error) = event { return error.localizedDescription }
                        if case .completed = event { return nil }
                    }
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(1500))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            await client.disconnect()
            return failure.map(ConnectionTest.State.failed) ?? .passed(ms: latency)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
