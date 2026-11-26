package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONObject
import java.util.Base64
import java.util.UUID

/**
 * StepFun realtime ASR wire format, ported from the macOS client. The server
 * accepts a `session.update`, base64 PCM appends, and a `commit`; transcripts
 * arrive as `text` (stable) plus `stash` (unstable tail) deltas that are
 * replaced by a full `completed` transcript.
 */
object StepFunProtocol {
    const val CHINA_ENDPOINT = "wss://api.stepfun.com/v1/realtime/asr/stream"
    const val GLOBAL_ENDPOINT = "wss://api.stepfun.ai/v1/realtime/asr/stream"
    const val DEFAULT_MODEL = "stepaudio-2.5-asr-stream"

    private const val HOTWORD_PREFIX = "专业术语："
    private const val MAX_HOTWORDS = 100
    private const val MAX_HOTWORD_CHARACTERS = 2_000

    sealed interface Event {
        data object SessionReady : Event
        data class Transcript(val text: String, val final: Boolean) : Event
        data class Failure(val message: String) : Event
    }

    fun endpoint(config: AsrConfig): String {
        val configured = config.baseUrl.trim()
        val officialEndpoint =
            if (config.extraValue("region").equals("global", ignoreCase = true)) GLOBAL_ENDPOINT else CHINA_ENDPOINT
        // A custom proxy URL wins; the official hosts follow the selected region.
        if (configured.isEmpty() || configured == CHINA_ENDPOINT || configured == GLOBAL_ENDPOINT) {
            return officialEndpoint
        }
        return configured
    }

    fun model(config: AsrConfig): String = config.resolvedModel(DEFAULT_MODEL)

    fun language(config: AsrConfig): String =
        config.extraValue("language").ifBlank { "zh" }

    fun buildSessionUpdateMessage(config: AsrConfig, hotwords: List<String>): String {
        val transcription = JSONObject()
            .put("model", model(config))
            .put("language", language(config))
            .put("full_rerun_on_commit", true)
            .put("enable_itn", !config.extraValue("numerals").equals("false", ignoreCase = true))
        hotwordPrompt(hotwords)?.let { transcription.put("prompt", it) }

        return JSONObject()
            .put("event_id", eventId())
            .put("type", "session.update")
            .put(
                "session",
                JSONObject().put(
                    "audio",
                    JSONObject().put(
                        "input",
                        JSONObject()
                            .put(
                                "format",
                                JSONObject()
                                    .put("type", "pcm")
                                    .put("codec", "pcm_s16le")
                                    .put("rate", 16_000)
                                    .put("bits", 16)
                                    .put("channel", 1),
                            )
                            .put("transcription", transcription),
                    ),
                ),
            )
            .toString()
    }

    fun buildAppendAudioMessage(pcm: ByteArray): String = JSONObject()
        .put("event_id", eventId())
        .put("type", "input_audio_buffer.append")
        .put("audio", Base64.getEncoder().encodeToString(pcm))
        .toString()

    fun buildCommitMessage(): String = JSONObject()
        .put("event_id", eventId())
        .put("type", "input_audio_buffer.commit")
        .toString()

    /** Returns null for message types this client does not consume. */
    fun parse(text: String): Event? {
        val json = runCatching { JSONObject(text) }.getOrElse {
            throw AsrException("StepFun returned an unreadable response")
        }
        return when (json.optString("type")) {
            "session.updated" -> Event.SessionReady

            "conversation.item.input_audio_transcription.delta" -> {
                val stable = json.optString("text")
                val stash = json.optString("stash")
                if (stable.isEmpty() && stash.isEmpty()) {
                    null
                } else {
                    Event.Transcript(stable + stash, final = false)
                }
            }

            "conversation.item.input_audio_transcription.completed" ->
                Event.Transcript(json.optString("transcript").trim(), final = true)

            "error" -> {
                val error = json.optJSONObject("error")
                Event.Failure(
                    errorMessage(
                        code = error?.optString("code").orEmpty(),
                        message = error?.optString("message").orEmpty(),
                    ),
                )
            }

            else -> null
        }
    }

    private fun errorMessage(code: String, message: String): String {
        val codePart = if (code.isEmpty()) "" else "[$code] "
        val detail = message.ifBlank { "unknown server error" }
        return "StepFun streaming ASR failed: $codePart$detail"
    }

    private fun hotwordPrompt(hotwords: List<String>): String? {
        val seen = mutableSetOf<String>()
        var prompt = HOTWORD_PREFIX
        var count = 0
        for (rawTerm in hotwords) {
            if (count >= MAX_HOTWORDS) break
            val term = rawTerm.trim()
            if (term.isEmpty()) continue
            if (!seen.add(term.lowercase())) continue
            val candidate = prompt + (if (count == 0) "" else "、") + term
            if (candidate.length > MAX_HOTWORD_CHARACTERS) continue
            prompt = candidate
            count++
        }
        return if (count == 0) null else prompt
    }

    private fun eventId(): String = "event_" + UUID.randomUUID().toString().lowercase()
}
