package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONArray
import org.json.JSONObject

/**
 * Microsoft Foundry Realtime and Speech fast-transcription wire format for
 * MAI-Transcribe-2. Streaming has no server-side turn detection, so the client
 * commits once when recording ends.
 */
object AzureProtocol {
    const val REALTIME_PATH = "/mai/v1/realtime"
    const val BATCH_PATH = "/speechtotext/transcriptions:transcribe"
    const val API_VERSION = "2025-10-15"
    const val DEFAULT_DEPLOYMENT = "MAI-Transcribe-2-Streaming"
    const val BATCH_MODEL = "MAI-Transcribe-2"
    const val SAMPLE_RATE = 16_000
    const val COMMIT_MESSAGE = """{"type":"input_audio_buffer.commit"}"""

    private const val FOUNDRY_SUFFIX = ".services.ai.azure.com"
    private const val SPEECH_SUFFIX = ".cognitiveservices.azure.com"
    private val KNOWN_SUFFIXES = listOf(FOUNDRY_SUFFIX, SPEECH_SUFFIX, ".openai.azure.com")
    private const val TRANSCRIPTION_PREFIX = "conversation.item.input_audio_transcription."

    data class Settings(
        val resource: String,
        val apiKey: String,
        val deployment: String,
        val transcribeStyle: String,
        val language: String,
        val foundryHost: String?,
        val speechHost: String?,
    )

    sealed class Event {
        object Created : Event()
        object Updated : Event()
        object Committed : Event()
        /** Newly finalized text, appended verbatim to what came before. */
        data class Delta(val text: String) : Event()
        /** Whole provisional suffix after the latest delta; replaces the previous one. */
        data class Intermediate(val text: String) : Event()
        /** Full final transcript for the audio since the previous commit. */
        data class Completed(val transcript: String) : Event()
        object Ignored : Event()
    }

    fun settings(config: AsrConfig): Settings {
        val resource = config.extra["resource"].orEmpty().trim().ifBlank { config.baseUrl.trim() }
        val deployment = config.model.trim()
            .ifBlank { config.extra["deployment"].orEmpty().trim() }
            .ifBlank { DEFAULT_DEPLOYMENT }
        val style = if (config.extra["transcribeStyle"].orEmpty().trim() == "verbatim") "verbatim" else "clean"
        return Settings(
            resource = resource,
            apiKey = config.apiKey.trim(),
            deployment = deployment,
            transcribeStyle = style,
            language = config.extra["language"].orEmpty().trim(),
            foundryHost = hostFor(resource, FOUNDRY_SUFFIX),
            speechHost = hostFor(resource, SPEECH_SUFFIX),
        )
    }

    fun realtimeUrl(settings: Settings): String {
        val host = settings.foundryHost
            ?: throw AsrException("Microsoft Azure resource name is missing or invalid")
        return "wss://$host$REALTIME_PATH?intent=transcription"
    }

    /** Must be sent before the first audio append; settings are fixed afterwards. */
    fun sessionUpdateMessage(settings: Settings): String {
        val transcription = JSONObject()
            .put("model", settings.deployment)
            .put("language", if (settings.language.isEmpty()) JSONObject.NULL else settings.language)
        return JSONObject()
            .put("type", "session.update")
            .put(
                "session",
                JSONObject()
                    .put("type", "transcription")
                    .put(
                        "audio",
                        JSONObject().put(
                            "input",
                            JSONObject()
                                .put("format", JSONObject().put("type", "audio/pcm").put("rate", SAMPLE_RATE))
                                .put("transcription", transcription)
                                .put("turn_detection", JSONObject.NULL)
                                .put("noise_reduction", JSONObject.NULL),
                        ),
                    ),
            )
            .toString()
    }

    fun appendMessage(pcm: ByteArray): String = JSONObject()
        .put("type", "input_audio_buffer.append")
        .put("audio", java.util.Base64.getEncoder().encodeToString(pcm))
        .toString()

    fun parseEvent(text: String): Event {
        val root = runCatching { JSONObject(text) }.getOrElse {
            throw AsrException("Could not parse the Microsoft Azure response")
        }
        val type = root.optString("type")
        return when (type) {
            "", "null" -> Event.Ignored
            "session.created" -> Event.Created
            "session.updated" -> Event.Updated
            "input_audio_buffer.committed" -> Event.Committed
            "error", TRANSCRIPTION_PREFIX + "failed" -> throw serverError(root)
            TRANSCRIPTION_PREFIX + "delta" -> Event.Delta(root.optString("delta"))
            TRANSCRIPTION_PREFIX + "intermediate" -> Event.Intermediate(root.optString("intermediate"))
            TRANSCRIPTION_PREFIX + "completed" -> Event.Completed(root.optString("transcript"))
            else -> Event.Ignored
        }
    }

