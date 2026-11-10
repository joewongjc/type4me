package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONArray
import org.json.JSONObject

object SonioxProtocol {
    const val ENDPOINT = "wss://stt-rt.soniox.com/transcribe-websocket"

    data class Update(
        val finalized: String,
        val partial: String,
        val finished: Boolean,
        val error: String?,
    )

    fun startMessage(config: AsrConfig, hotwords: List<String>): String {
        val json = JSONObject()
            .put("model", config.model.ifBlank { "stt-rt-v5" })
            .put("audio_format", "pcm_s16le")
            .put("sample_rate", 16000)
            .put("num_channels", 1)
            .put("enable_endpoint_detection", true)
            .put("endpoint_sensitivity", config.endpointSensitivity)
            .put("max_endpoint_delay_ms", 2000)
            .put("language_hints", JSONArray().put("zh").put("en"))
            .put("language_hints_strict", true)
            .put("api_key", config.apiKey)

        val terms = hotwords.map { it.trim() }.filter { it.isNotEmpty() }.take(100)
        if (terms.isNotEmpty()) {
            json.put(
                "context",
                JSONObject().put("terms", JSONArray().apply { terms.forEach { put(it) } }),
            )
        }
        return json.toString()
    }

    fun parse(text: String): Update {
        val json = runCatching { JSONObject(text) }.getOrElse {
            throw AsrException("Could not parse the Soniox response")
        }
        val errorCode = json.optInt("error_code", 0)
        if (errorCode != 0) {
            val message = json.optString("error_message").ifBlank { "Soniox request failed" }
            throw AsrException("$message ($errorCode)")
        }

        val tokens = json.optJSONArray("tokens") ?: JSONArray()
        val finalized = StringBuilder()
        val partial = StringBuilder()
        for (index in 0 until tokens.length()) {
            val token = tokens.optJSONObject(index) ?: continue
            val value = token.optString("text")
            if (value == "<end>" || value == "<fin>") continue
            if (token.optBoolean("is_final", false)) finalized.append(value) else partial.append(value)
        }

        return Update(
            finalized = finalized.toString(),
            partial = partial.toString(),
            finished = json.optBoolean("finished", false),
            error = null,
        )
    }
}
