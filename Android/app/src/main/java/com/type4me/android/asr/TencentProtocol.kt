package com.type4me.android.asr

import org.json.JSONArray
import org.json.JSONObject
import java.util.TreeMap

/**
 * Tencent Cloud realtime ASR V2 wire format (sentence stream) plus the hotword list
 * and error text shared by the realtime and recording-file (RecTask) paths.
 */
object TencentProtocol {
    const val ENGINE_MODEL_TYPE = "16k_zh_en_2.0"
    const val WS_HOST = "asr.cloud.tencent.com"
    const val WS_PATH_PREFIX = "/asr/v2/"
    const val API_HOST = "asr.tencentcloudapi.com"
    const val API_SERVICE = "asr"
    const val API_VERSION = "2019-06-14"
    const val MAX_HOTWORDS = 128
    const val MAX_HOTWORD_LENGTH = 30
    const val MAX_HOTWORD_HAN_CHARACTERS = 10
    const val HOTWORD_WEIGHT = 10

    data class SentenceUpdate(val id: Int, val text: String, val final: Boolean)

    data class RealtimeMessage(
        val code: Int,
        val message: String?,
        val voiceId: String?,
        val updates: List<SentenceUpdate>,
        val final: Boolean,
    )

    fun decode(text: String): RealtimeMessage? {
        val root = runCatching { JSONObject(text) }.getOrNull() ?: return null
        if (!root.has("code")) return null
        val updates = mutableListOf<SentenceUpdate>()
        val result = root.optJSONObject("result")
        if (result != null) {
            updates.add(
                SentenceUpdate(
                    id = result.optInt("index", 0),
                    text = result.optString("voice_text_str"),
                    final = result.optInt("slice_type", 0) == 2,
                ),
            )
        } else {
            when (val sentences = root.opt("sentences")) {
                is JSONArray -> for (index in 0 until sentences.length()) {
                    sentences.optJSONObject(index)?.let { updates.add(sentence(it)) }
                }
                is JSONObject -> updates.add(sentence(sentences))
            }
        }
        val message = if (root.isNull("message")) null else root.optString("message").takeIf { it.isNotBlank() }
        val voiceId = if (root.isNull("voice_id")) null else root.optString("voice_id").takeIf { it.isNotBlank() }
        return RealtimeMessage(
            code = root.optInt("code", 0),
            message = message,
            voiceId = voiceId,
            updates = updates,
            final = root.optInt("final", 0) == 1,
        )
    }

    fun liveParameters(hotwords: List<String>): Map<String, String> {
        val parameters = linkedMapOf(
            "engine_model_type" to ENGINE_MODEL_TYPE,
            "voice_format" to "1",
            "needvad" to "1",
            "sentence_strategy" to "0",
            "filter_dirty" to "0",
            "filter_modal" to "0",
            "convert_num_mode" to "1",
            "filter_empty_result" to "1",
        )
        formatHotwords(hotwords)?.let { parameters["hotword_list"] = it }
        return parameters
    }

    /** `term|10` entries joined by commas; terms with whitespace, commas or pipes are dropped. */
    fun formatHotwords(hotwords: List<String>): String? {
        val seen = mutableSetOf<String>()
        val terms = mutableListOf<String>()
        for (raw in hotwords) {
            val term = raw.trim()
            if (term.isEmpty()) continue
            if (term.any { it == ' ' || it == '\t' || it == ',' || it == '，' || it == '|' }) continue
            if (term.length > MAX_HOTWORD_LENGTH) continue
            if (term.count { isHan(it) } > MAX_HOTWORD_HAN_CHARACTERS) continue
            if (!seen.add(term.lowercase())) continue
            terms.add("$term|$HOTWORD_WEIGHT")
            if (terms.size >= MAX_HOTWORDS) break
        }
        return if (terms.isEmpty()) null else terms.joinToString(",")
    }

