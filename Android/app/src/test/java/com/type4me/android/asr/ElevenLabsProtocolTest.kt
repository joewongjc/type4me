package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import com.type4me.android.data.AsrKind
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.Base64

class ElevenLabsProtocolTest {
    /** OkHttp parses http(s) only; the handshake URL is the same with a ws scheme. */
    private fun String.toHttpUrlForTest() = replaceFirst("wss://", "https://").toHttpUrl()

    private fun config(
        model: String = "",
        baseUrl: String = "",
        extra: Map<String, String> = emptyMap(),
    ) = AsrConfig(
        kind = AsrKind.OPENAI,
        providerId = "elevenlabs",
        baseUrl = baseUrl,
        model = model,
        apiKey = "secret",
        extra = extra,
    )

    @Test
    fun buildsRealtimeUrlWithModelLanguageAndKeyterms() {
        val url = ElevenLabsProtocol
            .buildWebSocketUrl(
                config(model = "scribe_v2_realtime", extra = mapOf("language" to "zh")),
                listOf(" Type4Me ", "", "a".repeat(21)),
            )
            .toHttpUrlForTest()

        assertEquals("api.elevenlabs.io", url.host)
        assertEquals("/v1/speech-to-text/realtime", url.encodedPath)
        assertEquals("scribe_v2_realtime", url.queryParameter("model_id"))
        assertEquals("pcm_16000", url.queryParameter("audio_format"))
        assertEquals("true", url.queryParameter("no_verbatim"))
        assertEquals("zh", url.queryParameter("language_code"))
        assertEquals(listOf("Type4Me"), url.queryParameterValues("keyterm"))
    }

    @Test
    fun defaultsTheModelWhenNoneIsConfigured() {
        val url = ElevenLabsProtocol.buildWebSocketUrl(config(), emptyList()).toHttpUrlForTest()
        assertEquals("scribe_v2_realtime", url.queryParameter("model_id"))
        assertNull(url.queryParameter("language_code"))
    }

    @Test
    fun audioChunkCarriesBase64Pcm() {
        val pcm = byteArrayOf(1, 2, 3, 4)
        val json = JSONObject(ElevenLabsProtocol.audioChunkMessage(pcm))
        assertEquals("input_audio_chunk", json.getString("message_type"))
        assertEquals(16000, json.getInt("sample_rate"))
        assertEquals(Base64.getEncoder().encodeToString(pcm), json.getString("audio_base_64"))
        assertFalse(json.has("commit"))
    }

    @Test
    fun commitMessageAsksForAFinalTranscript() {
        val json = JSONObject(ElevenLabsProtocol.commitMessage())
        assertEquals("input_audio_chunk", json.getString("message_type"))
        assertEquals("", json.getString("audio_base_64"))
        assertTrue(json.getBoolean("commit"))
    }

    @Test
    fun parsesPartialTranscript() {
        val update = ElevenLabsProtocol.parse(
            """{"message_type":"partial_transcript","text":"hello"}""",
            emptyList(),
            isFinalCommit = false,
            languageCode = "",
        )
        assertEquals("hello", update?.partial)
        assertTrue(update!!.confirmedSegments.isEmpty())
        assertFalse(update!!.isFinal)
    }

    @Test
    fun stripsTheConfirmedPrefixFromCumulativePartials() {
        val update = ElevenLabsProtocol.parse(
            """{"message_type":"partial_transcript","text":"hello world"}""",
            listOf("hello "),
            isFinalCommit = false,
            languageCode = "en",
        )
        assertEquals("world", update?.partial)
    }

    @Test
    fun commitsAreNotFinalUntilTheClientAsksToFinish() {
        val body = """{"message_type":"committed_transcript","text":"hello"}"""

        val midStream = ElevenLabsProtocol.parse(body, emptyList(), isFinalCommit = false, languageCode = "")
        assertEquals(listOf("hello"), midStream?.confirmedSegments)
        assertFalse(midStream!!.isFinal)

        val closing = ElevenLabsProtocol.parse(body, emptyList(), isFinalCommit = true, languageCode = "")
        assertTrue(closing!!.isFinal)
    }

    @Test
    fun throttledCommitFinishesTheTranscript() {
        val update = ElevenLabsProtocol.parse(
            """{"message_type":"commit_throttled"}""",
            listOf("hello"),
            isFinalCommit = true,
            languageCode = "",
        )
        assertTrue(update!!.isFinal)
        assertEquals(listOf("hello"), update!!.confirmedSegments)
    }

    @Test
    fun throttledCommitWithNoTextIsIgnored() {
        assertNull(
            ElevenLabsProtocol.parse(
                """{"message_type":"commit_throttled"}""",
                emptyList(),
                isFinalCommit = false,
                languageCode = "",
            ),
        )
    }

    @Test
    fun serverErrorsAreReported() {
        try {
            ElevenLabsProtocol.parse(
                """{"message_type":"error","message":"bad audio"}""",
                emptyList(),
                isFinalCommit = false,
                languageCode = "",
            )
            fail("expected an error")
        } catch (error: AsrException) {
            assertTrue(error.message!!.contains("bad audio"))
        }
    }

    @Test
    fun unacceptedTermsAreReported() {
        try {
            ElevenLabsProtocol.parse(
                """{"message_type":"unaccepted_terms"}""",
                emptyList(),
                isFinalCommit = false,
                languageCode = "",
            )
            fail("expected an error")
        } catch (error: AsrException) {
            assertTrue(error.message!!.contains("terms"))
        }
    }
}
