import XCTest
@testable import Type4Me

final class LLMProviderModelOptionsTests: XCTestCase {

    func testProviderModelListsExposeCurrentDefaults() {
        XCTAssertEqual(LLMProvider.doubao.optionValues.first, "doubao-seed-2-1-turbo-260628")
        XCTAssertTrue(LLMProvider.doubao.optionValues.contains("doubao-seed-2-1-pro-260915"))
        XCTAssertTrue(LLMProvider.doubao.optionValues.contains("doubao-seed-2-1-lite-260915"))
        XCTAssertTrue(LLMProvider.doubao.optionValues.contains("doubao-seed-2-0-mini-260428"))
        XCTAssertFalse(LLMProvider.doubao.optionValues.contains("doubao-seed-2-0-pro-260215"))

        XCTAssertEqual(LLMProvider.minimaxCN.optionValues, ["MiniMax-M3", "MiniMax-M3.1-Flash"])
        XCTAssertEqual(LLMProvider.minimaxCN.optionValues, LLMProvider.minimaxIntl.optionValues)

        XCTAssertEqual(LLMProvider.bailian.optionValues.first, "qwen3.7-plus")
        XCTAssertTrue(LLMProvider.bailian.optionValues.contains("qwen3.8-flash"))
        XCTAssertTrue(LLMProvider.bailian.optionValues.contains("qwen3.8-max"))
        XCTAssertFalse(LLMProvider.bailian.optionValues.contains("qwen-turbo"))

        XCTAssertEqual(LLMProvider.kimi.optionValues.first, "kimi-k3.1-pro-highspeed")
        XCTAssertTrue(LLMProvider.kimi.optionValues.contains("kimi-k3"))
        XCTAssertTrue(LLMProvider.kimi.optionValues.contains("kimi-k2.6"))
        XCTAssertFalse(LLMProvider.kimi.optionValues.contains("kimi-k2.5"))
        XCTAssertFalse(LLMProvider.kimi.optionValues.contains("moonshot-v1-8k"))

        XCTAssertEqual(LLMProvider.openai.optionValues.first, "gpt-6-luna")
        XCTAssertTrue(LLMProvider.openai.optionValues.contains("gpt-6.1-terra"))
        XCTAssertTrue(LLMProvider.openai.optionValues.contains("gpt-5.4-mini"))
        XCTAssertFalse(LLMProvider.openai.optionValues.contains("gpt-5.4-nano"))

        XCTAssertEqual(LLMProvider.gemini.optionValues.first, "gemini-3.5-flash-lite")
        XCTAssertTrue(LLMProvider.gemini.optionValues.contains("gemini-3.8-flash"))
        XCTAssertTrue(LLMProvider.gemini.optionValues.contains("gemini-3.1-pro-preview"))
        XCTAssertFalse(LLMProvider.gemini.optionValues.contains("gemini-3.5-flash"))
        XCTAssertFalse(LLMProvider.gemini.optionValues.contains("gemini-2.5-flash"))

        XCTAssertEqual(LLMProvider.deepseek.optionValues, ["deepseek-flash", "deepseek-v4-pro"])

        XCTAssertEqual(LLMProvider.zhipu.optionValues.first, "glm-5.2")
        XCTAssertTrue(LLMProvider.zhipu.optionValues.contains("glm-5.3-flashx"))
        XCTAssertTrue(LLMProvider.zhipu.optionValues.contains("glm-4.7-flash"))

        XCTAssertEqual(LLMProvider.claude.optionValues.first, "claude-haiku-5-5")
        XCTAssertTrue(LLMProvider.claude.optionValues.contains("claude-sonnet-5-5"))
        XCTAssertTrue(LLMProvider.claude.optionValues.contains("claude-opus-5-5"))
        XCTAssertTrue(LLMProvider.claude.optionValues.contains("claude-haiku-4-5"))

        XCTAssertEqual(LLMProvider.codexCLI.optionValues.first, "gpt-6-luna")
        XCTAssertTrue(LLMProvider.codexCLI.optionValues.contains("gpt-6.1-terra"))
        XCTAssertTrue(LLMProvider.codexCLI.optionValues.contains("gpt-5.6-luna"))
        XCTAssertFalse(LLMProvider.codexCLI.optionValues.contains("gpt-5.3-codex-spark"))

        XCTAssertEqual(LLMProvider.mimo.optionValues.first, "mimo-v2.6-flash")
        XCTAssertTrue(LLMProvider.mimo.optionValues.contains("mimo-v2.6-pro"))
        XCTAssertFalse(LLMProvider.mimo.optionValues.contains("mimo-v2.5-pro"))
        XCTAssertEqual(LLMProvider.mimo.defaultBaseURL, "https://api.xiaomimimo.com/v1")
        XCTAssertEqual(LLMProvider.mimo.thinkingDisableField(for: "mimo-v2.6-pro"), .thinking)

        XCTAssertTrue(LLMProvider.magpie.optionValues.isEmpty)
        XCTAssertEqual(LLMProvider.magpie.defaultBaseURL, "http://127.0.0.1:3425/v1")
        XCTAssertEqual(LLMProvider.magpie.thinkingDisableField(for: "any"), .lowestReasoningEffort)
        XCTAssertFalse(LLMProvider.magpie.requiresAPIKey)
        XCTAssertTrue(LLMProvider.magpie.isOpenAICompatible)
        XCTAssertFalse(LLMProvider.magpie.isLocal)
    }

