package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class CartesiaProtocolTest {
    @Test
    fun buildsUrlWithVersionEncodingAndKeyterms() {
        val url = CartesiaProtocol.buildUrl(AsrConfig(), listOf("Type4Me", "  "))
        assertTrue(url.startsWith("wss://api.cartesia.ai/stt/websocket?"))
        assertTrue(url.contains("model=ink-2"))
        assertTrue(url.contains("encoding=pcm_s16le"))
        assertTrue(url.contains("sample_rate=16000"))
        assertTrue(url.contains("cartesia_version=2026-08-14"))
        assertTrue(url.contains("language=zh"))
        assertTrue(url.contains("keyterm=Type4Me"))
    }

    @Test
    fun honorsConfiguredModelLanguageAndEndpoint() {
        val url = CartesiaProtocol.buildUrl(
            AsrConfig(
                baseUrl = "wss://proxy.test/stt",
                model = "ink-2-pro",
                extra = mapOf("language" to "zh"),
            ),
            emptyList(),
        )
        assertTrue(url.startsWith("wss://proxy.test/stt?"))
        assertTrue(url.contains("model=ink-2-pro"))
        assertTrue(url.contains("language=zh"))
    }

    @Test
    fun accumulatesFinalChunksAndKeepsInterimText() {
        val interim = CartesiaProtocol.parse(
            """{"type":"transcript","is_final":false,"text":"hello"}""",
            emptyList(),
        )!!
        assertEquals("hello", interim.text)
        assertFalse(interim.final)
        assertTrue(interim.confirmedSegments.isEmpty())

        val final = CartesiaProtocol.parse(
            """{"type":"transcript","is_final":true,"text":"hello."}""",
            interim.confirmedSegments,
        )!!
        assertEquals("hello.", final.text)
        assertTrue(final.final)
        assertEquals(listOf("hello."), final.confirmedSegments)
    }

    @Test
    fun ignoresUnrelatedMessages() {
        assertNull(CartesiaProtocol.parse("""{"type":"done"}""", emptyList()))
    }

    @Test
    fun surfacesServerErrors() {
        try {
            CartesiaProtocol.parse(
                """{"type":"error","title":"unauthorized","message":"bad key"}""",
                emptyList(),
            )
            fail("expected an AsrException")
        } catch (error: AsrException) {
            assertTrue(error.message.orEmpty().contains("unauthorized"))
            assertTrue(error.message.orEmpty().contains("bad key"))
        }
    }
}
