package com.type4me.android.pipeline

import android.content.Context
import com.type4me.android.data.CjkSpacing
import com.type4me.android.data.Snippet
import com.type4me.android.data.TextOutputStore
import com.type4me.android.data.TrailingPunctuation

object TextPipeline {
    /**
     * Snippet triggers match ignoring case and whitespace, with ASCII word
     * boundaries so a Chinese trigger still matches next to Chinese text.
     * Rules run in list order over the previous rule's output.
     */
    fun applySnippets(text: String, snippets: List<Snippet>): String =
        snippets.fold(text) { result, snippet ->
            val trigger = snippet.trigger.filterNot { it.isWhitespace() }
            if (trigger.isEmpty()) return@fold result
            val pattern = buildString {
                append("(?<![A-Za-z0-9])")
                trigger.forEachIndexed { index, char ->
                    if (index > 0) append("\\s*")
                    append(Regex.escape(char.toString()))
                }
                append("(?![A-Za-z0-9])")
            }
            runCatching {
                Regex(pattern, RegexOption.IGNORE_CASE)
                    .replace(result) { snippet.replacement }
            }.getOrDefault(result)
        }

    fun clean(text: String): String = text.trim()

    /** The shared text cleanup, matching the app's Text Output settings. */
    fun format(
        text: String,
        context: Context,
        modePunctuation: ModePunctuation = ModePunctuation.INHERIT,
    ): String = format(
        text = text,
        spacing = TextOutputStore.spacing(context),
        punctuation = TextOutputStore.punctuation(context),
        cornerQuotes = TextOutputStore.cornerQuotes(context),
        modePunctuation = modePunctuation,
    )

    fun format(text: String, spacing: CjkSpacing, punctuation: TrailingPunctuation): String =
        format(text, spacing, punctuation, cornerQuotes = false, modePunctuation = ModePunctuation.INHERIT)

    fun format(
        text: String,
        spacing: CjkSpacing,
        punctuation: TrailingPunctuation,
        cornerQuotes: Boolean,
        modePunctuation: ModePunctuation,
    ): String {
        var result = text
        if (cornerQuotes) {
            result = result.replace('‘', '『').replace('’', '』')
        }
        when (spacing) {
            CjkSpacing.PANGU -> result = spaceBetweenHanAndLatin(result)
            CjkSpacing.KEEP -> Unit
            CjkSpacing.REMOVE -> result = removeSpaceBetweenHanAndLatin(result)
        }
        result = when (modePunctuation) {
            ModePunctuation.INHERIT -> applyPunctuation(result, punctuation)
            ModePunctuation.PRESERVE -> result
            ModePunctuation.STRIP_TRAILING -> result.replace(TRAILING_PUNCTUATION, "")
            ModePunctuation.QUESTIONS_AND_EXCLAMATIONS -> result.replace(KEEP_QUESTIONS, "")
            ModePunctuation.REMOVE_ALL -> result.replace(ALL_PUNCTUATION, "")
        }
        return result.trim()
    }

    private fun applyPunctuation(text: String, punctuation: TrailingPunctuation): String =
        when (punctuation) {
            TrailingPunctuation.KEEP -> text
            TrailingPunctuation.PERIOD -> text.replace(TRAILING_PERIOD, "")
            TrailingPunctuation.ALL -> text.replace(TRAILING_PUNCTUATION, "")
        }

    private val KEEP_QUESTIONS = Regex("[，。、；：,.;:]+\\s*$")
    private val ALL_PUNCTUATION = Regex("[\\p{P}\\p{S}]")

    private val TRAILING_PERIOD = Regex("[。.]+\\s*$")
    private val TRAILING_PUNCTUATION = Regex("[，。！？；：、,.!?;:]+\\s*$")

    private fun isHan(codePoint: Int): Boolean =
        Character.UnicodeScript.of(codePoint) == Character.UnicodeScript.HAN

    private fun isLatin(codePoint: Int): Boolean =
        codePoint in 'A'.code..'Z'.code ||
            codePoint in 'a'.code..'z'.code ||
            codePoint in '0'.code..'9'.code

    private fun spaceBetweenHanAndLatin(text: String): String {
        val out = StringBuilder(text.length + 8)
        var previous = -1
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            val crosses = previous >= 0 &&
                ((isHan(previous) && isLatin(codePoint)) || (isLatin(previous) && isHan(codePoint)))
            if (crosses && out.isNotEmpty() && out.last() != ' ' && out.last() != '\n') {
                out.append(' ')
            }
            out.appendCodePoint(codePoint)
            previous = codePoint
            index += Character.charCount(codePoint)
        }
        return out.toString()
    }

    private fun removeSpaceBetweenHanAndLatin(text: String): String {
        val out = StringBuilder(text.length)
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            if (codePoint == ' '.code && isSpaceBetweenScripts(text, index)) {
                index += 1
                continue
            }
            out.appendCodePoint(codePoint)
            index += Character.charCount(codePoint)
        }
        return out.toString()
    }

    private fun isSpaceBetweenScripts(text: String, index: Int): Boolean {
        var before = index - 1
        while (before >= 0 && text[before] == ' ') before--
        var after = index + 1
        while (after < text.length && text[after] == ' ') after++
        if (before < 0 || after >= text.length) return false
        val left = text.codePointBefore(before + 1)
        val right = text.codePointAt(after)
        return (isHan(left) && isLatin(right)) || (isLatin(left) && isHan(right))
    }
}
