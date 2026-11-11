package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64

/**
 * Alibaba Cloud Bailian wire format: the duplex WebSocket used for streaming ASR and the
 * DashScope multimodal-generation endpoint used for batch uploads.
 */
object BailianProtocol {
    const val CHINA_ENDPOINT = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
    const val INTL_ENDPOINT = "wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference"
    const val CHINA_HOST = "dashscope.aliyuncs.com"
    const val INTL_HOST = "dashscope-intl.aliyuncs.com"
    const val DEFAULT_MODEL = "qwen-audio-3.1-asr-flash-streaming"
    const val DEFAULT_BATCH_MODEL = "qwen-audio-3.1-asr-flash"
    const val BATCH_PATH = "/api/v1/services/aigc/multimodal-generation/generation"
    /** DashScope answers silent audio with HTTP 400 and this marker. */
    const val NO_SPEECH_MARKER = "ASR_RESPONSE_HAVE_NO_WORDS"

    private val SUPPORTED_LANGUAGE_HINTS = setOf(
        "zh", "en", "ja", "ko", "fr", "de", "es", "ru", "it", "pt", "ar", "th", "vi", "id",
    )

    data class Settings(
        val endpoint: String,
        val baseUrl: String,
        val apiKey: String,
        val model: String,
        val batchModel: String,
        val languageHint: String,
        val vocabularyId: String,
    )

    data class Sentence(val text: String, val heartbeat: Boolean, val sentenceEnd: Boolean)

    sealed class Event {
        data class Started(val taskId: String?) : Event()
        data class SentenceEvent(val sentence: Sentence) : Event()
        object Finished : Event()
        data class Failed(val code: String?, val message: String?) : Event()
    }

    fun settings(config: AsrConfig): Settings {
        val international = config.extra["region"].orEmpty().trim().equals("international", ignoreCase = true)
        val baseUrl = config.baseUrl.trim()
        val regionKey = if (international) {
            config.extra["intlApiKey"].orEmpty()
        } else {
            config.apiKey
        }.trim().ifBlank { config.apiKey.trim() }
        val model = config.model.trim()
            .ifBlank { config.extra["model"].orEmpty().trim() }
            .ifBlank { DEFAULT_MODEL }
        val batchModel = config.extra["batchModel"].orEmpty().trim().ifBlank { DEFAULT_BATCH_MODEL }
        val languageHint = config.extra["languageHint"].orEmpty().trim().lowercase()
            .takeIf { it in SUPPORTED_LANGUAGE_HINTS }
            .orEmpty()
        return Settings(
            endpoint = endpoint(config),
            baseUrl = baseUrl,
            apiKey = regionKey,
            model = model,
            batchModel = batchModel,
            languageHint = languageHint,
            vocabularyId = config.extra["vocabularyId"].orEmpty().trim(),
        )
    }

    fun endpoint(config: AsrConfig): String {
        val international = config.extra["region"].orEmpty().trim().equals("international", ignoreCase = true)
        val fallback = if (international) INTL_ENDPOINT else CHINA_ENDPOINT
        val trimmed = config.baseUrl.trim()
        if (trimmed.isEmpty()) return fallback
        val lower = trimmed.lowercase()
        return when {
            lower.startsWith("wss://") || lower.startsWith("ws://") -> trimmed
            lower.startsWith("https://") -> "wss://" + trimmed.substring(8)
            lower.startsWith("http://") -> "ws://" + trimmed.substring(7)
            else -> fallback
        }
    }

    fun batchEndpoint(settings: Settings): String {
        val host = hostOf(settings.baseUrl)
            ?: if (settings.endpoint.contains(INTL_HOST)) INTL_HOST else CHINA_HOST
        return "https://$host$BATCH_PATH"
    }

    fun buildRunTaskMessage(config: AsrConfig, taskId: String): String {
        val settings = settings(config)
        val parameters = JSONObject()
            .put("format", "pcm")
            .put("sample_rate", 16_000)
            .put("semantic_punctuation_enabled", false)
            .put("max_sentence_silence", 800)
            .put("multi_threshold_mode_enabled", false)
            .put("heartbeat", false)
        if (settings.vocabularyId.isNotEmpty()) parameters.put("vocabulary_id", settings.vocabularyId)
        if (settings.languageHint.isNotEmpty()) {
            parameters.put("language_hints", JSONArray().put(settings.languageHint))
        }
        return JSONObject()
            .put(
                "header",
                JSONObject()
                    .put("action", "run-task")
                    .put("task_id", taskId)
                    .put("streaming", "duplex"),
            )
            .put(
                "payload",
                JSONObject()
                    .put("task_group", "audio")
                    .put("task", "asr")
                    .put("function", "recognition")
                    .put("model", settings.model)
                    .put("parameters", parameters)
                    .put("input", JSONObject()),
            )
            .toString()
    }

    fun buildFinishTaskMessage(taskId: String): String = JSONObject()
        .put(
            "header",
            JSONObject()
                .put("action", "finish-task")
                .put("task_id", taskId)
                .put("streaming", "duplex"),
        )
        .put("payload", JSONObject().put("input", JSONObject()))
        .toString()

