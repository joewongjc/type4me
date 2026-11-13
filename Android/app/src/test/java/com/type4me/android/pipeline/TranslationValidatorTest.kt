package com.type4me.android.pipeline

import org.junit.Assert.assertFalse
import org.junit.Test

class TranslationValidatorTest {
    @Test
    fun countsSupplementaryLatinLettersAsOneCodePoint() {
        val text = String(Character.toChars(0x10400)).repeat(3) + "日本語"
        assertFalse(TranslationValidator.check(text, TranslateTarget.JAPANESE, "原文").retry)
    }
}
