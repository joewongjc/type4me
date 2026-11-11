package com.type4me.android.asr

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * OkHttp only parses http(s) URLs, so WebSocket endpoints are converted for
 * query building and converted back before the handshake.
 */
internal fun websocketUrl(
    rawBase: String,
    defaultBase: String,
    invalidMessage: String,
    configure: (okhttp3.HttpUrl.Builder) -> Unit = {},
): String {
    val raw = rawBase.trim().ifEmpty { defaultBase }
    val httpForm = when {
        raw.startsWith("wss://", ignoreCase = true) -> "https://" + raw.substring(6)
        raw.startsWith("ws://", ignoreCase = true) -> "http://" + raw.substring(5)
        else -> raw
    }
    val parsed = httpForm.toHttpUrlOrNull() ?: throw AsrException(invalidMessage)
    val built = parsed.newBuilder().also(configure).build().toString()
    return when {
        built.startsWith("https://") -> "wss://" + built.removePrefix("https://")
        built.startsWith("http://") -> "ws://" + built.removePrefix("http://")
        else -> built
    }
}
