package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import com.type4me.android.data.AsrKind
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class GrokProtocolTest {
    /** OkHttp parses http(s) only; the handshake URL is the same with a ws scheme. */
    private fun String.toHttpUrlForTest() = replaceFirst("wss://", "https://").toHttpUrl()

    private fun config(
        model: String = "",
        extra: Map<String, String> = emptyMap(),
    ) = AsrConfig(
        kind = AsrKind.OPENAI,
        providerId = "grok",
        model = model,
        apiKey = "secret",
        extra = extra,
    )

    @Test
    fun buildsPushToTalkUrl() {
        val url = GrokProtocol
            .buildWebSocketUrl(config(extra = mapOf("language" to "ja")), listOf("Type4Me", "b".repeat(51)))
            .toHttpUrlForTest()

        assertEquals("api.x.ai", url.host)
        assertEquals("/v1/stt", url.encodedPath)
        assertEquals("grok-voice-transcribe-2.0", url.queryParameter("model"))
        assertEquals("16000", url.queryParameter("sample_rate"))
        assertEquals("pcm", url.queryParameter("encoding"))
        assertEquals("true", url.queryParameter("interim_results"))
        assertEquals("false", url.queryParameter("filler_words"))
        assertEquals("0.7", url.queryParameter("smart_turn"))
        assertEquals("3000", url.queryParameter("smart_turn_timeout"))
        assertEquals("ja", url.queryParameter("language"))
        assertEquals(listOf("Type4Me"), url.queryParameterValues("keyterm"))
    }

    @Test
    fun clientMessagesAskForAFinalTranscript() {
        assertEquals("finalize", org.json.JSONObject(GrokProtocol.finalizeMessage()).getString("type"))
        assertEquals("audio.done", org.json.JSONObject(GrokProtocol.audioDoneMessage()).getString("type"))
    }

    @Test
    fun createdEventMarksTheServerReady() {
        val update = GrokProtocol.parse(
            """{"type":"transcript.created"}""",
            GrokProtocol.State(),
            isFinalCommit = false,
        )
        assertTrue(update!!.serverReady)
    }

    @Test
    fun interimPartialReplacesThePendingTail() {
        val state = GrokProtocol.State(utterances = listOf("hello"))
        val update = GrokProtocol.parse(
            """{"type":"transcript.partial","is_final":false,"text":"hello world"}""",
            state,
            isFinalCommit = false,
        )
        assertEquals(" world", update?.partial)
        assertFalse(update!!.isFinal)
    }

    @Test
    fun chunkFinalIsAppendedToTheConfirmedText() {
        val update = GrokProtocol.parse(
            """{"type":"transcript.partial","is_final":true,"text":"hello"}""",
            GrokProtocol.State(),
            isFinalCommit = false,
        )
        assertEquals("hello", update!!.state.joinedConfirmed)
        assertFalse(update!!.isFinal)
    }

    @Test
    fun speechFinalRevisesTheChunkRatherThanDuplicatingIt() {
        val chunked = GrokProtocol.State(chunks = listOf("hello"))
        val update = GrokProtocol.parse(
            """{"type":"transcript.partial","is_final":true,"speech_final":true,"text":"hello world"}""",
            chunked,
            isFinalCommit = false,
        )
        assertEquals(listOf("hello world"), update!!.state.utterances)
        assertTrue(update!!.state.chunks.isEmpty())
        assertEquals("hello world", update!!.state.joinedConfirmed)
    }

    @Test
    fun transcriptDonePrefersTheServerTranscriptAndFinishes() {
        val state = GrokProtocol.State(utterances = listOf("hello world"))
        val update = GrokProtocol.parse(
            """{"type":"transcript.done","text":"hello world."}""",
            state,
            isFinalCommit = true,
        )
        assertTrue(update!!.isFinal)
        assertEquals("hello world.", update!!.state.joinedConfirmed)
    }

    @Test
    fun chineseConfirmedSegmentsJoinWithoutSpaces() {
        assertEquals(
            "你好世界",
            GrokProtocol.State(utterances = listOf("你好", "世界")).joinedConfirmed,
        )
        assertEquals(
            "hello world",
            GrokProtocol.State(utterances = listOf("hello", "world")).joinedConfirmed,
        )
    }

    @Test
    fun emptyPartialIsIgnored() {
        assertNull(
            GrokProtocol.parse(
                """{"type":"transcript.partial","is_final":false,"text":"  "}""",
                GrokProtocol.State(),
                isFinalCommit = false,
            ),
        )
    }

    @Test
    fun serverErrorsAreReported() {
        try {
            GrokProtocol.parse(
                """{"type":"error","message":"bad key"}""",
                GrokProtocol.State(),
                isFinalCommit = false,
            )
            fail("expected an error")
        } catch (error: AsrException) {
            assertTrue(error.message!!.contains("bad key"))
        }
    }
}
