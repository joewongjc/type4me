package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AzureProtocolTest {
    @Test
    fun resourceNameMapsToFoundryAndSpeechHosts() {
        val bare = AzureProtocol.settings(AsrConfig(providerId = "azure", apiKey = "k", baseUrl = "my-resource"))
        assertEquals("my-resource.services.ai.azure.com", bare.foundryHost)
        assertEquals("my-resource.cognitiveservices.azure.com", bare.speechHost)

        val url = AzureProtocol.settings(
            AsrConfig(
                providerId = "azure",
                apiKey = "k",
                extra = mapOf("resource" to "https://my-resource.services.ai.azure.com/"),
            ),
        )
        assertEquals("my-resource.services.ai.azure.com", url.foundryHost)
        assertEquals("my-resource.cognitiveservices.azure.com", url.speechHost)

        val custom = AzureProtocol.settings(
            AsrConfig(providerId = "azure", apiKey = "k", baseUrl = "asr.example.com"),
        )
        assertEquals("asr.example.com", custom.foundryHost)
        assertEquals("asr.example.com", custom.speechHost)

        val missing = AzureProtocol.settings(AsrConfig(providerId = "azure", apiKey = "k"))
        assertEquals(null, missing.foundryHost)
        assertEquals(null, missing.speechHost)
    }

    @Test
    fun realtimeUrlAndSessionUpdateDescribeTheDeployment() {
        val settings = AzureProtocol.settings(
            AsrConfig(
                providerId = "azure",
                apiKey = "k",
                baseUrl = "my-resource",
                extra = mapOf("language" to "zh"),
            ),
        )
        assertEquals(
            "wss://my-resource.services.ai.azure.com/mai/v1/realtime?intent=transcription",
            AzureProtocol.realtimeUrl(settings),
        )

        val update = JSONObject(AzureProtocol.sessionUpdateMessage(settings))
        assertEquals("session.update", update.getString("type"))
        val session = update.getJSONObject("session")
        assertEquals("transcription", session.getString("type"))
        val input = session.getJSONObject("audio").getJSONObject("input")
        assertEquals("audio/pcm", input.getJSONObject("format").getString("type"))
        assertEquals(16_000, input.getJSONObject("format").getInt("rate"))
        assertEquals("zh", input.getJSONObject("transcription").getString("language"))
        assertEquals(AzureProtocol.DEFAULT_DEPLOYMENT, input.getJSONObject("transcription").getString("model"))
        assertTrue(input.isNull("turn_detection"))
        assertTrue(input.isNull("noise_reduction"))
    }

    @Test
    fun emptyLanguageIsSentAsNull() {
        val settings = AzureProtocol.settings(AsrConfig(providerId = "azure", apiKey = "k", baseUrl = "my-resource"))
        val update = JSONObject(AzureProtocol.sessionUpdateMessage(settings))
        assertTrue(
            update.getJSONObject("session")
                .getJSONObject("audio")
                .getJSONObject("input")
                .getJSONObject("transcription")
                .isNull("language"),
        )
    }

    @Test
    fun parsesRealtimeEvents() {
        assertEquals(AzureProtocol.Event.Created, AzureProtocol.parseEvent("""{"type":"session.created"}"""))
        assertEquals(AzureProtocol.Event.Updated, AzureProtocol.parseEvent("""{"type":"session.updated"}"""))
        assertEquals(AzureProtocol.Event.Committed, AzureProtocol.parseEvent("""{"type":"input_audio_buffer.committed"}"""))
        assertEquals(
            AzureProtocol.Event.Delta("你好"),
            AzureProtocol.parseEvent(
                """{"type":"conversation.item.input_audio_transcription.delta","delta":"你好"}""",
            ),
        )
        assertEquals(
            AzureProtocol.Event.Intermediate("世界"),
            AzureProtocol.parseEvent(
                """{"type":"conversation.item.input_audio_transcription.intermediate","intermediate":"世界"}""",
            ),
        )
        assertEquals(
            AzureProtocol.Event.Completed("你好世界"),
            AzureProtocol.parseEvent(
                """{"type":"conversation.item.input_audio_transcription.completed","transcript":"你好世界"}""",
            ),
        )
        assertEquals(AzureProtocol.Event.Ignored, AzureProtocol.parseEvent("""{"type":"unknown"}"""))
    }

    @Test
    fun serverErrorsBecomeExceptions() {
        val failure = assertThrows(AsrException::class.java) {
            AzureProtocol.parseEvent(
                """{"type":"error","error":{"code":"invalid_request","message":"bad deployment"}}""",
            )
        }
        assertTrue(failure.message!!.contains("bad deployment"))
        assertTrue(failure.message!!.contains("invalid_request"))
    }

    @Test
    fun batchDefinitionCarriesStyleLocalesAndPhrases() {
        val settings = AzureProtocol.settings(
            AsrConfig(
                providerId = "azure",
                apiKey = "k",
                baseUrl = "my-resource",
                extra = mapOf("transcribeStyle" to "verbatim", "language" to "en"),
            ),
        )
        assertEquals(
            "https://my-resource.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe" +
                "?api-version=2025-10-15",
            AzureProtocol.batchUrl(settings),
        )

        val definition = AzureProtocol.batchDefinition(
            settings,
            listOf("Type4Me", " Type4Me ", "a term that is far too long to fit inside fifty characters for sure", ""),
        )
        val enhanced = definition.getJSONObject("enhancedMode")
        assertEquals(true, enhanced.getBoolean("enabled"))
        assertEquals("MAI-Transcribe-2", enhanced.getString("model"))
        assertEquals("verbatim", enhanced.getJSONObject("modelOptions").getString("transcribeStyle"))
        assertEquals("en", definition.getJSONArray("locales").getString(0))
        val phrases = definition.getJSONObject("phraseList").getJSONArray("phrases")
        assertEquals(1, phrases.length())
        assertEquals("Type4Me", phrases.getString(0))
    }

    @Test
    fun batchResponseJoinsTheCombinedPhrases() {
        assertEquals(
            "你好世界",
            AzureProtocol.parseBatchResponse(
                """{"combinedPhrases":[{"text":"你好"},{"text":"世界"}]}""",
            ),
        )
        assertEquals(
            "hello world",
            AzureProtocol.parseBatchResponse(
                """{"combinedPhrases":[{"text":"hello"},{"text":"world"}]}""",
            ),
        )
        assertThrows(AsrException::class.java) {
            AzureProtocol.parseBatchResponse("""{"unexpected":true}""")
        }
    }
}
