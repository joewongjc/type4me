package com.type4me.android.asr

/**
 * Factory for the portable streaming providers that do not need a dedicated
 * [com.type4me.android.data.AsrKind] case.
 */
object PortableStreamingA {
    fun create(
        providerId: String,
        onPartial: (String) -> Unit,
        onError: (Throwable) -> Unit,
    ): StreamingAsrSession? = when (providerId) {
        "stepfun" -> StepFunSession(onPartial, onError)
        "deepgram" -> DeepgramSession(onPartial, onError)
        "cartesia" -> CartesiaSession(onPartial, onError)
        "assemblyai" -> AssemblyAISession(onPartial, onError)
        else -> null
    }
}
