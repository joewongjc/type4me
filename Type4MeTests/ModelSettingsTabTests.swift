import XCTest
@testable import Type4Me

final class ModelSettingsTabTests: XCTestCase {

    func testModelCategoryProperties() {
        XCTAssertEqual(ModelCategory.asr.id, "asr")
        XCTAssertEqual(ModelCategory.llm.id, "llm")

        XCTAssertFalse(ModelCategory.asr.displayName.isEmpty)
        XCTAssertFalse(ModelCategory.llm.displayName.isEmpty)

        XCTAssertEqual(ModelCategory.asr.icon, "mic.fill")
        XCTAssertEqual(ModelCategory.llm.icon, "sparkles")
    }

    func testModelProviderGroupASR() {
        let rec = ModelSettingsHelpers.asrProviders(in: .recommended)
        XCTAssertTrue(rec.contains(.volcano))

        let local = ModelSettingsHelpers.asrProviders(in: .local)
        XCTAssertTrue(local.contains(.apple))

        let cloud = ModelSettingsHelpers.asrProviders(in: .cloud)
        XCTAssertFalse(cloud.contains(.volcano))
        XCTAssertFalse(cloud.contains(.apple))
    }

    func testModelProviderGroupLLM() {
        let rec = ModelSettingsHelpers.llmProviders(in: .recommended)
        XCTAssertTrue(rec.contains(.doubao))
        XCTAssertTrue(rec.contains(.deepseek))

        let local = ModelSettingsHelpers.llmProviders(in: .local)
        XCTAssertTrue(local.contains(.codexCLI))
        XCTAssertTrue(local.contains(.ollama))

        let cloud = ModelSettingsHelpers.llmProviders(in: .cloud)
        XCTAssertFalse(cloud.contains(.doubao))
        XCTAssertFalse(cloud.contains(.codexCLI))
    }

    func testLocalASREngineSelectionTransitions() {
        let initial = LocalASREngineSelection(senseVoiceEnabled: true, qwen3Enabled: true)

        // Turn off senseVoice with Qwen3 available keeps Qwen3 enabled
        let svOff = initial.settingSenseVoice(false, qwen3Available: true)
        XCTAssertFalse(svOff.senseVoiceEnabled)
        XCTAssertTrue(svOff.qwen3Enabled)

        // Turn off senseVoice when Qwen3 is not available does not allow both off
        let bothOffAttempt = LocalASREngineSelection(senseVoiceEnabled: true, qwen3Enabled: false)
            .settingSenseVoice(false, qwen3Available: false)
        XCTAssertTrue(bothOffAttempt.senseVoiceEnabled)

        // Turn on Qwen3 preserves senseVoice
        let qwenOn = LocalASREngineSelection(senseVoiceEnabled: true, qwen3Enabled: false)
            .settingQwen3(true)
        XCTAssertTrue(qwenOn.senseVoiceEnabled)
        XCTAssertTrue(qwenOn.qwen3Enabled)
    }

    func testZeroCredentialConfiguredStatus() {
        // Apple ASR requires no credentials
        XCTAssertTrue(ModelSettingsHelpers.hasConfiguredCredentials(for: ASRProvider.apple))

        // Codex CLI requires no explicit API key
        XCTAssertTrue(ModelSettingsHelpers.hasConfiguredCredentials(for: LLMProvider.codexCLI))

        // Ollama requires saved model configuration
        XCTAssertFalse(ModelSettingsHelpers.hasConfiguredCredentials(for: LLMProvider.ollama))
    }

    func testProviderIcons() {
        XCTAssertEqual(ModelSettingsHelpers.icon(for: ASRProvider.apple), "apple.logo")
        XCTAssertEqual(ModelSettingsHelpers.icon(for: ASRProvider.volcano), "flame.fill")
        XCTAssertEqual(ModelSettingsHelpers.icon(for: LLMProvider.doubao), "sparkles")
        XCTAssertEqual(ModelSettingsHelpers.icon(for: LLMProvider.deepseek), "brain.fill")
    }
}
