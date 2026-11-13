package com.type4me.android.asr

/** Streaming sessions keyed by provider id. */
internal object StreamingAsrProviders {
    fun create(
        providerId: String,
        onPartial: (String) -> Unit,
        onError: (Throwable) -> Unit,
    ): StreamingAsrSession? = when (providerId) {
        "stepfun" -> StepFunSession(onPartial, onError)
        "deepgram" -> DeepgramSession(onPartial, onError)
        "cartesia" -> CartesiaSession(onPartial, onError)
        "assemblyai" -> AssemblyAISession(onPartial, onError)
        "elevenlabs" -> ElevenLabsSession(onPartial, onError)
        "gemini" -> GeminiSession(onPartial, onError)
        "grok" -> GrokSession(onPartial, onError)
        "metaMuse" -> MetaMuseSession(onPartial, onError)
        "bailian" -> BailianSession(onPartial, onError)
        "azure" -> AzureSession(onPartial, onError)
        "tencent" -> TencentSession(onPartial, onError)
        else -> null
    }
}
