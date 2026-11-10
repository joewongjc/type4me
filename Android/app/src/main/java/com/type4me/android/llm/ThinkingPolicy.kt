package com.type4me.android.llm

/** The request field each provider accepts for turning reasoning off. */
enum class ThinkingField {
    THINKING,
    ENABLE_THINKING,
    REASONING_EFFORT,
    REASONING,
    THINK,
}

enum class ThinkingUnavailable {
    ALWAYS_THINKS,
    CLAUDE_MODEL,
    REASONING_SPLIT,
    NO_PARAMETER,
}

/**
 * Model-aware thinking-off rules, matching the Mac's `LLMProvider`.
 * A provider alone is not enough: some models always reason and reject the
 * parameter, so the switch has to follow the selected model.
 */
object ThinkingPolicy {
    private val claudeModelsAcceptingDisabledThinking = listOf(
        "claude-haiku-5-5", "claude-haiku-4-5",
        "claude-sonnet-5", "claude-opus-5",
        "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5",
        "claude-sonnet-4-6", "claude-sonnet-4-5",
    )

    private val openAIModelsAcceptingNoReasoning = listOf(
        "gpt-6-luna", "gpt-6.1-terra", "gpt-6-sol",
        "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol",
        "gpt-5.5", "gpt-5.4-mini",
    )

    /** Thinking is off by default, except on OpenRouter where reasoning can be mandatory. */
    fun defaultDisabled(providerId: String): Boolean = key(providerId) != "openrouter"

    fun fieldFor(providerId: String, model: String): ThinkingField? {
        val id = key(providerId)
        val name = model.trim().lowercase()
        return when (id) {
            "volcengine", "deepseek", "mimo" -> ThinkingField.THINKING
            "moonshot" -> if (alwaysThinks(id, name)) null else ThinkingField.THINKING
            "zhipu" -> if (alwaysThinks(id, name)) null else ThinkingField.THINKING
            "bailian" -> ThinkingField.ENABLE_THINKING
            "openai" -> if (openAIModelsAcceptingNoReasoning.any { matches(name, it) }) {
                ThinkingField.REASONING_EFFORT
            } else {
                null
            }
            "claude" -> if (claudeOffType(name) != null) ThinkingField.THINKING else null
            "openrouter" -> ThinkingField.REASONING
            else -> null
        }
    }

    /** Anthropic's `thinking.type` for this model, or null when it can't be disabled. */
    fun claudeOffType(model: String): String? {
        val name = model.trim().lowercase()
        if (matches(name, "claude-sonnet-5-5")) return "between_tools"
        return if (claudeModelsAcceptingDisabledThinking.any { matches(name, it) }) {
            "disabled"
        } else {
            null
        }
    }

    fun supports(providerId: String, model: String): Boolean =
        fieldFor(providerId, model) != null

    fun unavailableReason(providerId: String, model: String): ThinkingUnavailable? {
        if (supports(providerId, model)) return null
        val id = key(providerId)
        val name = model.trim().lowercase()
        return when {
            alwaysThinks(id, name) -> ThinkingUnavailable.ALWAYS_THINKS
            id == "claude" -> ThinkingUnavailable.CLAUDE_MODEL
            id.startsWith("minimax") -> ThinkingUnavailable.REASONING_SPLIT
            else -> ThinkingUnavailable.NO_PARAMETER
        }
    }

    private fun alwaysThinks(providerId: String, model: String): Boolean = when (providerId) {
        "moonshot" -> model.startsWith("kimi-k3") || model.startsWith("kimi-k2.7-code")
        "zhipu" -> model.startsWith("glm-5.3")
        else -> false
    }

    private fun key(providerId: String): String = when (providerId.trim().lowercase()) {
        "doubao", "volcengine", "ark" -> "volcengine"
        "kimi", "moonshot" -> "moonshot"
        "zhipu", "glm" -> "zhipu"
        "anthropic", "claude" -> "claude"
        "minimax", "minimaxcn", "minimaxintl" -> "minimax"
        else -> providerId.trim().lowercase()
    }

    /** Exact model ID or a dated snapshot, not a sibling such as `-pro`. */
    private fun matches(model: String, id: String): Boolean {
        if (!model.startsWith(id)) return false
        val suffix = model.substring(id.length)
        return suffix.isEmpty() ||
            (suffix.startsWith("-") && suffix.getOrNull(1)?.isDigit() == true && suffix.length >= 6)
    }
}
