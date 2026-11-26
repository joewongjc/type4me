package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64

/**
 * Xiaomi MiMo ASR: one chat-completions request with the whole WAV inlined as a data URL,
 * streamed back as server-sent events.
 */
object MiMoProtocol {
    const val DEFAULT_ENDPOINT = "https://api.xiaomimimo.com/v1/chat/completions"
    const val DEFAULT_MODEL = "mimo-v2.5-asr"
    const val MAX_ENCODED_AUDIO_BYTES = 10 * 1024 * 1024

    sealed class Event {
        data class Delta(val text: String) : Event()
        object Done : Event()
        data class Failure(val message: String) : Event()
    }

    fun endpoint(config: AsrConfig): String {
        val base = config.baseUrl.trim().trimEnd('/')
        if (base.isEmpty()) return DEFAULT_ENDPOINT
        return if (base.endsWith("/chat/completions")) base else "$base/chat/completions"
    }

    fun model(config: AsrConfig): String = config.model.trim().ifBlank { DEFAULT_MODEL }

    fun language(config: AsrConfig): String = config.extra["language"].orEmpty().trim().ifBlank { "auto" }

    fun buildBody(config: AsrConfig, wav: ByteArray): JSONObject {
        val dataUrl = "data:audio/wav;base64," + Base64.getEncoder().encodeToString(wav)
        if (dataUrl.toByteArray(Charsets.UTF_8).size > MAX_ENCODED_AUDIO_BYTES) {
            throw AsrException(
                "The recording exceeds Xiaomi MiMo's per-request audio limit. Record a shorter segment.",
            )
        }
        val message = JSONObject()
            .put("role", "user")
            .put(
                "content",
                JSONArray().put(
                    JSONObject()
                        .put("type", "input_audio")
                        .put("input_audio", JSONObject().put("data", dataUrl)),
                ),
            )
        return JSONObject()
            .put("model", model(config))
            .put("messages", JSONArray().put(message))
            .put("asr_options", JSONObject().put("language", language(config)))
            .put("stream", true)
    }

    fun parseSseLine(line: String): Event? {
        if (!line.startsWith("data:")) return null
        val payload = line.removePrefix("data:").trim()
        // [DONE] is only stream framing; finish_reason governs completion.
        if (payload.isEmpty() || payload == "[DONE]") return null

        val json = runCatching { JSONObject(payload) }.getOrElse {
            throw AsrException("Could not parse the Xiaomi MiMo response")
        }
        json.optJSONObject("error")?.let { error ->
            return Event.Failure(error.optString("message").ifBlank { "Xiaomi MiMo recognition failed" })
        }
        val choice = json.optJSONArray("choices")?.optJSONObject(0) ?: return null
        val finishReason = if (choice.isNull("finish_reason")) {
            null
        } else {
            choice.optString("finish_reason").takeIf { it.isNotBlank() }
        }
        if (finishReason != null) {
            return when (finishReason) {
                "stop" -> Event.Done
                "length" -> Event.Failure("Recognition output exceeded the maximum token length")
                "content_filter" -> Event.Failure("Recognition content was filtered by the safety policy")
                else -> Event.Failure("Recognition terminated abnormally: $finishReason")
            }
        }
        val delta = choice.optJSONObject("delta") ?: return null
        val content = if (delta.isNull("content")) "" else delta.optString("content")
        return if (content.isEmpty()) null else Event.Delta(content)
    }

    fun extractErrorMessage(body: String): String? {
        val json = runCatching { JSONObject(body) }.getOrNull()
        if (json != null) {
            json.optJSONObject("error")?.optString("message")?.takeIf { it.isNotBlank() }?.let { return it }
            json.optString("message").takeIf { it.isNotBlank() }?.let { return it }
        }
        return body.trim().take(200).takeIf { it.isNotBlank() }
    }
}
