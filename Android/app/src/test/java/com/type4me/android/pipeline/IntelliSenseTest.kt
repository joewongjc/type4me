package com.type4me.android.pipeline

import org.junit.Assert.assertEquals
import org.junit.Test

class IntelliSenseTest {
    @Test
    fun acceptsALightEdit() {
        val input = "嗯那个我们明天下午3点开会"
        val output = "我们明天下午 3 点开会。"
        assertEquals(output, IntelliSense.check(input, output))
    }

    @Test
    fun rejectsAnAnswerInsteadOfAPolish() {
        val input = "这次复盘有几个问题"
        val output = "以下是整理后的内容：有三个问题。"
        assertEquals(input, IntelliSense.check(input, output))
    }

    @Test
    fun rejectsATranslationOfChineseDictation() {
        val input = "明天下午三点的会议改到四点"
        val output = "The meeting tomorrow is moved to four."
        assertEquals(input, IntelliSense.check(input, output))
    }

    @Test
    fun rejectsADroppedNumber() {
        val input = "预算 12000 元"
        val output = "预算是一万元。"
        assertEquals(input, IntelliSense.check(input, output))
    }

    @Test
    fun detectsCredentialsButNotOrdinaryText() {
        assertEquals(false, SensitiveText.contains("明天下午三点开会"))
        assertEquals(true, SensitiveText.contains("api_key = sk-abcdefghijklmnop"))
        assertEquals(true, SensitiveText.contains("卡号 4242 4242 4242 4242"))
    }
}
