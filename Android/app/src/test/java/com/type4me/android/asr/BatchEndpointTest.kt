package com.type4me.android.asr

import com.type4me.android.data.Presets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BatchEndpointTest {
    private val grokBatch = "https://api.x.ai/v1/stt"

    @Test
    fun websocketAddressesFallBackToTheBatchEndpoint() {
        assertEquals(grokBatch, batchHttpUrl("wss://api.x.ai/v1/stt", grokBatch))
        assertEquals(grokBatch, batchHttpUrl("ws://proxy.test/stt", grokBatch))
        assertEquals(grokBatch, batchHttpUrl(" WSS://API.X.AI/V1/STT ", grokBatch))
    }

    @Test
    fun blankAddressUsesTheBatchEndpoint() {
        assertEquals(grokBatch, batchHttpUrl("", grokBatch))
        assertEquals(grokBatch, batchHttpUrl("   ", grokBatch))
    }

    @Test
    fun httpAddressIsKept() {
        assertEquals("https://proxy.test/v1/stt", batchHttpUrl(" https://proxy.test/v1/stt ", grokBatch))
    }

    @Test
    fun batchPresetsCarryTheirOwnHttpEndpoint() {
        assertEquals(
            "https://api.elevenlabs.io/v1/speech-to-text",
            Presets.asrById("elevenlabs").batchBaseUrl,
        )
        assertEquals(
            "https://generativelanguage.googleapis.com/v1beta/",
            Presets.asrById("gemini").batchBaseUrl,
        )
        assertEquals(grokBatch, Presets.asrById("grok").batchBaseUrl)
        assertTrue(Presets.asrById("deepgram").batchBaseUrl.isEmpty())
    }
}
