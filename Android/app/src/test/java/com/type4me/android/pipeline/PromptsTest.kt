package com.type4me.android.pipeline

import com.type4me.android.data.TranslateTarget
import org.junit.Assert.assertTrue
import org.junit.Test

class PromptsTest {
    @Test
    fun translationNamesTheTargetLanguage() {
        val prompt = Prompts.translatePrompt(TranslateTarget.JAPANESE, "hello")
        assertTrue(prompt.contains("Japanese"))
        assertTrue(prompt.contains("hello"))
    }

    @Test
    fun rewriteTemplatesCarryTheTranscriptPlaceholder() {
        assertTrue(Prompts.polishTemplate.contains("{text}"))
        assertTrue(Prompts.agentTemplate.contains("{text}"))
        assertTrue(Prompts.polishTemplate.contains("语音识别"))
    }

    @Test
    fun customPromptWithPlaceholderBecomesOneMessage() {
        val request = Prompts.request(
            context = null,
            mode = ModeDefinition(
                id = "custom",
                kind = Mode.CUSTOM,
                prompt = "整理：{text}",
            ),
            text = "原话",
        )
        assertTrue(request != null)
    }
}
