package com.type4me.android.asr

/**
 * Portable streaming providers that are not part of [com.type4me.android.data.AsrKind].
 * Sessions are constructed here so the shared client code stays untouched.
 */
object PortableStreamingC {
    fun create(
        providerId: String,
        onPartial: (String) -> Unit,
        onError: (Throwable) -> Unit,
    ): StreamingAsrSession? = when (providerId) {
        "bailian" -> BailianSession(onPartial, onError)
        "azure" -> AzureSession(onPartial, onError)
        "tencent" -> TencentSession(onPartial, onError)
        else -> null
    }
}