    fun parseEvent(text: String): Event? {
        val root = runCatching { JSONObject(text) }.getOrElse {
            throw AsrException("Could not parse the Bailian response")
        }
        val header = root.optJSONObject("header") ?: return null
        val taskId = header.optString("task_id").takeIf { it.isNotBlank() }
        return when (header.optString("event")) {
            "task-started" -> Event.Started(taskId)
            "result-generated" -> {
                val sentence = root.optJSONObject("payload")
                    ?.optJSONObject("output")
                    ?.optJSONObject("sentence")
                    ?: return null
                Event.SentenceEvent(
                    Sentence(
                        text = sentence.optString("text"),
                        heartbeat = sentence.optBoolean("heartbeat", false),
                        sentenceEnd = sentence.optBoolean("sentence_end", false),
                    ),
                )
            }
            "task-finished" -> Event.Finished
            "task-failed" -> Event.Failed(
                code = header.optString("error_code").takeIf { it.isNotBlank() },
                message = header.optString("error_message").takeIf { it.isNotBlank() },
            )
            else -> null
        }
    }

    /** Batch request body for the DashScope flash model; audio is inlined as a base64 WAV data URL. */
    fun buildBatchBody(config: AsrConfig, wav: ByteArray): JSONObject {
        val settings = settings(config)
        val parameters = JSONObject()
            .put("format", "wav")
            .put("sample_rate", 16_000)
        if (settings.vocabularyId.isNotEmpty()) parameters.put("vocabulary_id", settings.vocabularyId)
        if (settings.languageHint.isNotEmpty()) {
            parameters.put("language_hints", JSONArray().put(settings.languageHint))
        }
        val content = JSONArray().put(
            JSONObject()
                .put("type", "input_audio")
                .put(
                    "input_audio",
                    JSONObject().put(
                        "data",
                        "data:audio/wav;base64," + Base64.getEncoder().encodeToString(wav),
                    ),
                ),
        )
        val messages = JSONArray().put(
            JSONObject().put("role", "user").put("content", content),
        )
        return JSONObject()
            .put("model", settings.batchModel)
            .put("input", JSONObject().put("messages", messages))
            .put("parameters", parameters)
    }

    fun parseBatchResponse(body: String): String {
        val root = runCatching { JSONObject(body) }.getOrElse {
            throw AsrException("Could not parse the Bailian response")
        }
        val output = root.optJSONObject("output")
            ?: throw AsrException("Bailian returned an invalid transcription response")
        stringAt(output, "text")?.takeIf { it.isNotBlank() }?.let { return it.trim() }
        val message = output.optJSONArray("choices")?.optJSONObject(0)?.optJSONObject("message")
        if (message != null) {
            stringAt(message, "content")?.takeIf { it.isNotBlank() }?.let { return it.trim() }
            val parts = message.optJSONArray("content")
            if (parts != null) {
                val joined = buildString {
                    for (index in 0 until parts.length()) {
                        append(parts.optJSONObject(index)?.optString("text").orEmpty())
                    }
                }
                if (joined.isNotBlank()) return joined.trim()
            }
        }
        output.optJSONObject("sentence")?.optString("text")?.takeIf { it.isNotBlank() }
            ?.let { return it.trim() }
        throw AsrException("Bailian returned an invalid transcription response")
    }

    fun isNoSpeechBody(body: String): Boolean = body.contains(NO_SPEECH_MARKER)

    /** Best-effort human-readable detail from a DashScope error envelope. */
    fun errorDetail(body: String): String? {
        val root = runCatching { JSONObject(body) }.getOrNull() ?: return null
        return root.optJSONObject("error")?.optString("message")?.takeIf { it.isNotBlank() }
            ?: root.optString("message").takeIf { it.isNotBlank() }
            ?: root.optString("code").takeIf { it.isNotBlank() }
    }

    private fun stringAt(json: JSONObject, key: String): String? =
        if (json.isNull(key)) null else json.opt(key) as? String

    private fun hostOf(raw: String): String? {
        if (raw.isBlank()) return null
        return runCatching { java.net.URI(raw.trim()).host }.getOrNull()?.takeIf { it.isNotBlank() }
    }

    private fun isCjk(char: Char): Boolean =
        char.code in 0x3400..0x4DBF || char.code in 0x4E00..0x9FFF || char.code in 0xF900..0xFAFF
}

/**
 * Assembles the sentence stream into one transcript. Confirmed sentences are kept in order and
 * the current sentence is replaced on every update.
 */
class BailianTranscript {
    private val confirmed = mutableListOf<String>()
    var text: String = ""
        private set

    /** Returns true when the assembled transcript changed. */
    fun apply(sentence: BailianProtocol.Sentence): Boolean {
        if (sentence.heartbeat) return false
        val trimmed = sentence.text.trim()
        val sentenceEnd = sentence.sentenceEnd
        val nextConfirmed = confirmed.toMutableList()
        var nextPartial = ""
        if (trimmed.isNotEmpty()) {
            val normalized = normalize(trimmed, confirmed.joinToString(""))
            if (sentenceEnd) nextConfirmed.add(normalized) else nextPartial = normalized
        } else if (!sentenceEnd || confirmed.isEmpty()) {
            return false
        }
        val next = nextConfirmed.joinToString("") + nextPartial
        confirmed.clear()
        confirmed.addAll(nextConfirmed)
        val changed = next != text
        text = next
        return changed
    }

    private fun normalize(segment: String, after: String): String {
        val last = after.lastOrNull() ?: return segment
        val first = segment.first()
        if (last.isWhitespace() || first.isWhitespace()) return segment
        if (first in CLOSING_PUNCTUATION || last in OPENING_PUNCTUATION) return segment
        if (isCjk(last) || isCjk(first)) return segment
        return " $segment"
    }

    private fun isCjk(char: Char): Boolean =
        char.code in 0x3400..0x4DBF || char.code in 0x4E00..0x9FFF || char.code in 0xF900..0xFAFF

    private companion object {
        const val CLOSING_PUNCTUATION = ",.!?;:)]}\"'"
        const val OPENING_PUNCTUATION = "([{/\"'"
    }
}
