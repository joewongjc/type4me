package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONObject

/** Scribe v2 realtime wire format: JSON chunks with base64 PCM. */
internal object ElevenLabsProtocol {
    const val ENDPOINT = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
    const val DEFAULT_MODEL = "scribe_v2_realtime"
    const val DEFAULT_BATCH_MODEL = "scribe_v2"
    const val SAMPLE_RATE = 16_000

    /** Server response distilled into the shape a live session needs. */
    data class Update(
        val confirmedSegments: List<String>,
        val partial: String,
        val isFinal: Boolean,
    )

    fun buildWebSocketUrl(config: AsrConfig, hotwords: List<String>): String =
        websocketUrl(config.baseUrl, ENDPOINT, "Invalid ElevenLabs WebSocket URL") { builder ->
            builder.addQueryParameter("model_id", config.resolvedModel(DEFAULT_MODEL))
                .addQueryParameter("audio_format", "pcm_16000")
                .addQueryParameter("no_verbatim", "true")
            val language = config.extraValue("language")
            if (language.isNotEmpty()) builder.addQueryParameter("language_code", language)
            keyterms(hotwords).forEach { builder.addQueryParameter("keyterm", it) }
        }

    /** At most 50 keyterms, each no longer than 20 characters. */
    fun keyterms(hotwords: List<String>): List<String> = hotwords
        .map { it.trim() }
        .filter { it.isNotEmpty() && it.length <= 20 }
        .take(50)

    fun audioChunkMessage(pcm: ByteArray): String = JSONObject()
        .put("message_type", "input_audio_chunk")
        .put("audio_base_64", base64(pcm))
        .put("sample_rate", SAMPLE_RATE)
        .toString()

    /** Asks the server to commit everything sent so far. */
    fun commitMessage(): String = JSONObject()
        .put("message_type", "input_audio_chunk")
        .put("audio_base_64", "")
        .put("commit", true)
        .put("sample_rate", SAMPLE_RATE)
        .toString()

    fun parse(
        message: String,
        confirmedSegments: List<String>,
        isFinalCommit: Boolean,
        languageCode: String,
    ): Update? {
        if (message.trimStart().firstOrNull() != '{') return null
        val json = runCatching { JSONObject(message) }.getOrElse {
            throw AsrException("Could not parse the ElevenLabs response")
        }
        val type = json.optString("message_type")
        val text = json.optString("text")
        val confirmed = confirmedSegments.joinToString("")

        return when (type) {
            "partial_transcript" -> {
                if (text.isBlank()) return null
                val partialOnly = AsrTextTools.stripConfirmedPrefix(text, confirmed)
                if (partialOnly.isEmpty()) return null
                val punctuated = AsrTextTools.normalizePunctuation(languageCode, partialOnly)
                val normalized = AsrTextTools.normalizeSegment(punctuated, confirmed)
                Update(confirmedSegments, normalized, isFinal = false)
            }

            "committed_transcript" -> {
                val next = confirmedSegments.toMutableList()
                val newOnly = AsrTextTools.stripConfirmedPrefix(text, confirmed)
                if (newOnly.isNotEmpty()) {
                    val punctuated = AsrTextTools.normalizePunctuation(languageCode, newOnly)
                    next += AsrTextTools.normalizeSegment(punctuated, confirmed)
                }
                // Only the explicit end-of-stream commit ends the session; VAD
                // commits keep the recording alive.
                Update(next, "", isFinal = isFinalCommit)
            }

            // VAD already committed every byte before our commit landed.
            "commit_throttled" -> {
                if (confirmedSegments.isNotEmpty() || isFinalCommit) {
                    Update(confirmedSegments, "", isFinal = true)
                } else {
                    null
                }
            }

            "unaccepted_terms" -> throw AsrException(
                "ElevenLabs terms not accepted. Accept them at elevenlabs.io/app/product-terms.",
            )

            "session_time_limit_exceeded", "error" -> {
                val detail = json.optString("message")
                val message = if (detail.isBlank()) {
                    "ElevenLabs error: $type"
                } else {
                    "ElevenLabs error ($type): $detail"
                }
                throw AsrException(message)
            }

            "insufficient_audio_activity", "chunk_size_exceeded" -> null

            else -> null
        }
    }

    private fun base64(bytes: ByteArray): String =
        java.util.Base64.getEncoder().encodeToString(bytes)
}
