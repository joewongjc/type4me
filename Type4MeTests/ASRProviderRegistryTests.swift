import XCTest
@testable import Type4Me

final class ASRProviderRegistryTests: XCTestCase {

    func testAvailableProvidersSupportDirectMode() {
        for provider in [ASRProvider.volcano, .stepfun, .stepfunBatch, .mimo, .baidu, .bailian, .deepgram, .gemini, .assemblyai, .soniox, .metaMuse, .openai] {
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
        for nonRealtime in [ASRProvider.openai, .stepfunBatch, .mimo] {
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
        XCTAssertEqual(ASRProvider.stepfunBatch.displayName, L("阶跃星辰", "StepFun"))
        XCTAssertEqual(ASRProvider.mimo.displayName, L("小米 MiMo", "Xiaomi MiMo"))
        XCTAssertEqual(ASRProvider.openai.displayName, "OpenAI")
    }
}
