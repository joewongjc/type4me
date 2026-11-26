package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PortableAsrRoutingTest {
    @Test
    fun portableStreamingMapsProviderIds() {
        val onPartial: (String) -> Unit = {}
        val onError: (Throwable) -> Unit = {}
        assertTrue(StreamingAsrProviders.create("elevenlabs", onPartial, onError) is ElevenLabsSession)
        assertTrue(StreamingAsrProviders.create("grok", onPartial, onError) is GrokSession)
        assertTrue(StreamingAsrProviders.create("azure", onPartial, onError) is AzureSession)
        assertNull(StreamingAsrProviders.create("volcano", onPartial, onError))
    }

    @Test
    fun portableBatchLeavesUnsupportedProvidersToOthers() = runBlocking {
        assertNull(PortableBatchB.transcribe("soniox", AsrConfig(), ByteArray(2), emptyList()))
    }

    @Test
    fun resolvedBatchModelPrefersExtraThenModelThenDefault() {
        assertEquals(
            "from-extra",
            AsrConfig(
                model = "from-model",
                extra = mapOf("batchModel" to " from-extra "),
            ).resolvedBatchModel("fallback"),
        )
        assertEquals("from-model", AsrConfig(model = " from-model ").resolvedBatchModel("fallback"))
        assertEquals("fallback", AsrConfig().resolvedBatchModel("fallback"))
    }

    @Test
    fun resolvedModelKeepsItsStreamingPrecedence() {
        assertEquals(
            "from-model",
            AsrConfig(
                model = " from-model ",
                extra = mapOf("model" to "from-extra"),
            ).resolvedModel("fallback"),
        )
        assertEquals(
            "from-extra",
            AsrConfig(extra = mapOf("model" to " from-extra ")).resolvedModel("fallback"),
        )
        assertEquals("fallback", AsrConfig().resolvedModel("fallback"))
    }
}