    fun batchUrl(settings: Settings): String {
        val host = settings.speechHost
            ?: throw AsrException("Microsoft Azure resource name is missing or invalid")
        return "https://$host$BATCH_PATH?api-version=$API_VERSION"
    }

    /** `definition` form field of the fast-transcription request. */
    fun batchDefinition(settings: Settings, hotwords: List<String>): JSONObject {
        val definition = JSONObject().put(
            "enhancedMode",
            JSONObject()
                .put("enabled", true)
                .put("model", BATCH_MODEL)
                .put("modelOptions", JSONObject().put("transcribeStyle", settings.transcribeStyle)),
        )
        if (settings.language.isNotEmpty()) definition.put("locales", JSONArray().put(settings.language))
        val phrases = phrases(hotwords)
        if (phrases.isNotEmpty()) {
            val array = JSONArray()
            phrases.forEach { array.put(it) }
            definition.put("phraseList", JSONObject().put("phrases", array))
        }
        return definition
    }

    /** Up to 100 distinct phrases, each at most 50 characters. */
    fun phrases(hotwords: List<String>): List<String> {
        val seen = linkedSetOf<String>()
        for (term in hotwords) {
            val trimmed = term.trim()
            if (trimmed.isEmpty() || trimmed.length > 50) continue
            seen.add(trimmed)
            if (seen.size >= 100) break
        }
        return seen.toList()
    }

    fun parseBatchResponse(body: String): String {
        val root = runCatching { JSONObject(body) }.getOrElse {
            throw AsrException("Could not parse the Microsoft Azure response")
        }
        val combined = root.optJSONArray("combinedPhrases")
            ?: throw AsrException("Microsoft Azure returned an invalid transcription response")
        val pieces = mutableListOf<String>()
        for (index in 0 until combined.length()) {
            val text = combined.optJSONObject(index)?.optString("text").orEmpty()
            if (text.isNotBlank()) pieces.add(text.trim())
        }
        val joined = StringBuilder()
        for (piece in pieces) {
            if (joined.isNotEmpty() && needsSpace(joined.last(), piece.first())) joined.append(' ')
            joined.append(piece)
        }
        return joined.toString()
    }

    fun errorDetail(body: String): String? {
        val root = runCatching { JSONObject(body) }.getOrNull() ?: return null
        val nested = root.optJSONObject("error")
        return nested?.optString("message")?.takeIf { it.isNotBlank() }
            ?: root.optString("message").takeIf { it.isNotBlank() }
            ?: nested?.optString("code")?.takeIf { it.isNotBlank() }
    }

    /**
     * Accepts a bare resource name, a resource hostname, or a full endpoint URL. Standard Azure
     * hostnames map to the requested service host; any other hostname is used as-is.
     */
    fun hostFor(rawResource: String, suffix: String): String? {
        val trimmed = rawResource.trim()
        if (trimmed.isEmpty()) return null
        val host = if (trimmed.contains("://")) {
            runCatching { java.net.URI(trimmed).host }.getOrNull()?.takeIf { it.isNotBlank() } ?: return null
        } else {
            trimmed.substringBefore('/')
        }
        val lowered = host.lowercase()
        if (lowered.isEmpty()) return null

        val name: String
        if (!lowered.contains('.')) {
            name = lowered
        } else {
            val known = KNOWN_SUFFIXES.firstOrNull { lowered.endsWith(it) }
            if (known == null) return if (isValidHost(lowered)) lowered else null
            name = lowered.dropLast(known.length)
        }
        if (name.isEmpty() || name.contains('.') || !isValidHost(name)) return null
        return name + suffix
    }

    private fun isValidHost(host: String): Boolean {
        val allowed = "abcdefghijklmnopqrstuvwxyz0123456789-."
        return host.all { it in allowed } && !host.startsWith("-") && !host.startsWith(".")
    }

    /** CJK phrases and punctuation clumps read better without an inserted space. */
    private fun needsSpace(left: Char, right: Char): Boolean =
        !isCjk(left) && !isCjk(right) && !left.isWhitespace() && !right.isWhitespace()

    private fun isCjk(char: Char): Boolean =
        char.code in 0x3400..0x4DBF || char.code in 0x4E00..0x9FFF || char.code in 0x3040..0x30FF

    private fun serverError(root: JSONObject): AsrException {
        val error = root.optJSONObject("error")
        val code = error?.optString("code")?.takeIf { it.isNotBlank() }
            ?: error?.optString("type")?.takeIf { it.isNotBlank() }
        val message = error?.optString("message")?.takeIf { it.isNotBlank() }
            ?: root.optString("message").takeIf { it.isNotBlank() }
            ?: "Unknown error"
        return AsrException(
            if (code.isNullOrBlank()) {
                "Microsoft Azure: $message"
            } else {
                "Microsoft Azure [$code]: $message"
            },
        )
    }
}