    fun serverErrorText(code: Int, rawMessage: String): String = when (code) {
        4002 -> if (rawMessage.contains("AppID") || rawMessage.contains("appid")) {
            "Tencent Cloud auth failed. Check the AppID (usually 10 digits starting with 125/130) ($code)"
        } else {
            "Invalid Tencent Cloud SecretId or SecretKey ($code)"
        }
        4003 -> "ASR is not enabled for this AppID. Enable it in the console. ($code)"
        4004 -> "ASR resource pack exhausted. Buy a pack or enable pay-as-you-go. ($code)"
        4005 -> "The Tencent Cloud account is in arrears. Top up and retry. ($code)"
        4006 -> "Concurrency limit reached. Try again later. ($code)"
        4008 -> "No audio data sent for over 15 seconds ($code)"
        6001 -> "Detected as an overseas call; bypass the proxy for ASR ($code)"
        in 5000..5002 -> "Tencent Cloud is temporarily unavailable. Retry. ($code)"
        else -> if (rawMessage.isNotBlank()) "$rawMessage ($code)" else "Tencent Cloud ASR service error ($code)"
    }

    fun apiErrorText(code: String, message: String): String {
        if (code.startsWith("AuthFailure")) {
            return if (code == "AuthFailure.SignatureExpire") {
                "Tencent Cloud signature expired. Please check the system clock. ($code)"
            } else {
                "Invalid Tencent Cloud SecretId or SecretKey ($code)"
            }
        }
        if (code.startsWith("UnauthorizedOperation")) {
            return "Insufficient sub-account permissions. Grant ASR permissions in CAM. ($code)"
        }
        if (code == "FailedOperation.NoSuchTask") {
            return "Tencent Cloud task not found or expired. ($code)"
        }
        if (code.startsWith("FailedOperation")) {
            return "${message.ifBlank { "Tencent Cloud operation failed" }} ($code)"
        }
        if (code.startsWith("InvalidParameter") || code == "MissingParameter") {
            return "${message.ifBlank { "Invalid request parameter" }} ($code)"
        }
        if (code.startsWith("RequestLimitExceeded")) {
            return "Tencent Cloud request limit exceeded. Try again later. ($code)"
        }
        if (code.startsWith("InternalError")) {
            return "Tencent Cloud is temporarily unavailable. Retry. ($code)"
        }
        return "Tencent Cloud $code: $message"
    }

    /** Strips the `[0:0.5]` timing prefixes from a RecTask result and joins the segments. */
    fun cleanResultText(result: String): String {
        val lines = result.split('\n')
            .map { TIMING_PREFIX.replace(it, "").trim() }
            .filter { it.isNotEmpty() }
        if (lines.isEmpty()) return ""
        val buffer = StringBuilder(lines.first())
        for (line in lines.drop(1)) {
            if (shouldInsertSpace(buffer.last(), line.first())) buffer.append(' ')
            buffer.append(line)
        }
        return buffer.toString()
    }

    private fun sentence(json: JSONObject): SentenceUpdate = SentenceUpdate(
        id = json.optInt("sentence_id", 0),
        text = json.optString("sentence"),
        final = json.optInt("sentence_type", 0) == 1,
    )

    private fun shouldInsertSpace(last: Char, next: Char): Boolean {
        if (isHan(last) || isHan(next)) return false
        val cjkPunctuation = "。，、？！；：“”‘’（）《》【】…—"
        if (cjkPunctuation.contains(last) || cjkPunctuation.contains(next)) return false
        return true
    }

    private fun isHan(char: Char): Boolean =
        char.code in 0x4E00..0x9FFF ||
            char.code in 0x3400..0x4DBF ||
            char.code in 0xF900..0xFAFF

    private val TIMING_PREFIX = Regex("""^\s*\[[^\]]*]\s*""")
}

/**
 * Orders the sentence stream: finalized sentences keep their slot, the trailing
 * in-progress sentences are replaced as they grow.
 */
class TencentTranscriptState {
    private val sentences = TreeMap<Int, String>()
    private val confirmedIds = mutableSetOf<Int>()
    private var completed = false

    val isCompleted: Boolean get() = completed

    fun apply(update: TencentProtocol.SentenceUpdate) {
        if (update.id in confirmedIds) return
        sentences[update.id] = update.text
        if (update.final) confirmedIds.add(update.id)
    }

    fun markFinal() {
        completed = true
        confirmedIds.addAll(sentences.keys)
    }

    val text: String
        get() {
            val confirmed = StringBuilder()
            val partial = StringBuilder()
            for ((id, value) in sentences) {
                if (value.isEmpty()) continue
                if (id in confirmedIds) confirmed.append(value) else partial.append(value)
            }
            return if (completed) confirmed.toString() else confirmed.toString() + partial
        }
}
