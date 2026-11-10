package com.type4me.android.llm

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ThinkingPolicyTest {

    @Test
    fun `direct Chinese providers send disabled thinking`() {
        assertEquals(ThinkingField.THINKING, ThinkingPolicy.fieldFor("volcengine", "doubao-pro"))
        assertEquals(ThinkingField.THINKING, ThinkingPolicy.fieldFor("deepseek", "deepseek-reasoner"))
        assertEquals(ThinkingField.THINKING, ThinkingPolicy.fieldFor("mimo", "mimo-v2-flash"))
        assertEquals(ThinkingField.ENABLE_THINKING, ThinkingPolicy.fieldFor("bailian", "qwen-plus"))
    }

    @Test
    fun `kimi and GLM models that always think skip the parameter`() {
        assertNull(ThinkingPolicy.fieldFor("moonshot", "kimi-k3-preview"))
        assertNull(ThinkingPolicy.fieldFor("moonshot", "kimi-k2.7-code"))
        assertEquals(ThinkingField.THINKING, ThinkingPolicy.fieldFor("moonshot", "kimi-k2.5"))
        assertNull(ThinkingPolicy.fieldFor("zhipu", "glm-5.3"))
        assertEquals(ThinkingField.THINKING, ThinkingPolicy.fieldFor("zhipu", "glm-4.7"))
        assertEquals(
            ThinkingUnavailable.ALWAYS_THINKS,
            ThinkingPolicy.unavailableReason("moonshot", "kimi-k3-preview"),
        )
    }

    @Test
    fun `OpenAI only sends none for models that accept it`() {
        assertEquals(ThinkingField.REASONING_EFFORT, ThinkingPolicy.fieldFor("openai", "gpt-5.5"))
        assertEquals(
            ThinkingField.REASONING_EFFORT,
            ThinkingPolicy.fieldFor("openai", "gpt-5.5-2026-04-23"),
        )
        assertNull(ThinkingPolicy.fieldFor("openai", "gpt-4o-mini"))
        assertNull(ThinkingPolicy.fieldFor("openai", "gpt-5-mini"))
        assertEquals(
            ThinkingUnavailable.NO_PARAMETER,
            ThinkingPolicy.unavailableReason("openai", "gpt-4o-mini"),
        )
    }

    @Test
    fun `Claude picks disabled between tools and unsupported per model`() {
        assertEquals("disabled", ThinkingPolicy.claudeOffType("claude-sonnet-4-5"))
        assertEquals("between_tools", ThinkingPolicy.claudeOffType("claude-sonnet-5-5"))
        assertNull(ThinkingPolicy.claudeOffType("claude-opus-5-5"))
        assertEquals(
            ThinkingField.THINKING,
            ThinkingPolicy.fieldFor("claude", "claude-haiku-4-5"),
        )
        assertNull(ThinkingPolicy.fieldFor("claude", "claude-opus-5-5"))
        assertEquals(
            ThinkingUnavailable.CLAUDE_MODEL,
            ThinkingPolicy.unavailableReason("claude", "claude-opus-5-5"),
        )
    }

    @Test
    fun `OpenRouter and MiniMax follow the desktop defaults`() {
        assertFalse(ThinkingPolicy.defaultDisabled("openrouter"))
        assertTrue(ThinkingPolicy.defaultDisabled("deepseek"))
        assertEquals(ThinkingField.REASONING, ThinkingPolicy.fieldFor("openrouter", "x-ai/grok"))
        assertNull(ThinkingPolicy.fieldFor("gemini", "gemini-2.5-flash"))
        assertEquals(
            ThinkingUnavailable.REASONING_SPLIT,
            ThinkingPolicy.unavailableReason("minimaxCN", "MiniMax-M2.7"),
        )
    }
}
