package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONObject

/**
 * Cartesia Ink realtime STT. The app owns voice activity detection, so the
 * recording is closed with the explicit `finalize` command instead of relying
 * on the server's own endpointing.
 */
object CartesiaProtocol {
    const val ENDPOINT = "wss://api.cartesia.ai/stt/websocket"
    const val API_VERSION = "2026-08-14"
    const val DEFAULT_MODEL = "ink-2"
    const val DEFAULT_LANGUAGE = "zh"

    private const val MAX_KEYTERMS = 100

    data class Update(
        val text: String,
        val final: Boolean,
        val confirmedSegments: List<String>,
    )

    fun buildUrl(config: AsrConfig, hotwords: List<String>): String =
        websocketUrl(config.baseUrl, ENDPOINT, "Invalid Cartesia WebSocket URL") { builder ->
            builder.addQueryParameter("model", config.resolvedModel(DEFAULT_MODEL))
            builder.addQueryParameter("encoding", "pcm_s16le")
            builder.addQueryParameter("sample_rate", "16000")
            builder.addQueryParameter("cartesia_version", API_VERSION)
            builder.addQueryParameter(
                "language",
                config.extraValue("language").ifBlank { DEFAULT_LANGUAGE },
            )
            hotwords.map { it.trim() }
                .filter { it.isNotEmpty() }
                .take(MAX_KEYTERMS)
                .forEach { builder.addQueryParameter("keyterm", it) }
        }

    fun finalizeMessage(): String = "finalize"

    /**
     * Folds one server message into [confirmedSegments]. Returns null for
     * message types this client does not consume.
     */
    fun parse(text: String, confirmedSegments: List<String>): Update? {
        val json = runCatching { JSONObject(text) }.getOrElse {
            throw AsrException("Cartesia returned an unreadable response")
        }
        val type = json.optString("type")
        if (type == "error") {
            val title = json.optString("title").ifBlank { "Error" }
            val message = json.optString("message").ifBlank { "Unknown server error" }
            throw AsrException("Cartesia $title: $message")
        }
        if (type != "transcript") return null

        val transcript = json.optString("text")
        val final = json.optBoolean("is_final", false)
        val confirmed = confirmedSegments.toMutableList()
        val partial: String
        if (final) {
            if (transcript.isNotEmpty()) confirmed += transcript
            partial = ""
        } else {
            partial = transcript
        }
        return Update(
            text = confirmed.joinToString("") + partial,
            final = final,
            confirmedSegments = confirmed,
        )
    }
}
