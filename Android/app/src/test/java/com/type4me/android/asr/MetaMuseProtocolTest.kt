package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import com.type4me.android.data.AsrKind
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class MetaMuseProtocolTest {
    private fun config(extra: Map<String, String> = emptyMap()) = AsrConfig(
        kind = AsrKind.OPENAI,
        providerId = "metaMuse",
        apiKey = "secret",
        extra = extra,
    )

    @Test
    fun handshakeCarriesAuthModelAndKeywords() {
        val json = JSONObject(
            MetaMuseProtocol.handshakeMessage(
                config(extra = mapOf("languageBias" to "Chinese")),
                listOf("Type4Me", "Type4Me", "x".repeat(30)),
            ),
        )
        assertEquals(
            "Bearer secret",
            json.getJSONObject("authorization").getString("accessToken"),
        )
        assertEquals("PCM_16KHZ", json.getString("audioEncoding"))
        assertEquals("muse-voice-transcribe-1.0", json.getString("model"))
        assertEquals("PUSH_TO_TALK", json.getString("mode"))
        assertEquals("Chinese", json.getJSONArray("languageBias").getString(0))
        val keywords = json.getJSONArray("keywords")
        assertEquals(2, keywords.length())
        assertEquals("Type4Me", keywords.getString(0))
        assertEquals(20, keywords.getString(1).length)
    }

    @Test
    fun handshakeOmitsEmptyOptionalFields() {
        val json = JSONObject(MetaMuseProtocol.handshakeMessage(config(), emptyList()))
        assertFalse(json.has("keywords"))
        assertFalse(json.has("languageBias"))
    }

    @Test
    fun endStreamMessageAsksForTheFinalTranscript() {
        assertEquals("endStream", JSONObject(MetaMuseProtocol.endStreamMessage()).getString("type"))
    }

    @Test
    fun handshakeResponseWithoutTypeIsSessionReady() {
        val event = MetaMuseProtocol.parse("""{"sessionId":"abc"}""")
        assertTrue(event is MetaMuseProtocol.Event.SessionReady)
        assertEquals("abc", (event as MetaMuseProtocol.Event.SessionReady).sessionId)
    }

    @Test
    fun typedSessionReadyIsOK() {
        val event = MetaMuseProtocol.parse("""{"type":"session.ready","session_id":"xyz"}""")
        assertEquals("xyz", (event as MetaMuseProtocol.Event.SessionReady).sessionId)
    }

    @Test
    fun transcriptEventCarriesFinality() {
        val partial = MetaMuseProtocol.parse("""{"type":"transcript","transcript":"hello","final":false}""")
            as MetaMuseProtocol.Event.Transcript
        assertEquals("hello", partial.text)
        assertFalse(partial.isFinal)

        val final = MetaMuseProtocol.parse("""{"type":"transcript","text":"hello world","final":true}""")
            as MetaMuseProtocol.Event.Transcript
        assertTrue(final.isFinal)
        assertEquals("hello world", final.text)
    }

    @Test
    fun authErrorsAreReported() {
        val event = MetaMuseProtocol.parse("""{"type":"error","message":"unauthorized api key"}""")
        val failed = event as MetaMuseProtocol.Event.Failed
        assertTrue(failed.message.contains("authentication failed"))
    }

    @Test
    fun unknownEventsAreIgnored() {
        val event = MetaMuseProtocol.parse("""{"type":"heartbeat"}""")
        assertEquals("heartbeat", (event as MetaMuseProtocol.Event.Ignored).type)
    }

    @Test
    fun unparseableFramesThrow() {
        try {
            MetaMuseProtocol.parse("[]")
            fail("expected an error")
        } catch (error: AsrException) {
            assertTrue(error.message!!.contains("unparseable"))
        }
    }
}
