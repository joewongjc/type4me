package com.type4me.android.asr

import com.type4me.android.audio.WavEncoder
import com.type4me.android.data.AsrConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * A batch upload cannot use the streaming WebSocket address that older saves kept
 * after switching recognition modes, so such values fall back to the default.
 */
internal fun batchHttpUrl(configured: String, fallback: String): String {
    val trimmed = configured.trim()
    if (trimmed.isEmpty()) return fallback
    val lower = trimmed.lowercase()
    if (lower.startsWith("ws://") || lower.startsWith("wss://")) return fallback
    return trimmed
}

/**
 * One-shot uploads for providers that also offer synchronous transcription.
 * ElevenLabs and Grok take raw 16 kHz PCM; Gemini takes a WAV container.
 */
object PortableBatchB {
    suspend fun transcribe(
        providerId: String,
        config: AsrConfig,
        pcm: ByteArray,
        hotwords: List<String>,
    ): String? = when (providerId) {
        "elevenlabs" -> ElevenLabsBatch.transcribe(config, pcm, hotwords)
        "grok" -> GrokBatch.transcribe(config, pcm, hotwords)
        "gemini" -> GeminiBatch.transcribe(config, pcm, hotwords)
        else -> null
    }

    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(90, TimeUnit.SECONDS)
        .writeTimeout(90, TimeUnit.SECONDS)
        .build()

    private val JSON = "application/json".toMediaType()
    private val PCM = "application/octet-stream".toMediaType()

    private fun execute(request: Request): String = client.newCall(request).execute().use { response ->
        val body = response.body?.string().orEmpty()
        if (!response.isSuccessful) throw AsrException(errorMessage(response.code, body))
        body
    }

    private fun errorMessage(code: Int, body: String): String {
        val json = runCatching { JSONObject(body) }.getOrNull()
        val detail = json?.optJSONObject("error")?.optString("message")?.takeIf { it.isNotBlank() }
            ?: json?.optString("message")?.takeIf { it.isNotBlank() }
            ?: json?.optString("detail")?.takeIf { it.isNotBlank() }
            ?: body.take(160).takeIf { it.isNotBlank() }
        return buildString {
            append("HTTP ").append(code)
            if (detail != null) append(": ").append(detail)
        }
    }

    private fun requireAudio(pcm: ByteArray) {
        if (pcm.isEmpty()) throw AsrException("No audio recorded")
    }

    private object ElevenLabsBatch {
        private const val ENDPOINT = "https://api.elevenlabs.io/v1/speech-to-text"
        private const val DEFAULT_MODEL = "scribe_v2"

        suspend fun transcribe(config: AsrConfig, pcm: ByteArray, hotwords: List<String>): String =
            withContext(Dispatchers.IO) {
                requireAudio(pcm)
                val form = MultipartBody.Builder().setType(MultipartBody.FORM)
                    .addFormDataPart("model_id", config.resolvedBatchModel(DEFAULT_MODEL))
                    .addFormDataPart("file_format", "pcm_s16le_16")
                    .addFormDataPart("tag_audio_events", "false")
                    .addFormDataPart("timestamps_granularity", "none")
                    .addFormDataPart("no_verbatim", "true")
                val language = config.extraValue("language")
                if (language.isNotEmpty()) form.addFormDataPart("language_code", language)
                ElevenLabsProtocol.keyterms(hotwords).forEach { form.addFormDataPart("keyterms", it) }
                form.addFormDataPart("file", "audio.pcm", pcm.toRequestBody(PCM))

                val request = Request.Builder()
                    .url(batchHttpUrl(config.baseUrl, ENDPOINT))
                    .header("xi-api-key", config.apiKey)
                    .post(form.build())
                    .build()
                val body = execute(request)
                val json = runCatching { JSONObject(body) }.getOrElse {
                    throw AsrException("Could not parse the ElevenLabs response")
                }
                json.optString("text").trim()
            }
    }

    private object GrokBatch {
        private const val ENDPOINT = "https://api.x.ai/v1/stt"
        private const val MODEL = "grok-voice-transcribe-2.0"

