package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONArray
import org.json.JSONObject

/** Meta Muse realtime ASR: JSON handshake, raw PCM frames, JSON events. */
internal object MetaMuseProtocol {
    const val DEFAULT_ENDPOINT = "wss://api.meta.ai/v1/asr/realtime"
    const val DEFAULT_MODEL = "muse-voice-transcribe-1.0"
    const val MAX_KEYWORDS = 100
    const val MAX_KEYWORD_LENGTH = 20

    sealed class Event {
        data class SessionReady(val sessionId: String) : Event()
        data class Transcript(val text: String, val isFinal: Boolean) : Event()
        data class Failed(val message: String) : Event()
        data class Ignored(val type: String) : Event()
    }

    fun buildWebSocketUrl(config: AsrConfig): String =
        websocketUrl(config.baseUrl, DEFAULT_ENDPOINT, "Invalid Meta Muse WebSocket URL")

    fun handshakeMessage(config: AsrConfig, hotwords: List<String>): String {
        if (config.apiKey.isBlank()) throw AsrException("Meta Muse API key is empty")
        val handshake = JSONObject()
            .put("authorization", JSONObject().put("accessToken", "Bearer ${config.apiKey}"))
            .put("audioEncoding", "PCM_16KHZ")
            .put("model", config.resolvedModel(DEFAULT_MODEL))
            .put("mode", "PUSH_TO_TALK")
        val keywords = sanitizedKeywords(hotwords)
        if (keywords.isNotEmpty()) handshake.put("keywords", JSONArray(keywords))
        val languageBias = config.firstExtraValue("languageBias", "language")
        if (languageBias.isNotEmpty()) handshake.put("languageBias", JSONArray().put(languageBias))
        return handshake.toString()
    }

    fun endStreamMessage(): String = JSONObject().put("type", "endStream").toString()

    fun sanitizedKeywords(
        hotwords: List<String>,
        maxCount: Int = MAX_KEYWORDS,
        maxLength: Int = MAX_KEYWORD_LENGTH,
    ): List<String> {
        val seen = HashSet<String>()
        val result = mutableListOf<String>()
        for (word in hotwords) {
            val trimmed = word.trim()
            if (trimmed.isEmpty() || !seen.add(trimmed)) continue
            result += trimmed.take(maxLength)
            if (result.size >= maxCount) break
        }
        return result
    }

    fun parse(message: String): Event {
        if (message.trimStart().firstOrNull() != '{') {
            throw AsrException("Meta Muse returned an unparseable event")
        }
        val json = runCatching { JSONObject(message) }.getOrElse {
            throw AsrException("Meta Muse returned an unparseable event")
        }

        // The session-ready frame is the only one without a "type" field.
        if (!json.has("type")) {
            val sessionId = json.optString("sessionId").ifEmpty { json.optString("session_id") }
            if (sessionId.isNotEmpty() || json.has("sessionId") || json.has("session_id")) {
                return Event.SessionReady(sessionId)
            }
            throw AsrException("Meta Muse returned an unparseable event")
        }

        return when (val type = json.optString("type")) {
            "handshake", "session_ready", "session.ready" -> {
                val sessionId = json.optString("sessionId").ifEmpty { json.optString("session_id") }
                Event.SessionReady(sessionId)
            }

            "transcript" -> {
                val text = if (json.has("transcript")) {
                    json.optString("transcript")
                } else {
                    json.optString("text")
                }
                if (!json.has("transcript") && !json.has("text")) {
                    throw AsrException("Meta Muse returned an unparseable event")
                }
                Event.Transcript(text, json.optBoolean("final", false))
            }

            "error" -> {
                val detail = json.optString("message").ifBlank { "Unknown error" }
                val lowered = detail.lowercase()
                val message = when {
                    lowered.contains("unauthorized") || lowered.contains("auth") ||
                        lowered.contains("api key") || lowered.contains("forbidden") ->
                        "Meta Muse authentication failed: $detail"

                    lowered.contains("rate limit") || lowered.contains("too many requests") ||
                        lowered.contains("429") ->
                        "Meta Muse rate limit exceeded: $detail"

                    lowered.contains("quota") || lowered.contains("limit reached") ->
                        "Meta Muse session reached its duration or audio limit"

                    else -> "Meta Muse error: $detail"
                }
                Event.Failed(message)
            }

            else -> Event.Ignored(type)
        }
    }
}