    func testProviderModelOptionsHaveNoDuplicates() {
        for provider in LLMProvider.allCases {
            let values = provider.optionValues
            XCTAssertEqual(
                Set(values).count,
                values.count,
                "\(provider.rawValue) has duplicate model options"
            )
        }
    }

    func testThinkingDisableStrategyIsModelAware() {
        XCTAssertNil(LLMProvider.kimi.thinkingDisableField(for: "kimi-k2.7-code"))
        XCTAssertNil(LLMProvider.kimi.thinkingDisableField(for: "kimi-k2.7-code-highspeed"))
        XCTAssertEqual(LLMProvider.kimi.thinkingDisableField(for: "kimi-k2.6"), .thinking)
        XCTAssertEqual(LLMProvider.deepseek.thinkingDisableField(for: "deepseek-v4-flash"), .thinking)
        XCTAssertEqual(LLMProvider.zhipu.thinkingDisableField(for: "glm-5.2"), .thinking)
        XCTAssertEqual(LLMProvider.openrouter.thinkingDisableField(for: "deepseek/deepseek-v4-flash-0731"), .reasoning)

        XCTAssertNil(LLMProvider.kimi.thinkingDisableField(for: "kimi-k3.1-pro-highspeed"))
        XCTAssertNil(LLMProvider.zhipu.thinkingDisableField(for: "glm-5.3-flash"))
        XCTAssertEqual(LLMProvider.zhipu.thinkingDisableField(for: "glm-4.7-flashx"), .thinking)

        XCTAssertEqual(LLMProvider.openai.thinkingDisableField(for: "gpt-6-luna"), .reasoningEffort)
        XCTAssertEqual(LLMProvider.openai.thinkingDisableField(for: "gpt-5.5-2026-04-23"), .reasoningEffort)
        XCTAssertNil(LLMProvider.openai.thinkingDisableField(for: "gpt-6.1-sol"))
        XCTAssertNil(LLMProvider.openai.thinkingDisableField(for: "gpt-6-astra"))
        XCTAssertNil(LLMProvider.openai.thinkingDisableField(for: "gpt-5.5-pro"))
    }

    func testClaudeThinkingOffTypeIsModelAware() {
        XCTAssertEqual(LLMProvider.claudeThinkingOffType(for: "claude-haiku-5-5"), "disabled")
        XCTAssertEqual(LLMProvider.claudeThinkingOffType(for: "claude-haiku-4-5"), "disabled")
        XCTAssertEqual(LLMProvider.claudeThinkingOffType(for: "claude-haiku-4-5-20251001"), "disabled")
        XCTAssertEqual(LLMProvider.claudeThinkingOffType(for: "claude-sonnet-5"), "disabled")
        XCTAssertEqual(LLMProvider.claudeThinkingOffType(for: "claude-sonnet-5-5"), "between_tools")
        XCTAssertNil(LLMProvider.claudeThinkingOffType(for: "claude-opus-5-5"))
        XCTAssertNil(LLMProvider.claudeThinkingOffType(for: "claude-fable-5-1"))
        XCTAssertNil(LLMProvider.claudeThinkingOffType(for: "MiniMax-M3"))

        XCTAssertEqual(LLMProvider.claude.thinkingDisableField(for: "claude-haiku-5-5"), .thinking)
        XCTAssertNil(LLMProvider.claude.thinkingDisableField(for: "claude-opus-5-5"))
    }

    func testOpenRouterThinkingPreferenceDefaultsToModelBehavior() throws {
        let suiteName = "LLMThinkingPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "tf_disableThinking")

        XCTAssertTrue(LLMThinkingPreference.isDisabled(for: .deepseek, defaults: defaults))
        XCTAssertFalse(LLMThinkingPreference.isDisabled(for: .openrouter, defaults: defaults))

        LLMThinkingPreference.setDisabled(true, for: .openrouter, defaults: defaults)
        XCTAssertTrue(LLMThinkingPreference.isDisabled(for: .openrouter, defaults: defaults))
    }
}

private extension LLMProvider {
    var optionValues: [String] {
        modelOptions.map(\.value)
    }
}
