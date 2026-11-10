package com.type4me.android.pipeline

import org.json.JSONObject

data class CorrectionRequest(
    val selected: String,
    val before: String = "",
    val after: String = "",
    /** Spellings the user already rejected, oldest first. */
    val attempts: List<String> = emptyList(),
    /** Correct the word just before the cursor, left by the last correction. */
    val again: Boolean = false,
)

data class CorrectionOccurrence(
    /** 1-based, in reading order; the number the prompt marks it with. */
    val number: Int,
    /** Characters from the start of the selection, negative before it. */
    val offset: Int,
)

data class CorrectionResult(
    val replacement: String,
    val also: List<Int>,
)

/** Turns "the selection is wrong, and here is what I said" into replacement text. */
object Correction {
    fun request(
        correction: CorrectionRequest,
        spoken: String,
        chinese: Boolean,
    ): Prompts.Request = Prompts.Request(
        system = if (chinese) systemZh else systemEn,
        user = userText(correction, spoken, chinese),
    )

    fun resolve(
        raw: String,
        selected: String,
        attempts: List<String> = emptyList(),
        occurrenceCount: Int = 0,
    ): CorrectionResult? {
        val start = raw.indexOf('{')
        val end = raw.lastIndexOf('}')
        if (start < 0 || end <= start) return null
        val json = runCatching { JSONObject(raw.substring(start, end + 1)) }.getOrNull() ?: return null
        if (json.isNull("replacement")) return null
        val replacement = json.optString("replacement").trim()
        if (replacement.isEmpty()) return null
        if (replacement == selected.trim()) return null
        if (attempts.any { it.trim() == replacement }) return null
        val also = buildSet {
            val array = json.optJSONArray("also") ?: return@buildSet
            for (index in 0 until array.length()) {
                val number = array.optInt(index, 0)
                if (number in 1..occurrenceCount) add(number)
            }
        }.sorted()
        return CorrectionResult(replacement, also)
    }

    /** Other places in the visible text that read exactly like the selection. */
    fun occurrences(before: String, selected: String, after: String): List<CorrectionOccurrence> {
        if (selected.isEmpty()) return emptyList()
        val ahead = starts(selected, before).map { it - before.length }
        val behind = starts(selected, after).map { it + selected.length }
        return (ahead + behind).mapIndexed { index, offset ->
            CorrectionOccurrence(index + 1, offset)
        }
    }

    private fun starts(needle: String, haystack: String): List<Int> {
        if (needle.isEmpty() || needle.length > haystack.length) return emptyList()
        val result = mutableListOf<Int>()
        var index = 0
        while (index + needle.length <= haystack.length) {
            if (haystack.regionMatches(index, needle, 0, needle.length)) {
                result += index
                index += needle.length
            } else {
                index += 1
            }
        }
        return result
    }

    /** The visible text with the selection marked ⟦*⟧ and other matches ⟦n⟧. */
    fun markedText(request: CorrectionRequest): String {
        val length = request.selected.length
        val occurrences = occurrences(request.before, request.selected, request.after)
        var before = request.before
        var after = request.after
        for (occurrence in occurrences.reversed()) {
            val open = "⟦${occurrence.number}⟧"
            val close = "⟦/${occurrence.number}⟧"
            if (occurrence.offset < 0) {
                val start = (before.length + occurrence.offset).coerceIn(0, before.length)
                before = before.substring(0, start) + open +
                    before.substring(start, (start + length).coerceAtMost(before.length)) + close +
                    before.substring((start + length).coerceAtMost(before.length))
            } else {
                val start = (occurrence.offset - length).coerceIn(0, after.length)
                after = after.substring(0, start) + open +
                    after.substring(start, (start + length).coerceAtMost(after.length)) + close +
                    after.substring((start + length).coerceAtMost(after.length))
            }
        }
        return before + "⟦*⟧" + request.selected + "⟦/*⟧" + after
    }

    private fun userText(request: CorrectionRequest, spoken: String, chinese: Boolean): String {
        val attempts = if (request.attempts.isEmpty()) {
            if (chinese) "（无）" else "(none)"
        } else {
            request.attempts.joinToString(if (chinese) "、" else ", ") { "「$it」" }
        }
        return if (chinese) {
            "原文：\n${markedText(request)}\n\n用户说的话（语音识别结果）：$spoken\n已被否定的写法：$attempts"
        } else {
            "Text:\n${markedText(request)}\n\nWhat the user said (speech recognition): $spoken\nAlready rejected: $attempts"
        }
    }

    private val systemZh = """
        你在帮用户修正语音输入里识别错的文字。原文中用 ⟦*⟧…⟦/*⟧ 标出的部分识别错了，用户刚才口头说明了正确内容。

        规则：
        1. 用户的话也经过了语音识别，可能同样有误。如果它和被标出的内容相同或读音相近，说明这是同音或近音错误，请根据上下文推断最可能的正确写法，不要原样返回。
        2. 用户可能直接说出正确内容，也可能带着解释，比如“叹气那个欸”“姓张，弓长张”“是英文缩写”。只返回最终应写入的文字，不要把解释写进去。
        3. 用户也可能把整段完整地重说一遍，这时直接返回重说的内容。
        4. 用户也可能说明为什么错、本来想表达什么意思。这时结合上下文和用户的描述，推断最可能的正确写法。用户话里提到的错误写法不是答案。
        5. 返回的内容必须和被标出的内容不同。“已被否定的写法”里的内容也不能再给，此时给出下一个最可能的写法。
        6. 原文里 ⟦1⟧、⟦2⟧ 等标出的是和被标出内容相同的其他位置。逐个判断它们是不是同一个错误，是的放进 also。
        7. 只输出 JSON，不要输出其他文字：{"replacement": "正确写法", "also": [编号]}。只要用户的话里有任何线索，就给出最可能的写法；只有完全无法推断时，才输出 {"replacement": null}。
    """.trimIndent()

    private val systemEn = """
        You fix words that speech recognition got wrong. In the text, the part marked ⟦*⟧…⟦/*⟧ was misrecognized, and the user just said what it should be.

        Rules:
        1. What the user said also went through speech recognition and may be wrong the same way. If it matches or sounds like the marked part, infer the most likely spelling from context instead of returning it unchanged.
        2. The user may say the right words directly or explain them. Return only the text to write, never the explanation.
        3. The user may also say the whole passage again; then return what they said.
        4. If the user explains what they meant, infer the most likely spelling from the context and their description. A wrong spelling they mention is not the answer.
        5. Your answer must differ from the marked part. Never return anything listed as already rejected either; give the next most likely spelling instead.
        6. Places marked ⟦1⟧, ⟦2⟧ and so on read the same as the marked part. Decide for each whether it is the same mistake, and list those in "also".
        7. Output JSON only, nothing else: {"replacement": "the right text", "also": [numbers]}. Whenever what the user said gives any clue, give the most likely spelling; output {"replacement": null} only when nothing in their words or the context lets you infer it.
    """.trimIndent()
}
