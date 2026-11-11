package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.json.JSONObject

/**
 * Deepgram realtime listen protocol. Audio is sent as raw binary frames while
 * JSON `Results` messages carry interim and final transcripts; `CloseStream`
 * asks the server to flush the tail and close.
 */
object DeepgramProtocol {
    const val DEFAULT_BASE_URL = "wss://api.deepgram.com/v1/listen"
    const val DEFAULT_MODEL = "nova-3"
    const val DEFAULT_LANGUAGE = "zh"

    private const val KEYWORD_INTENSITY = 2
    private const val MAX_URL_KEYTERMS = 30
    private val STANDARD_AUTH_HOSTS = setOf("api.deepgram.com", "asr.autoloops.ai")

    data class Update(
        val text: String,
        val final: Boolean,
        val confirmedSegments: List<String>,
    )

    fun isFluxModel(model: String): Boolean = model.contains("flux", ignoreCase = true)

    /**
     * Deepgram's own hosts take `Authorization: Token ...`; compatible proxies
     * authenticate the raw key through `X-API-Key` instead.
     */
    fun usesStandardAuthorization(url: String): Boolean {
        val parsed = httpForm(url) ?: return false
        if (parsed.scheme != "https") return false
        return parsed.host.lowercase() in STANDARD_AUTH_HOSTS
    }

    fun buildUrl(config: AsrConfig, hotwords: List<String>): String {
        val model = config.resolvedModel(DEFAULT_MODEL)
        val isFlux = isFluxModel(model)
        val rawBase = config.baseUrl.trim().ifBlank { DEFAULT_BASE_URL }
        val base = if (isFlux) fluxEndpoint(rawBase) else rawBase

        return websocketUrl(base, DEFAULT_BASE_URL, "Invalid Deepgram WebSocket URL") { builder ->
            builder.addQueryParameter("model", model)
            builder.addQueryParameter("encoding", "linear16")
            builder.addQueryParameter("sample_rate", "16000")

            if (isFlux) {
                builder.addQueryParameter("eot_threshold", "0.7")
                val language = config.extraValue("language")
                if (model.contains("multi", ignoreCase = true) &&
                    language.isNotEmpty() &&
                    !language.equals("multi", ignoreCase = true)
                ) {
                    builder.addQueryParameter("language_hint", language)
                }
            } else {
                builder.addQueryParameter(
                    "language",
                    config.extraValue("language").ifBlank { DEFAULT_LANGUAGE },
                )
                builder.addQueryParameter("channels", "1")
                builder.addQueryParameter("interim_results", "true")
                builder.addQueryParameter(
                    "punctuate",
                    if (config.extraValue("punctuate") == "false") "false" else "true",
                )
                builder.addQueryParameter("smart_format", "true")
                if (config.extraValue("numerals").equals("true", ignoreCase = true)) {
                    builder.addQueryParameter("numerals", "true")
                }

                val terms = hotwords.map { it.trim() }.filter { it.isNotEmpty() }.take(MAX_URL_KEYTERMS)
                if (model.lowercase().startsWith("nova-3")) {
                    terms.forEach { builder.addQueryParameter("keyterm", it) }
                } else {
                    terms.forEach { builder.addQueryParameter("keywords", "$it:$KEYWORD_INTENSITY") }
                }
            }
        }
    }

    fun closeStreamMessage(): String = """{"type":"CloseStream"}"""

    /**
     * Folds one server message into [confirmedSegments]. Returns null when the
     * message is not a transcript or repeats a settled result.
     */
    fun parse(text: String, confirmedSegments: List<String>): Update? {
        val json = runCatching { JSONObject(text) }.getOrElse {
            throw AsrException("Deepgram returned an unreadable response")
        }
        val type = json.optString("type")
        val raw: String
        val final: Boolean
        when (type) {
            "Results" -> {
                raw = json.optJSONObject("channel")
                    ?.optJSONArray("alternatives")
                    ?.optJSONObject(0)
                    ?.optString("transcript")
                    .orEmpty()
                final = json.optBoolean("is_final", false) ||
                    json.optBoolean("speech_final", false) ||
                    json.optBoolean("from_finalize", false)
            }

            "TurnInfo" -> {
                raw = json.optString("transcript")
                final = json.optString("event") == "EndOfTurn"
            }

            else -> return null
        }

        val trimmed = raw.trim()
        val confirmed = confirmedSegments.toMutableList()
        var partial = ""
        if (trimmed.isNotEmpty()) {
            val normalized = AsrTextTools.normalizeSegment(trimmed, confirmed.joinToString(""))
            if (final) confirmed += normalized else partial = normalized
        } else if (!final || confirmed.isEmpty()) {
            return null
        }

        return Update(
            text = confirmed.joinToString("") + partial,
            final = final,
            confirmedSegments = confirmed,
        )
    }

    /** Flux lives on `/v2/listen`; other paths are kept as configured. */
    private fun fluxEndpoint(base: String): String {
        val queryIndex = base.indexOf('?')
        val withoutQuery = if (queryIndex >= 0) base.substring(0, queryIndex) else base
        val query = if (queryIndex >= 0) base.substring(queryIndex) else ""
        val hostEnd = withoutQuery.indexOf('/', withoutQuery.indexOf("://") + 3)
        val authority = if (hostEnd >= 0) withoutQuery.substring(0, hostEnd) else withoutQuery
        val path = if (hostEnd >= 0) withoutQuery.substring(hostEnd) else ""
        if (path.isNotEmpty() && path != "/v1/listen") return base
        return "$authority/v2/listen$query"
    }

    private fun httpForm(url: String): okhttp3.HttpUrl? {
        val trimmed = url.trim()
        val http = when {
            trimmed.startsWith("wss://", ignoreCase = true) -> "https://" + trimmed.substring(6)
            trimmed.startsWith("ws://", ignoreCase = true) -> "http://" + trimmed.substring(5)
            else -> trimmed
        }
        return http.toHttpUrlOrNull()
    }
}