        suspend fun transcribe(config: AsrConfig, pcm: ByteArray, hotwords: List<String>): String =
            withContext(Dispatchers.IO) {
                requireAudio(pcm)
                val form = MultipartBody.Builder().setType(MultipartBody.FORM)
                    .addFormDataPart("model", config.resolvedModel(MODEL))
                    .addFormDataPart("audio_format", "pcm")
                    .addFormDataPart("sample_rate", "16000")
                    .addFormDataPart("filler_words", "false")
                val language = config.extraValue("language")
                if (language.isNotEmpty()) form.addFormDataPart("language", language)
                GrokProtocol.keyterms(hotwords).forEach { form.addFormDataPart("keyterm", it) }
                // The file part must come after every option field.
                form.addFormDataPart("file", "audio.pcm", pcm.toRequestBody(PCM))

                val request = Request.Builder()
                    .url(batchHttpUrl(config.baseUrl, ENDPOINT))
                    .header("Authorization", "Bearer ${config.apiKey}")
                    .post(form.build())
                    .build()
                val body = execute(request)
                val json = runCatching { JSONObject(body) }.getOrElse {
                    throw AsrException("Could not parse the Grok response")
                }
                json.optString("text").trim()
            }
    }

    private object GeminiBatch {
        private const val ENDPOINT_BASE =
            "https://generativelanguage.googleapis.com/v1beta/"

        suspend fun transcribe(config: AsrConfig, pcm: ByteArray, hotwords: List<String>): String =
            withContext(Dispatchers.IO) {
                requireAudio(pcm)
                val model = config.resolvedBatchModel(GeminiProtocol.DEFAULT_BATCH_MODEL)
                val endpoint = batchHttpUrl(config.baseUrl, ENDPOINT_BASE)
                    .trimEnd('/') + "/" + GeminiProtocol.qualifiedModelName(model) +
                    ":generateContent"

                val transcription = JSONObject().put("mode", GeminiProtocol.transcriptionMode(config))
                val languageCodes = GeminiProtocol.languageCodes(config)
                if (languageCodes.isNotEmpty()) {
                    transcription.put("languageCodes", JSONArray(languageCodes))
                }
                val vocabulary = GeminiProtocol.sanitizeHotwords(hotwords)
                if (vocabulary.isNotEmpty()) {
                    transcription.put("customVocabulary", JSONArray(vocabulary))
                }

                val wav = WavEncoder.encode(pcm)
                val inlineData = JSONObject()
                    .put("mimeType", "audio/wav")
                    .put("data", java.util.Base64.getEncoder().encodeToString(wav))
                val body = JSONObject()
                    .put(
                        "contents",
                        JSONArray().put(
                            JSONObject()
                                .put("role", "user")
                                .put("parts", JSONArray().put(JSONObject().put("inlineData", inlineData))),
                        ),
                    )
                    .put(
                        "generationConfig",
                        JSONObject().put("audioTranscriptionConfig", transcription),
                    )

                val request = Request.Builder()
                    .url(endpoint)
                    .header("x-goog-api-key", config.apiKey)
                    .post(body.toString().toRequestBody(JSON))
                    .build()
                parseTranscript(execute(request), hotwords)
            }

        private fun parseTranscript(body: String, hotwords: List<String>): String {
            val root = runCatching { JSONObject(body) }.getOrElse {
                throw AsrException("Could not parse the Gemini response")
            }
            root.optJSONObject("promptFeedback")?.optString("blockReason")
                ?.takeIf { it.isNotBlank() }
                ?.let { throw AsrException("Gemini blocked the audio: $it") }

            val candidates = root.optJSONArray("candidates")
            val candidate = if (candidates != null && candidates.length() > 0) {
                candidates.optJSONObject(0)
            } else {
                null
            } ?: throw AsrException("Could not parse the Gemini response")

            // Only a normal stop without content means silence; SAFETY, RECITATION, etc. are failures.
            val finishReason = candidate.optString("finishReason")
            if (finishReason.isNotEmpty() && finishReason !in NORMAL_FINISH_REASONS) {
                throw AsrException("Gemini stopped transcribing: $finishReason")
            }
            val parts = candidate.optJSONObject("content")?.optJSONArray("parts") ?: return ""
            val text = buildString {
                for (index in 0 until parts.length()) {
                    append(parts.optJSONObject(index)?.optString("text").orEmpty())
                }
            }.trim()
            return AsrTextTools.sanitizeHotwordLeak(text, hotwords)
        }

        private val NORMAL_FINISH_REASONS =
            setOf("STOP", "MAX_TOKENS", "FINISH_REASON_UNSPECIFIED")
    }
}
