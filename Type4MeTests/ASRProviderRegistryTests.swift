import XCTest
@testable import Type4Me

final class ASRProviderRegistryTests: XCTestCase {

    func testAvailableProvidersSupportDirectMode() {
        for provider in [ASRProvider.volcano, .stepfun, .mimo, .baidu, .bailian, .deepgram, .gemini, .assemblyai, .soniox, .metaMuse, .openai] {
            XCTAssertTrue(ASRProviderRegistry.supports(.direct, for: provider))
        }
    }

    func testResolvedModeFallsBackToDirectForUnavailableProvider() {
        let customMode = ProcessingMode(
            id: UUID(),
            name: "Custom",
            prompt: "Rewrite: {text}",
            isBuiltin: false
        )
        // Custom/LLM modes should always be supported
        XCTAssertTrue(ASRProviderRegistry.supports(customMode, for: .bailian))
        XCTAssertTrue(ASRProviderRegistry.supports(customMode, for: .volcano))
    }

    func testSupportedModesFilterKeepsAllForAvailableProviders() {
        let customMode = ProcessingMode(
            id: UUID(),
            name: "Custom",
            prompt: "Rewrite: {text}",
            isBuiltin: false
        )
        let modes = [ProcessingMode.direct, customMode]

        let volcanoModes = ASRProviderRegistry.supportedModes(from: modes, for: .volcano)
        XCTAssertEqual(volcanoModes.map(\.id), [ProcessingMode.directId, customMode.id])

        let bailianModes = ASRProviderRegistry.supportedModes(from: modes, for: .bailian)
        XCTAssertEqual(bailianModes.map(\.id), [ProcessingMode.directId, customMode.id])
    }

