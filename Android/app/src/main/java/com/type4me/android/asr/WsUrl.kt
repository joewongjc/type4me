package com.type4me.android.asr

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * OkHttp only parses http(s) URLs, so WebSocket endpoints are converted for
 * query building and converted back before the handshake.
 */
internal fun httpForm(url: String): okhttp3.HttpUrl? {
    val trimmed = url.trim()
    val http = when {
        trimmed.startsWith("wss://", ignoreCase = true) -> "https://" + trimmed.substring(6)
        trimmed.startsWith("ws://", ignoreCase = true) -> "http://" + trimmed.substring(5)
        else -> trimmed
    }
    return http.toHttpUrlOrNull()
}

internal fun websocketUrl(
    rawBase: String,
    defaultBase: String,
    invalidMessage: String,
    configure: (okhttp3.HttpUrl.Builder) -> Unit = {},
): String {
    val raw = rawBase.trim().ifEmpty { defaultBase }
    val parsed = httpForm(raw) ?: throw AsrException(invalidMessage)
    val built = parsed.newBuilder().also(configure).build().toString()
    return when {
        built.startsWith("https://") -> "wss://" + built.removePrefix("https://")
        built.startsWith("http://") -> "ws://" + built.removePrefix("http://")
        else -> built
    }
}
