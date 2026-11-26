package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import com.type4me.android.data.AsrKind
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.Base64

class GeminiProtocolTest {
    private fun config(
        model: String = "",
        extra: Map<String, String> = emptyMap(),
    ) = AsrConfig(
        kind = AsrKind.OPENAI,
        providerId = "gemini",
        model = model,
        apiKey = "secret",
        extra = extra,
    )

    @Test
    fun setupMessageDescribesATranscriptionOnlySession() {
        val json = JSONObject(
            GeminiProtocol.setupMessage(
                config(extra = mapOf("languageCode" to "cmn-Hans-CN", "mode" to "VERBATIM")),
                listOf("Type4Me", "Type4Me"),
            ),
        ).getJSONObject("setup")

        assertEquals("models/gemini-3.5-transcribe-live", json.getString("model"))
        assertEquals(
            "TEXT",
            json.getJSONObject("generationConfig").getJSONArray("responseModalities").getString(0),
        )
        assertTrue(
            json.getJSONObject("realtimeInputConfig")
                .getJSONObject("automaticActivityDetection")
                .getBoolean("disabled"),
        )
        val transcription = json.getJSONObject("inputAudioTranscription")
        assertEquals("VERBATIM", transcription.getString("mode"))
        assertEquals("cmn-Hans-CN", transcription.getJSONArray("languageCodes").getString(0))
        val vocabulary = transcription.getJSONArray("customVocabulary")
        assertEquals(1, vocabulary.length())
        assertEquals("Type4Me", vocabulary.getString(0))
    }

    @Test
    fun autoLanguageSendsNoLanguageCodes() {
        val transcription = JSONObject(
            GeminiProtocol.setupMessage(config(), emptyList()),
        ).getJSONObject("setup").getJSONObject("inputAudioTranscription")
        assertEquals(0, transcription.getJSONArray("languageCodes").length())
        assertFalse(transcription.has("customVocabulary"))
        assertEquals("SMART", transcription.getString("mode"))
    }

    @Test
    fun qualifiedModelNameAcceptsEitherForm() {
        assertEquals("models/gemini-3.5-transcribe", GeminiProtocol.qualifiedModelName("gemini-3.5-transcribe"))
        assertEquals(
            "models/gemini-3.5-transcribe",
            GeminiProtocol.qualifiedModelName("models/gemini-3.5-transcribe"),
        )
        assertEquals(
            "models/gemini-3.5-transcribe-live",
            GeminiProtocol.qualifiedModelName("  "),
        )
    }

    @Test
    fun audioChunksAreBase64PcmAt16k() {
        val json = JSONObject(GeminiProtocol.audioChunkMessage(byteArrayOf(1, 2)))
        val audio = json.getJSONObject("realtimeInput").getJSONObject("audio")
        assertEquals(Base64.getEncoder().encodeToString(byteArrayOf(1, 2)), audio.getString("data"))
        assertEquals("audio/pcm;rate=16000", audio.getString("mimeType"))
    }

    @Test
    fun audioIsSlicedIntoHundredMillisecondPayloads() {
        val (payloads, rest) = GeminiProtocol.sliceAudioPayloads(ByteArray(7_000))
        assertEquals(2, payloads.size)
        assertEquals(3_200, payloads[0].size)
        assertEquals(600, rest.size)

        val (none, all) = GeminiProtocol.sliceAudioPayloads(ByteArray(100))
        assertTrue(none.isEmpty())
        assertEquals(100, all.size)
    }

    @Test
    fun setupCompleteIsReportedSeparately() {
        val update = GeminiProtocol.parse("""{"setupComplete":{}}""", emptyList(), false, emptyList())
        assertNotNull(update)
        assertTrue(update!!.isSetupComplete)
    }

    @Test
    fun interimTranscriptionBecomesAPartial() {
        val update = GeminiProtocol.parse(
            """{"serverContent":{"interimInputTranscription":{"text":"hello"}}}""",
            emptyList(),
            didEndAudio = false,
            hotwords = emptyList(),
        )
        assertEquals("hello", update?.partial)
        assertFalse(update!!.isFinal)
        assertTrue(update!!.confirmedSegments.isEmpty())
    }

    @Test
    fun finalTranscriptionAppendsAConfirmedSegment() {
        val body = """{"serverContent":{"inputTranscription":{"text":"world"}}}"""

        val streaming = GeminiProtocol.parse(body, listOf("hello "), didEndAudio = false, hotwords = emptyList())
        assertEquals(listOf("hello ", "world"), streaming?.confirmedSegments)
        assertFalse(streaming!!.isFinal)

        val final = GeminiProtocol.parse(body, listOf("hello "), didEndAudio = true, hotwords = emptyList())
        assertTrue(final!!.isFinal)
        assertEquals("", final.partial)
    }

    @Test
    fun repeatedFinalSegmentIsNotAppendedTwice() {
        val update = GeminiProtocol.parse(
            """{"serverContent":{"inputTranscription":{"text":"hello"}}}""",
            listOf("hello"),
            didEndAudio = false,
            hotwords = emptyList(),
        )
        assertEquals(listOf("hello"), update?.confirmedSegments)
    }

    @Test
    fun goAwayIsSurfaced() {
        val update = GeminiProtocol.parse(
            """{"goAway":{"timeLeft":"10s"}}""",
            listOf("hello"),
            didEndAudio = false,
            hotwords = emptyList(),
        )
        assertTrue(update!!.goAway)
        assertEquals(listOf("hello"), update!!.confirmedSegments)
    }

    @Test
    fun quotaErrorsAreReported() {
        try {
            GeminiProtocol.parse(
                """{"error":{"code":429,"message":"quota","status":"RESOURCE_EXHAUSTED"}}""",
                emptyList(),
                didEndAudio = false,
                hotwords = emptyList(),
            )
            fail("expected an error")
        } catch (error: AsrException) {
            assertTrue(error.message!!.contains("quota"))
        }
    }

    @Test
    fun unrelatedFramesAreIgnored() {
        assertNull(GeminiProtocol.parse("""{"serverContent":{}}""", emptyList(), false, emptyList()))
        assertNull(GeminiProtocol.parse("not json", emptyList(), false, emptyList()))
    }
}
