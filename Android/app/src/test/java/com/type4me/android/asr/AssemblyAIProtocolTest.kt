package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AssemblyAIProtocolTest {
    @Test
    fun buildsUrlWithSampleRateAndModel() {
        val url = AssemblyAIProtocol.buildUrl(AsrConfig())
        assertTrue(url.startsWith("wss://streaming.assemblyai.com/v3/ws?"))
        assertTrue(url.contains("sample_rate=16000"))
        assertTrue(url.contains("encoding=pcm_s16le"))
        assertTrue(url.contains("speech_model=universal-3-6-pro"))
        assertFalse(url.contains("format_turns"))
    }

    @Test
    fun universalStreamingModelsGetFormatTurns() {
        val enabled = AssemblyAIProtocol.buildUrl(AsrConfig(model = "universal-streaming-english"))
        assertTrue(enabled.contains("format_turns=true"))

        val disabled = AssemblyAIProtocol.buildUrl(
            AsrConfig(model = "universal-streaming-english"),
            enablePunc = false,
        )
        assertTrue(disabled.contains("format_turns=false"))
    }

    @Test
    fun updateConfigurationCarriesTruncatedKeyterms() {
        val longTerm = "x".repeat(80)
        val message = AssemblyAIProtocol.updateConfigurationMessage(listOf("Type4Me", "  ", longTerm))!!
        val json = JSONObject(message)
        assertEquals("UpdateConfiguration", json.getString("type"))
        val keyterms = json.getJSONArray("keyterms_prompt")
        assertEquals(2, keyterms.length())
        assertEquals("Type4Me", keyterms.getString(0))
        assertEquals(50, keyterms.getString(1).length)
        assertNull(AssemblyAIProtocol.updateConfigurationMessage(emptyList()))
    }

    @Test
    fun parsesBeginAndTurnMessages() {
        assertEquals(AssemblyAIProtocol.Event.Begin, AssemblyAIProtocol.parse("""{"type":"Begin","id":"abc"}"""))
        assertEquals(
            AssemblyAIProtocol.Event.Termination,
            AssemblyAIProtocol.parse("""{"type":"Termination","audio_duration_seconds":1.5}"""),
        )
        assertNull(AssemblyAIProtocol.parse("""{"type":"KeepAlive"}"""))

        val partial = AssemblyAIProtocol.parse(
            """
            {
              "type": "Turn",
              "turn_order": 0,
              "turn_is_formatted": false,
              "end_of_turn": false,
              "transcript": "hel",
              "words": [{"text": "hello", "word_is_final": false}]
            }
            """.trimIndent(),
        ) as AssemblyAIProtocol.Event.Turn
        assertFalse(partial.update.isFinal)
        assertEquals("hello", partial.update.displayText)
        assertEquals("", partial.update.finalizedText)
        assertEquals(0, partial.update.turnOrder)

        val complete = AssemblyAIProtocol.parse(
            """{"type":"Turn","turn_order":0,"turn_is_formatted":true,"end_of_turn":true,"transcript":"Hello there."}""",
        ) as AssemblyAIProtocol.Event.Turn
        assertTrue(complete.update.isFinal)
        assertEquals("Hello there.", complete.update.displayText)
        assertEquals("Hello there.", complete.update.authoritativeText)
    }

    @Test
    fun finalizedWordsBecomeTheStablePrefixOfAnOpenTurn() {
        val event = AssemblyAIProtocol.parse(
            """
            {
              "type": "Turn",
              "turn_order": 2,
              "turn_is_formatted": false,
              "end_of_turn": false,
              "transcript": "",
              "words": [
                {"text": "hello", "word_is_final": true},
                {"text": "world", "word_is_final": false}
              ]
            }
            """.trimIndent(),
        ) as AssemblyAIProtocol.Event.Turn
        assertEquals("hello", event.update.finalizedText)
        assertEquals("hello world", event.update.displayText)
        assertEquals("hello", event.update.authoritativeText)
    }

    @Test
    fun accumulatorCombinesCompletedTurnsWithTheActiveTurn() {
        val accumulator = AssemblyAITranscriptAccumulator()

        accumulator.apply(
            AssemblyAIProtocol.TurnUpdate(
                turnOrder = 0,
                finalizedText = "",
                displayText = "Hello",
                authoritativeText = "Hello",
                isFinal = false,
                isFormatted = false,
            ),
        )
        var transcript = accumulator.transcript()
        assertEquals(listOf<String>(), transcript.confirmedSegments)
        assertEquals("Hello", transcript.partial)
        assertFalse(transcript.final)

        accumulator.apply(
            AssemblyAIProtocol.TurnUpdate(
                turnOrder = 0,
                finalizedText = "Hello.",
                displayText = "Hello.",
                authoritativeText = "Hello.",
                isFinal = true,
                isFormatted = true,
            ),
        )
        accumulator.apply(
            AssemblyAIProtocol.TurnUpdate(
                turnOrder = 1,
                finalizedText = "",
                displayText = "World",
                authoritativeText = "World",
                isFinal = false,
                isFormatted = false,
            ),
        )
        transcript = accumulator.transcript()
        assertEquals(listOf("Hello."), transcript.confirmedSegments)
        // Chunks carry their own separator, so the partial keeps the space.
        assertEquals(" World", transcript.partial)
        assertEquals("Hello. World", transcript.authoritativeText)
        assertFalse(transcript.final)

        // A late partial revision of the completed turn must not rewrite it.
        accumulator.apply(
            AssemblyAIProtocol.TurnUpdate(
                turnOrder = 0,
                finalizedText = "",
                displayText = "Hello?",
                authoritativeText = "Hello?",
                isFinal = false,
                isFormatted = false,
            ),
        )
        assertEquals(listOf("Hello."), accumulator.transcript().confirmedSegments)
    }

    @Test
    fun accumulatorReportsFinalWithoutAnActiveTurn() {
        val accumulator = AssemblyAITranscriptAccumulator()
        accumulator.apply(
            AssemblyAIProtocol.TurnUpdate(
                turnOrder = 0,
                finalizedText = "你好。",
                displayText = "你好。",
                authoritativeText = "你好。",
                isFinal = true,
                isFormatted = true,
            ),
        )
        val transcript = accumulator.transcript()
        assertTrue(transcript.final)
        assertEquals("你好。", transcript.authoritativeText)
    }

    @Test
    fun closeCodesMapToReadableFailures() {
        assertTrue(AssemblyAIProtocol.closeErrorMessage(1008, "bad key").contains("unauthorized"))
        assertTrue(AssemblyAIProtocol.closeErrorMessage(3005, "").contains("cancelled"))
        assertTrue(AssemblyAIProtocol.closeErrorMessage(1000, "bye").contains("1000"))
    }
}