    func testRegistry_exposesGeminiProviderConfiguration() {
        let entry = ASRProviderRegistry.entry(for: .gemini)
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isAvailable ?? false)
        XCTAssertTrue(ASRProviderRegistry.configType(for: .gemini) == GeminiASRConfig.self)
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .gemini))

        let caps = ASRProviderRegistry.capabilities(for: .gemini)
        XCTAssertTrue(caps.isAvailable)
        XCTAssertTrue(caps.isStreaming)
        XCTAssertTrue(caps.supportsRealtimeRecognition)
        XCTAssertEqual(caps.audioInput, .pcmData)
    }
    func testRegistry_exposesMetaMuseProviderConfiguration() {
        let entry = ASRProviderRegistry.entry(for: .metaMuse)
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isAvailable ?? false)
        XCTAssertTrue(ASRProviderRegistry.configType(for: .metaMuse) == MetaMuseASRConfig.self)
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .metaMuse))

        let caps = ASRProviderRegistry.capabilities(for: .metaMuse)
        XCTAssertTrue(caps.isAvailable)
        XCTAssertTrue(caps.isStreaming)
        XCTAssertTrue(caps.supportsRealtimeRecognition)
        XCTAssertEqual(caps.audioInput, .pcmData)
    }


    func testRegistry_exposesMiMoProviderConfiguration() {
        let entry = ASRProviderRegistry.entry(for: .mimo)
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isAvailable ?? false)
        XCTAssertTrue(ASRProviderRegistry.configType(for: .mimo) == MiMoASRConfig.self)
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .mimo))

        let caps = ASRProviderRegistry.capabilities(for: .mimo)
        XCTAssertTrue(caps.isAvailable)
        XCTAssertFalse(caps.isStreaming)
        XCTAssertFalse(caps.supportsRealtimeRecognition)
        XCTAssertEqual(caps.audioInput, .pcmData)
    }

    func testCapabilities_distinguishRealtimeAndNonRealtimeProviders() {
        // Non-realtime (batch audio submission after hotkey release)
        for nonRealtime in [ASRProvider.openai, .mimo] {
            let caps = ASRProviderRegistry.capabilities(for: nonRealtime)
            XCTAssertTrue(caps.isAvailable)
            XCTAssertFalse(caps.isStreaming)
            XCTAssertFalse(caps.supportsRealtimeRecognition)
        }

        // Realtime streaming providers
        for realtime in [
            ASRProvider.apple, .volcano, .deepgram, .cartesia,
            .assemblyai, .elevenlabs, .gemini, .grok, .soniox, .metaMuse, .stepfun, .bailian, .baidu
        ] {
            let caps = ASRProviderRegistry.capabilities(for: realtime)
            XCTAssertTrue(caps.isAvailable)
            XCTAssertTrue(caps.isStreaming)
            XCTAssertTrue(caps.supportsRealtimeRecognition)
        }
    }

    func testProviderDisplayNames_areCleanWithoutBatchSuffix() {
        XCTAssertEqual(ASRProvider.stepfun.displayName, L("阶跃星辰", "StepFun"))
        XCTAssertEqual(ASRProvider.mimo.displayName, L("小米 MiMo", "Xiaomi MiMo"))
        XCTAssertEqual(ASRProvider.openai.displayName, "OpenAI")
    }

    func testRecognitionModeSelection_isOfferedByProvidersWithBatchVariant() {
        for provider in [ASRProvider.stepfun, .bailian, .gemini, .elevenlabs, .grok] {
            XCTAssertTrue(ASRProviderRegistry.supportsRecognitionModeSelection(for: provider), "\(provider)")
            let fields = ASRProviderRegistry.configType(for: provider)?.credentialFields ?? []
            XCTAssertEqual(fields.first?.key, ASRRecognitionMode.credentialKey, "\(provider)")
            XCTAssertEqual(fields.first?.defaultValue, ASRRecognitionMode.streaming.rawValue, "\(provider)")
        }
        for provider in [ASRProvider.volcano, .deepgram, .soniox, .openai, .mimo, .baidu] {
            XCTAssertFalse(ASRProviderRegistry.supportsRecognitionModeSelection(for: provider), "\(provider)")
        }
    }

    func testCapabilities_followRequestedRecognitionMode() {
        for provider in [ASRProvider.stepfun, .bailian, .gemini, .elevenlabs, .grok] {
            let streaming = ASRProviderRegistry.capabilities(for: provider, mode: .streaming)
            XCTAssertTrue(streaming.isStreaming, "\(provider)")
            XCTAssertTrue(streaming.supportsRealtimeRecognition, "\(provider)")

            let batch = ASRProviderRegistry.capabilities(for: provider, mode: .batch)
            XCTAssertTrue(batch.isAvailable, "\(provider)")
            XCTAssertFalse(batch.isStreaming, "\(provider)")
            XCTAssertFalse(batch.supportsRealtimeRecognition, "\(provider)")
        }
        // Providers without a batch variant ignore the requested mode.
        XCTAssertTrue(ASRProviderRegistry.capabilities(for: .volcano, mode: .batch).isStreaming)
    }

    func testCreateClient_usesBatchClientWhenConfigSelectsBatch() throws {
        let streaming = try XCTUnwrap(GrokASRConfig(credentials: ["apiKey": "xai-test"]))
        XCTAssertTrue(ASRProviderRegistry.createClient(for: .grok, config: streaming) is GrokASRClient)

        let batch = try XCTUnwrap(GrokASRConfig(credentials: ["apiKey": "xai-test", "recognitionMode": "batch"]))
        XCTAssertTrue(ASRProviderRegistry.createClient(for: .grok, config: batch) is BufferedBatchASRClient)
        XCTAssertFalse(ASRProviderRegistry.capabilities(for: .grok, config: batch).isStreaming)

        let stepFunBatch = try XCTUnwrap(StepFunASRConfig(credentials: ["apiKey": "sk", "recognitionMode": "batch"]))
        XCTAssertTrue(ASRProviderRegistry.createClient(for: .stepfun, config: stepFunBatch) is StepFunBatchASRClient)
    }

    func testCapabilities_followSavedRecognitionMode() throws {
        guard KeychainService.isUsingTestStorage else {
            throw XCTSkip("Requires isolated credential storage")
        }
        let original = KeychainService.loadASRCredentials(for: .elevenlabs)
        defer { try? KeychainService.saveASRCredentials(for: .elevenlabs, values: original ?? [:]) }

        try KeychainService.saveASRCredentials(for: .elevenlabs, values: ["apiKey": "k", "recognitionMode": "batch"])
        XCTAssertEqual(ASRProviderRegistry.recognitionMode(for: .elevenlabs), .batch)
        XCTAssertFalse(ASRProviderRegistry.capabilities(for: .elevenlabs).supportsRealtimeRecognition)
        XCTAssertEqual(
            MenuBarASRProviderItem(provider: .elevenlabs).title,
            "ElevenLabs (\(L("非实时", "Batch")))"
        )

        try KeychainService.saveASRCredentials(for: .elevenlabs, values: ["apiKey": "k", "recognitionMode": "streaming"])
        XCTAssertEqual(ASRProviderRegistry.recognitionMode(for: .elevenlabs), .streaming)
        XCTAssertTrue(ASRProviderRegistry.capabilities(for: .elevenlabs).supportsRealtimeRecognition)
        XCTAssertEqual(MenuBarASRProviderItem(provider: .elevenlabs).title, "ElevenLabs")
    }
}
