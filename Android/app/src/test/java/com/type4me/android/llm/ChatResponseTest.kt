package com.type4me.android.llm

import org.junit.Assert.assertEquals
import org.junit.Test

class ChatResponseTest {
    @Test
    fun readsTheAssistantMessage() {
        val body = """
            {"choices":[{"message":{"role":"assistant","content":"整理后的文字。"}}]}
        """.trimIndent()
        assertEquals("整理后的文字。", ChatResponse.text(body))
    }

    @Test
    fun removesThinkingBlocks() {
        val body = """
            {"choices":[{"message":{"content":"<think>hidden</think>可见内容"}}]}
        """.trimIndent()
        assertEquals("可见内容", ChatResponse.text(body))
    }

    @Test
    fun removesUnclosedThinkingPrefix() {
        val body = """
            {"choices":[{"message":{"content":"推理过程</think>最终答案"}}]}
        """.trimIndent()
        assertEquals("最终答案", ChatResponse.text(body))
    }

    @Test
    fun removesThinkingAndReasoningBlocks() {
        val body = """
            {"choices":[{"message":{"content":"<thinking>plan</thinking><reasoning>why</reasoning>答案"}}]}
        """.trimIndent()
        assertEquals("答案", ChatResponse.text(body))
    }

    @Test
    fun removesUnclosedReasoningPrefix() {
        val body = """
            {"choices":[{"message":{"content":"推理</reasoning>答案"}}]}
        """.trimIndent()
        assertEquals("答案", ChatResponse.text(body))
    }

    @Test
    fun stripsOuterQuotes() {
        val body = """
            {"choices":[{"message":{"content":"“你好。”"}}]}
        """.trimIndent()
        assertEquals("你好。", ChatResponse.text(body))
    }

    @Test(expected = ChatException::class)
    fun rejectsAnEmptyChoiceList() {
        ChatResponse.text("""{"choices":[]}""")
    }
}
