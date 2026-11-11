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
import org.json.JSONObject
import java.util.concurrent.TimeUnit

class AsrException(message: String) : Exception(message)

/**
 * OpenAI-compatible /audio/transcriptions. One request per dictation, with the
 * whole recording uploaded when the user lets go.
 */
class OpenAITranscriptionClient(
    private val client: OkHttpClient = defaultClient,
) {
    suspend fun transcribe(
        config: AsrConfig,
        wav: ByteArray,
        hotwords: List<String> = emptyList(),
    ): String = withContext(Dispatchers.IO) {
        if (config.kind != com.type4me.android.data.AsrKind.OPENAI) {
            throw AsrException("This provider streams live audio")
        }
        if (wav.size <= 44) throw AsrException("No audio recorded")
        val multipart = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("file", "audio.wav", wav.toRequestBody(WAV))
            .addFormDataPart("model", config.model)
        // Whisper-family endpoints take a prompt hint; some others reject
        // unknown form fields, so only the known-compatible presets get one.
        val supportsPrompt = config.providerId.isEmpty() ||
            config.providerId in setOf("openai", "groq", "mistral", "custom")
        val prompt = hotwords.map { it.trim() }.filter { it.isNotEmpty() }
            .take(50).joinToString(", ")
        if (supportsPrompt && prompt.isNotEmpty()) multipart.addFormDataPart("prompt", prompt)
        val request = Request.Builder()
            .url(endpoint(config.baseUrl))
            .post(multipart.build())
            .apply {
                if (config.apiKey.isNotBlank()) {
                    header("Authorization", "Bearer ${config.apiKey}")
                }
            }
            .build()

        client.newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw AsrException(errorMessage(response.code, body))
            }
            parseText(body)
        }
    }

    /** Uploads a second of silence. A 2xx response means URL, key and model are usable. */
    suspend fun test(config: AsrConfig): Long = withContext(Dispatchers.IO) {
        val started = System.currentTimeMillis()
        transcribe(config, WavEncoder.encode(ByteArray(32_000)))
        System.currentTimeMillis() - started
    }

    private fun endpoint(baseUrl: String): String {
        val trimmed = baseUrl.trim().trimEnd('/')
        if (trimmed.isEmpty()) throw AsrException("Speech service URL is empty")
        if (trimmed.endsWith("/audio/transcriptions")) return trimmed
        return "$trimmed/audio/transcriptions"
    }

    private fun parseText(body: String): String {
        if (body.isBlank()) throw AsrException("The speech service returned an empty response")
        val json = runCatching { JSONObject(body) }
            .getOrElse { throw AsrException("Could not parse the speech service response") }
        val rootText = if (json.isNull("text")) "" else json.optString("text")
        val data = json.optJSONObject("data")
        val dataText = if (data == null || data.isNull("text")) "" else data.optString("text")
        val text = rootText.ifBlank { dataText }
        // A valid empty transcript is the service saying it heard nothing;
        // the caller has a clearer message for that than the raw JSON.
        return text.trim()
    }

    private fun errorMessage(code: Int, body: String): String {
        val json = runCatching { JSONObject(body) }.getOrNull()
        val detail = json?.optJSONObject("error")?.optString("message")?.takeIf { it.isNotBlank() }
            ?: json?.optString("message")?.takeIf { it.isNotBlank() }
            ?: json?.optString("detail")?.takeIf { it.isNotBlank() }
            ?: body.take(160).takeIf { it.isNotBlank() }
        return buildString {
            if (code > 0) append("HTTP ").append(code) else append("Unexpected response")
            if (detail != null) append(": ").append(detail)
        }
    }

    companion object {
        private val WAV = "audio/wav".toMediaType()

        private val defaultClient = OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(90, TimeUnit.SECONDS)
            .writeTimeout(90, TimeUnit.SECONDS)
            .build()
    }
}
