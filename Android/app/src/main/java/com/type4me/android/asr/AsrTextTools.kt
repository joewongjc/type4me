package com.type4me.android.asr

import com.type4me.android.data.AsrConfig

/**
 * Transcript text helpers shared by the streaming protocols, ported from the
 * Mac client so both platforms stitch segments the same way.
 */
internal object AsrTextTools {
    /** Joins `segment` after `existing`, adding a space only between Latin words. */
    fun normalizeSegment(segment: String, existing: String): String {
        if (segment.isEmpty()) return segment
        val last = existing.lastOrNull() ?: return segment
        val first = segment.first()
        if (last.isWhitespace() || first.isWhitespace()) return segment
        if (isClosingPunctuation(first) || isOpeningPunctuation(last)) return segment
        if (isCjk(last) || isCjk(first)) return segment
        return " $segment"
    }

    /** Strips the already-confirmed prefix from cumulative server partials. */
    fun stripConfirmedPrefix(text: String, confirmed: String): String {
        val trimmed = text.trim()
        if (confirmed.isEmpty()) return trimmed
        val prefix = confirmed.trim()
        if (trimmed.startsWith(prefix)) return trimmed.removePrefix(prefix).trim()
        return trimmed
    }

    /** Drops a leading hotword list echoed by the recognizer on short audio. */
    fun sanitizeHotwordLeak(text: String, hotwords: List<String>): String {
        val trimmedText = text.trim()
        if (trimmedText.isEmpty()) return ""
        val cleaned = hotwords.map { it.trim() }.filter { it.isNotEmpty() }
        if (cleaned.isEmpty()) return trimmedText

        val search = dropLeadingContextLabel(trimmedText)
        val match = bestPrefixMatch(search.text, cleaned) ?: return trimmedText
        // A single exact hotword may be a legitimate utterance; a labeled list
        // or a run of two or more is a prompt echo.
        if (!search.hadLabel && match.wordCount < 2) return trimmedText
        return match.remainder
    }

    /** Converts CJK punctuation to Latin style when the transcript is not CJK. */
    fun normalizePunctuation(languageCode: String, text: String): String {
        val language = languageCode.trim().lowercase()
        val useLatin = when {
            language in CJK_LANGUAGES -> false
            language.isNotEmpty() -> true
            else -> text.none { isCjk(it) }
        }
        if (!useLatin) return text
        return insertLatinPunctuationSpacing(text.map { CJK_TO_LATIN[it] ?: it }.joinToString(""))
    }

    fun isClosingPunctuation(character: Char): Boolean = character in ",.!?;:)]}\"'"

    fun isOpeningPunctuation(character: Char): Boolean = character in "([{/\"'"

    fun isCjk(character: Char): Boolean = when (character.code) {
        in 0x3400..0x4DBF, in 0x4E00..0x9FFF, in 0xF900..0xFAFF -> true
        else -> false
    }

    private fun insertLatinPunctuationSpacing(text: String): String {
        if (text.isEmpty()) return text
        val result = StringBuilder(text.length + 8)
        for (index in text.indices) {
            val character = text[index]
            result.append(character)
            if (index + 1 >= text.length) continue
            val next = text[index + 1]
            val previous = if (index > 0) text[index - 1] else null
            if (shouldInsertSpace(character, next, previous)) result.append(' ')
        }
        return result.toString()
    }

    private fun shouldInsertSpace(after: Char, before: Char, previous: Char?): Boolean {
        if (before.isWhitespace() || !isLatinWordCharacter(before)) return false
        if (after in ",;:!?") return true
        if (after == '.') {
            if (previous != null && previous.isDigit() && before.isDigit()) return false
            return true
        }
        return false
    }

    private fun isLatinWordCharacter(character: Char): Boolean =
        character.isLetter() && character.code < 128

    private data class LabelResult(val text: String, val hadLabel: Boolean)

    private data class PrefixMatch(
        val consumedText: String,
        val remainder: String,
        val wordCount: Int,
    )

    private val CONTEXT_LABELS = listOf(
        "Vocabulary:", "Vocabulary：", "Vocabulary",
        "Hotwords:", "Hotwords：", "Hotwords",
        "词汇：", "词汇:", "词汇表：", "词汇表:", "热词：", "热词:", "关键词：", "关键词:",
    )

    private val SEPARATOR_PUNCTUATION =
        ",，、;；:：|/\\-—_·.。.!！?？\"'“”‘’()（）[]【】<>《》"

    private fun isSeparator(character: Char): Boolean =
        character.isWhitespace() || SEPARATOR_PUNCTUATION.contains(character)

    private fun skipSeparators(text: String, from: Int): Int {
        var index = from
        while (index < text.length && isSeparator(text[index])) index++
        return index
    }

    private fun trimLeadingSeparators(text: String): String =
        text.substring(skipSeparators(text, 0)).trim()

    private fun dropLeadingContextLabel(text: String): LabelResult {
        val trimmed = trimLeadingSeparators(text)
        for (label in CONTEXT_LABELS) {
            if (trimmed.regionMatches(0, label, 0, label.length, ignoreCase = true)) {
                return LabelResult(trimLeadingSeparators(trimmed.substring(label.length)), true)
            }
        }
        return LabelResult(trimmed, false)
    }

    private fun bestPrefixMatch(text: String, hotwords: List<String>): PrefixMatch? {
        var best: PrefixMatch? = null
        for (start in hotwords.indices) {
            val candidate = prefixMatch(text, hotwords, start) ?: continue
            val current = best
            if (current == null ||
                candidate.wordCount > current.wordCount ||
                (candidate.wordCount == current.wordCount &&
                    candidate.consumedText.length > current.consumedText.length)
            ) {
                best = candidate
            }
        }
        return best
    }

    private fun prefixMatch(text: String, hotwords: List<String>, startIndex: Int): PrefixMatch? {
        var index = 0
        var consumedStart = -1
        var wordCount = 0
        for (hotwordIndex in startIndex until hotwords.size) {
            index = skipSeparators(text, index)
            if (consumedStart < 0) consumedStart = index
            val hotword = hotwords[hotwordIndex]
            if (!text.regionMatches(index, hotword, 0, hotword.length, ignoreCase = true)) break
            index += hotword.length
            wordCount++
        }
        if (wordCount == 0 || consumedStart < 0) return null
        return PrefixMatch(
            consumedText = text.substring(consumedStart, index),
            remainder = trimLeadingSeparators(text.substring(index)),
            wordCount = wordCount,
        )
    }

    private val CJK_LANGUAGES = setOf("zh", "zh-tw", "ja", "ko")

    private val CJK_TO_LATIN: Map<Char, Char> = mapOf(
        '，' to ',', '。' to '.', '！' to '!', '？' to '?', '；' to ';', '：' to ':',
        '（' to '(', '）' to ')', '【' to '[', '】' to ']',
        '\u201C' to '"', '\u201D' to '"', '\u2018' to '\'', '\u2019' to '\'',
        '、' to ',',
    )
}

internal fun AsrConfig.extraValue(key: String): String = extra[key]?.trim().orEmpty()

internal fun AsrConfig.firstExtraValue(vararg keys: String): String {
    for (key in keys) {
        val value = extraValue(key)
        if (value.isNotEmpty()) return value
    }
    return ""
}

internal fun AsrConfig.resolvedModel(default: String): String =
    model.trim().ifEmpty { extraValue("model") }.ifEmpty { default }

internal fun AsrConfig.resolvedBatchModel(default: String): String =
    extraValue("batchModel").ifEmpty { default }
