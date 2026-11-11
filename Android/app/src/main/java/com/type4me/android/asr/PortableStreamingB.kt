package com.type4me.android.asr

/**
 * Streaming providers added by this batch. Keyed by provider id so a config
 * can be routed without [com.type4me.android.data.AsrKind] entries for each one.
 */
object PortableStreamingB {
    fun create(
        providerId: String,
        onPartial: (String) -> Unit,
        onError: (Throwable) -> Unit,
    ): StreamingAsrSession? = when (providerId) {
        "elevenlabs" -> ElevenLabsSession(onPartial, onError)
        "gemini" -> GeminiSession(onPartial, onError)
        "grok" -> GrokSession(onPartial, onError)
        "metaMuse" -> MetaMuseSession(onPartial, onError)
        else -> null
    }
}
