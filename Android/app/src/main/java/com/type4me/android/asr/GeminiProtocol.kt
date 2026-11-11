package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONArray
import org.json.JSONObject

/** Gemini Live wire format: setup, activity markers and base64 PCM frames. */
internal object GeminiProtocol {
    const val ENDPOINT =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    const val DEFAULT_MODEL = "gemini-3.5-transcribe-live"
    const val DEFAULT_BATCH_MODEL = "gemini-3.5-transcribe"
    const val SAMPLE_RATE = 16_000
    /** 1600 frames of 16-bit mono audio, about 100ms per payload. */
    const val TARGET_PAYLOAD_BYTES = 3_200
    const val MAX_CUSTOM_VOCABULARY = 1_000

    data class Update(
        val confirmedSegments: List<String>,
        val partial: String,
        val isFinal: Boolean,
        val isSetupComplete: Boolean = false,
        val goAway: Boolean = false,
    )

    fun buildWebSocketUrl(config: AsrConfig): String {
        if (config.apiKey.isBlank()) throw AsrException("Gemini API key is empty")
        return websocketUrl(config.baseUrl, ENDPOINT, "Invalid Gemini WebSocket URL") { builder ->
            builder.addQueryParameter("key", config.apiKey)
        }
    }

    /** Gemini wants a fully qualified `models/<id>`; users may paste either form. */
    fun qualifiedModelName(model: String, defaultModel: String = DEFAULT_MODEL): String {
        val trimmed = model.trim()
        val bare = if (trimmed.startsWith("models/")) trimmed.removePrefix("models/") else trimmed
        val resolved = bare.ifEmpty { defaultModel }
        return "models/$resolved"
    }

    fun transcriptionMode(config: AsrConfig): String =
        if (config.extraValue("mode").uppercase() == "VERBATIM") "VERBATIM" else "SMART"

    fun languageCodes(config: AsrConfig): List<String> {
        val language = config.firstExtraValue("languageCode", "language")
        if (language.isEmpty() || language.equals("auto", ignoreCase = true)) return emptyList()
        return listOf(language)
    }

    fun setupMessage(config: AsrConfig, hotwords: List<String>): String {
        val transcription = JSONObject()
            .put("mode", transcriptionMode(config))
            .put("languageCodes", JSONArray(languageCodes(config)))
        val vocabulary = sanitizeHotwords(hotwords)
        if (vocabulary.isNotEmpty()) transcription.put("customVocabulary", JSONArray(vocabulary))

        val generationConfig = JSONObject()
            .put("responseModalities", JSONArray().put("TEXT"))
        val realtimeInputConfig = JSONObject()
            .put("automaticActivityDetection", JSONObject().put("disabled", true))

        val setup = JSONObject()
            .put("model", qualifiedModelName(config.resolvedModel(DEFAULT_MODEL)))
            .put("generationConfig", generationConfig)
            .put("realtimeInputConfig", realtimeInputConfig)
            .put("inputAudioTranscription", transcription)
        return JSONObject().put("setup", setup).toString()
    }

    fun activityStartMessage(): String =
        JSONObject().put("realtimeInput", JSONObject().put("activityStart", JSONObject())).toString()

    fun activityEndMessage(): String =
        JSONObject().put("realtimeInput", JSONObject().put("activityEnd", JSONObject())).toString()

    fun audioChunkMessage(pcm: ByteArray): String {
        val audio = JSONObject()
            .put("data", java.util.Base64.getEncoder().encodeToString(pcm))
            .put("mimeType", "audio/pcm;rate=$SAMPLE_RATE")
        return JSONObject().put("realtimeInput", JSONObject().put("audio", audio)).toString()
    }

    fun sanitizeHotwords(hotwords: List<String>): List<String> {
        val seen = HashSet<String>()
        val result = mutableListOf<String>()
        for (word in hotwords) {
            val trimmed = word.trim()
            if (trimmed.isEmpty()) continue
            if (seen.add(trimmed)) {
                result += trimmed
                if (result.size >= MAX_CUSTOM_VOCABULARY) break
            }
        }
        return result
    }

    /** Splits buffered audio into payloads, keeping the sub-payload tail. */
    fun sliceAudioPayloads(residual: ByteArray): Pair<List<ByteArray>, ByteArray> {
        val payloads = mutableListOf<ByteArray>()
        var offset = 0
        while (residual.size - offset >= TARGET_PAYLOAD_BYTES) {
            payloads += residual.copyOfRange(offset, offset + TARGET_PAYLOAD_BYTES)
            offset += TARGET_PAYLOAD_BYTES
        }
        return payloads to residual.copyOfRange(offset, residual.size)
    }

    fun flushResidualAudio(residual: ByteArray): ByteArray? =
        if (residual.isEmpty()) null else residual.copyOf()

    fun parse(
        message: String,
        confirmedSegments: List<String>,
        didEndAudio: Boolean,
        hotwords: List<String>,
    ): Update? {
        if (message.trimStart().firstOrNull() != '{') return null
        val json = runCatching { JSONObject(message) }.getOrElse {
            throw AsrException("Could not parse the Gemini response")
        }

        json.optJSONObject("error")?.let { problem ->
            val code = if (problem.has("code")) problem.optInt("code") else null
            val status = problem.optString("status")
            val detail = problem.optString("message").ifBlank { "Unknown error" }
            if (code == 429 || status == "RESOURCE_EXHAUSTED") {
                throw AsrException("Gemini API quota exceeded: $detail")
            }
            val suffix = if (code != null) " ($code)" else ""
            throw AsrException("Gemini server error$suffix: $detail")
        }

        // The server asks clients to migrate before terminating the socket.
        if (json.has("goAway")) {
            return Update(confirmedSegments, "", isFinal = didEndAudio, goAway = true)
        }

        if (json.has("setupComplete")) {
            return Update(confirmedSegments, "", isFinal = false, isSetupComplete = true)
        }

        val content = json.optJSONObject("serverContent") ?: return null

        val finalText = content.optJSONObject("inputTranscription")?.optString("text")
        if (finalText != null) {
            val sanitized = AsrTextTools.sanitizeHotwordLeak(finalText.trim(), hotwords)
            if (sanitized.isEmpty()) {
                if (!didEndAudio) return null
                return Update(confirmedSegments, "", isFinal = true)
            }
            if (confirmedSegments.lastOrNull() == sanitized) {
                return Update(confirmedSegments, "", isFinal = didEndAudio)
            }
            val normalized = AsrTextTools.normalizeSegment(sanitized, confirmedSegments.joinToString(""))
            return Update(confirmedSegments + normalized, "", isFinal = didEndAudio)
        }

        val interimText = content.optJSONObject("interimInputTranscription")?.optString("text")
        if (interimText != null) {
            val sanitized = AsrTextTools.sanitizeHotwordLeak(interimText.trim(), hotwords)
            if (sanitized.isEmpty()) return null
            val normalized = AsrTextTools.normalizeSegment(sanitized, confirmedSegments.joinToString(""))
            return Update(confirmedSegments, normalized, isFinal = false)
        }

        return null
    }
}
