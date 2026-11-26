package com.type4me.android.pipeline

/**
 * A light language check after a translation. It cannot prove a translation
 * is good, but it catches the common failure: the model answers in the source
 * language, explains itself, or returns the input unchanged.
 */
object TranslationValidator {
    data class Result(val retry: Boolean)

    /** Every target only needs this much output in its own script. */
    private const val REQUIRED_SCRIPT_RATIO = 0.35

    fun check(output: String, target: TranslateTarget, raw: String): Result {
        val text = output.trim()
        if (text.isEmpty()) return Result(true)
        if (text.contains("```") || text.contains("<think>")) return Result(true)
        if (looksLikeExplanation(text)) return Result(true)
        val letters = countLetters(text)
        if (letters == 0) return Result(false)
        // Latin-script targets only need Latin output; CJK, Arabic,
        // Devanagari, Thai and Cyrillic have an unmistakable script.
        if (scriptRatio(text, target) < REQUIRED_SCRIPT_RATIO) return Result(true)
        // Script alone cannot verify a same-script pair (en→es, zh-Hans→zh-Hant);
        // only an unchanged source in another script is reliably detectable.
        if (text == raw.trim() && targetScriptDiffers(target, raw)) return Result(true)
        return Result(false)
    }

    private fun scriptRatio(text: String, target: TranslateTarget): Double {
        val letters = countLetters(text).coerceAtLeast(1)
        var matching = 0
        forEachCodePoint(text) { codePoint ->
            if (!Character.isLetter(codePoint)) return@forEachCodePoint
            if (matchesTargetScript(codePoint, target)) matching++
        }
        return matching.toDouble() / letters
    }

    private fun countLetters(text: String): Int {
        var count = 0
        forEachCodePoint(text) { codePoint ->
            if (Character.isLetter(codePoint)) count++
        }
        return count
    }

    private fun forEachCodePoint(text: String, action: (Int) -> Unit) {
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            action(codePoint)
            index += Character.charCount(codePoint)
        }
    }

    private fun matchesTargetScript(codePoint: Int, target: TranslateTarget): Boolean {
        val script = Character.UnicodeScript.of(codePoint)
        return when (target) {
            TranslateTarget.SIMPLIFIED_CHINESE,
            TranslateTarget.TRADITIONAL_CHINESE,
            -> script == Character.UnicodeScript.HAN

            TranslateTarget.JAPANESE ->
                script == Character.UnicodeScript.HIRAGANA ||
                    script == Character.UnicodeScript.KATAKANA ||
                    script == Character.UnicodeScript.HAN

            TranslateTarget.KOREAN -> script == Character.UnicodeScript.HANGUL
            TranslateTarget.ARABIC -> script == Character.UnicodeScript.ARABIC
            TranslateTarget.HINDI -> script == Character.UnicodeScript.DEVANAGARI
            TranslateTarget.THAI -> script == Character.UnicodeScript.THAI
            TranslateTarget.RUSSIAN -> script == Character.UnicodeScript.CYRILLIC
            else -> script == Character.UnicodeScript.LATIN
        }
    }

    private fun targetScriptDiffers(target: TranslateTarget, raw: String): Boolean =
        scriptRatio(raw, target) < REQUIRED_SCRIPT_RATIO

    private fun looksLikeExplanation(text: String): Boolean {
        val lower = text.trimStart().lowercase()
        val zh = listOf("以下是", "这是", "翻译如下", "译文：", "当然，", "我为你")
        if (zh.any { lower.startsWith(it) }) return true
        val en = listOf("here is", "here's", "sure,", "certainly,", "the translation")
        return en.any { lower.startsWith(it) }
    }
}
