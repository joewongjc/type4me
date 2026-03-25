import Foundation

enum ASRProviderRegistry {

    struct ProviderEntry: Sendable {
        let configType: any ASRProviderConfig.Type
        let createClient: (@Sendable () -> any SpeechRecognizer)?

        /// Factory for creating an offline (one-shot) recognizer for dual-channel mode.
        /// Providers that support dual-channel return a non-nil closure.
        let offlineRecognize: (@Sendable (Data, any ASRProviderConfig) async throws -> String)?

        var isAvailable: Bool { createClient != nil }

        /// Whether this provider supports dual-channel (streaming + offline) mode.
        var supportsDualChannel: Bool { offlineRecognize != nil }

        init(
            configType: any ASRProviderConfig.Type,
            createClient: (@Sendable () -> any SpeechRecognizer)?,
            offlineRecognize: (@Sendable (Data, any ASRProviderConfig) async throws -> String)? = nil
        ) {
            self.configType = configType
            self.createClient = createClient
            self.offlineRecognize = offlineRecognize
        }
    }

    static let all: [ASRProvider: ProviderEntry] = [
        .sherpa:  ProviderEntry(
            configType: SherpaASRConfig.self,
            createClient: { SherpaASRClient() },
            offlineRecognize: { pcmData, config in
                guard let sherpaConfig = config as? SherpaASRConfig else {
                    throw SherpaOfflineASRError.modelNotFound("Invalid config type")
                }
                return try await SherpaOfflineASRClient.recognize(pcmData: pcmData, config: sherpaConfig)
            }
        ),
        .volcano: ProviderEntry(
            configType: VolcanoASRConfig.self,
            createClient: { VolcASRClient() },
            offlineRecognize: { pcmData, config in
                guard let volcConfig = config as? VolcanoASRConfig else {
                    throw VolcFlashASRError.missingCredentials
                }
                return try await VolcFlashASRClient.recognize(pcmData: pcmData, config: volcConfig)
            }
        ),
        .openai:  ProviderEntry(configType: OpenAIASRConfig.self,  createClient: nil),
        .azure:   ProviderEntry(configType: AzureASRConfig.self,   createClient: nil),
        .google:  ProviderEntry(configType: GoogleASRConfig.self,  createClient: nil),
        .aws:     ProviderEntry(configType: AWSASRConfig.self,     createClient: nil),
        .deepgram: ProviderEntry(configType: DeepgramASRConfig.self, createClient: { DeepgramASRClient() }),
        .aliyun:  ProviderEntry(configType: AliyunASRConfig.self,  createClient: nil),
        .tencent: ProviderEntry(configType: TencentASRConfig.self, createClient: nil),
        .iflytek: ProviderEntry(configType: IflytekASRConfig.self, createClient: nil),
        .custom:  ProviderEntry(configType: CustomASRConfig.self,  createClient: nil),
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
}
