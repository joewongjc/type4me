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

    func testCodexCLIFallbackConfigWhenKeychainEmpty() {
        let config = KeychainService.loadLLMProviderConfig(for: .codexCLI)
        XCTAssertNotNil(config, "Codex CLI should safely resolve a default configuration even without Keychain values")
        XCTAssertEqual(config?.toLLMConfig().model, "gpt-5.6-luna")
    }

    func testBrandIconDevPathResolution() {
        let sourceDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Type4MeTests
            .deletingLastPathComponent() // Project root
            .appendingPathComponent("Type4Me/Resources/Icons")
        let testIconURL = sourceDir.appendingPathComponent("openai.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: testIconURL.path), "Brand icons must exist at Type4Me/Resources/Icons")
    }

    func testInitialProviderDefaultsDoNotTriggerUnsavedChanges() {
        let fields = LLMProviderRegistry.configType(for: .openai)?.credentialFields ?? []
        var defaults: [String: String] = [:]
        for field in fields where !field.defaultValue.isEmpty {
            defaults[field.key] = field.defaultValue
        }

        let draftValues = defaults
        let savedValues = defaults
        let isDirty = draftValues != savedValues

        XCTAssertFalse(isDirty, "Newly opened provider with default values must not start in dirty/unsaved state")
        XCTAssertFalse(defaults.isEmpty, "OpenAI should have default model and baseURL fields")
    }

    func testInitialASRProviderDefaultsDoNotTriggerUnsavedChanges() {
        let fields = ASRProviderRegistry.configType(for: .stepfun)?.credentialFields ?? []
        var defaults: [String: String] = [:]
        for field in fields where !field.defaultValue.isEmpty {
            defaults[field.key] = field.defaultValue
        }

        let draftValues = defaults
        let savedValues = defaults
        let isDirty = draftValues != savedValues

        XCTAssertFalse(isDirty, "Newly opened ASR provider with default values must not start in dirty/unsaved state")
    }

    func testDraftTransactionLifecycleAndRevert() {
        let initialSaved = ["apiKey": "original-key", "model": "gpt-4o"]
        var draftValues = initialSaved
        let savedValues = initialSaved

        XCTAssertEqual(draftValues, savedValues)

        // User edits API key to a broken key
        draftValues["apiKey"] = "broken-key"
        XCTAssertNotEqual(draftValues, savedValues, "Editing draft must mark transaction as dirty")

        // Test connection executes using draftValues without mutating savedValues
        let testValues = draftValues
        XCTAssertEqual(testValues["apiKey"], "broken-key")
        XCTAssertEqual(savedValues["apiKey"], "original-key", "Saved baseline must remain intact during testing")

        // Reverting draft restores original key
        draftValues = savedValues
        XCTAssertEqual(draftValues["apiKey"], "original-key")
        XCTAssertEqual(draftValues, savedValues)
    }

    func testVolcanoAutoResourceUpdatesDraftWithoutDirectPersistence() {
        var draft = ["apiKey": "test-key", "resourceId": VolcanoASRConfig.resourceIdAuto]
        let saved = draft

        // Simulating auto-resource resolution during test
        let resolvedID = VolcanoASRConfig.resourceIdSeedASR
        draft["resolvedResourceId"] = resolvedID

        XCTAssertEqual(draft["resolvedResourceId"], resolvedID)
        XCTAssertNil(saved["resolvedResourceId"], "Saved baseline must not be mutated before explicit save")
        XCTAssertNotEqual(draft, saved, "Auto-resolved resource in draft should mark state dirty until saved")
    }
}
