package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class StepFunProtocolTest {
    @Test
    fun sessionUpdateCarriesFormatModelAndHotwords() {
        val json = JSONObject(
            StepFunProtocol.buildSessionUpdateMessage(
                AsrConfig(apiKey = "secret"),
                listOf("Type4Me", "阶跃", "type4me", " "),
            ),
        )
        assertEquals("session.update", json.getString("type"))
        val input = json.getJSONObject("session").getJSONObject("audio").getJSONObject("input")
        val format = input.getJSONObject("format")
        assertEquals("pcm_s16le", format.getString("codec"))
        assertEquals(16_000, format.getInt("rate"))
        assertEquals(1, format.getInt("channel"))

        val transcription = input.getJSONObject("transcription")
        assertEquals("stepaudio-2.5-asr-stream", transcription.getString("model"))
        assertEquals("zh", transcription.getString("language"))
        assertTrue(transcription.getBoolean("full_rerun_on_commit"))
        val prompt = transcription.getString("prompt")
        assertTrue(prompt.startsWith("专业术语："))
        assertTrue(prompt.contains("Type4Me"))
        assertTrue(prompt.contains("阶跃"))
        // The duplicate term is dropped, so "Type4Me" appears once.
        assertEquals(1, Regex("Type4Me").findAll(prompt).count())
    }

    @Test
    fun sessionUpdateOmitsThePromptWithoutHotwords() {
        val json = JSONObject(StepFunProtocol.buildSessionUpdateMessage(AsrConfig(), emptyList()))
        val transcription = json.getJSONObject("session")
            .getJSONObject("audio")
            .getJSONObject("input")
            .getJSONObject("transcription")
        assertFalse(transcription.has("prompt"))
    }

    @Test
    fun endpointFollowsTheRegionUnlessOverridden() {
        assertEquals(StepFunProtocol.CHINA_ENDPOINT, StepFunProtocol.endpoint(AsrConfig()))
        assertEquals(
            StepFunProtocol.CHINA_ENDPOINT,
            StepFunProtocol.endpoint(AsrConfig(extra = mapOf("region" to "china"))),
        )
        assertEquals(
            StepFunProtocol.GLOBAL_ENDPOINT,
            StepFunProtocol.endpoint(AsrConfig(extra = mapOf("region" to "global"))),
        )
        // A preset stores the China URL, but switching the region still moves it.
        assertEquals(
            StepFunProtocol.GLOBAL_ENDPOINT,
            StepFunProtocol.endpoint(
                AsrConfig(
                    baseUrl = StepFunProtocol.CHINA_ENDPOINT,
                    extra = mapOf("region" to "global"),
                ),
            ),
        )
        assertEquals(
            "wss://proxy.test/realtime",
            StepFunProtocol.endpoint(AsrConfig(baseUrl = "wss://proxy.test/realtime")),
        )
    }

    @Test
    fun appendMessageCarriesBase64Pcm() {
        val pcm = byteArrayOf(1, 2, 3, 4)
        val json = JSONObject(StepFunProtocol.buildAppendAudioMessage(pcm))
        assertEquals("input_audio_buffer.append", json.getString("type"))
        assertArrayEquals(pcm, Base64.getDecoder().decode(json.getString("audio")))
        assertEquals("input_audio_buffer.commit", JSONObject(StepFunProtocol.buildCommitMessage()).getString("type"))
    }

    @Test
    fun parsesDeltaCompletedAndError() {
        val delta = StepFunProtocol.parse(
            """{"type":"conversation.item.input_audio_transcription.delta","text":"你好","stash":"世界"}""",
        ) as StepFunProtocol.Event.Transcript
        assertEquals("你好世界", delta.text)
        assertFalse(delta.final)

        val completed = StepFunProtocol.parse(
            """{"type":"conversation.item.input_audio_transcription.completed","transcript":" 你好，世界。 "}""",
        ) as StepFunProtocol.Event.Transcript
        assertEquals("你好，世界。", completed.text)
        assertTrue(completed.final)

        val failure = StepFunProtocol.parse(
            """{"type":"error","error":{"code":"1001","message":"bad key"}}""",
        ) as StepFunProtocol.Event.Failure
        assertTrue(failure.message.contains("1001"))
        assertTrue(failure.message.contains("bad key"))

        assertEquals(StepFunProtocol.Event.SessionReady, StepFunProtocol.parse("""{"type":"session.updated"}"""))
        assertNull(StepFunProtocol.parse("""{"type":"session.created"}"""))
        assertNull(
            StepFunProtocol.parse("""{"type":"conversation.item.input_audio_transcription.delta","text":"","stash":""}"""),
        )
    }
}
