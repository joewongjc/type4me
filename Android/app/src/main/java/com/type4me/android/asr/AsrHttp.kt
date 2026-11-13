package com.type4me.android.asr

import org.json.JSONObject
import java.util.Base64

/** Shared encoding and error text for the HTTP batch ASR clients. */
internal object AsrHttp {
    fun base64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    fun errorMessage(code: Int, body: String): String {
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
}
