package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MiMoProtocolTest {
    @Test
    fun requestBodyInlinesTheWavAsADataUrl() {
        val config = AsrConfig(providerId = "mimo", apiKey = "k", extra = mapOf("language" to "zh"))
        val body = MiMoProtocol.buildBody(config, ByteArray(4) { 7 })
        assertEquals("mimo-v2.5-asr", body.getString("model"))
        assertTrue(body.getBoolean("stream"))
        assertEquals("zh", body.getJSONObject("asr_options").getString("language"))

        val content = body.getJSONArray("messages").getJSONObject(0).getJSONArray("content").getJSONObject(0)
        assertEquals("input_audio", content.getString("type"))
        assertTrue(
            content.getJSONObject("input_audio").getString("data")
                .startsWith("data:audio/wav;base64,"),
        )
    }

    @Test
    fun endpointUsesTheDefaultOrTheConfiguredBaseUrl() {
        assertEquals(MiMoProtocol.DEFAULT_ENDPOINT, MiMoProtocol.endpoint(AsrConfig(providerId = "mimo")))
        assertEquals(
            "https://proxy.example.com/v1/chat/completions",
            MiMoProtocol.endpoint(AsrConfig(providerId = "mimo", baseUrl = "https://proxy.example.com/v1")),
        )
        assertEquals(
            MiMoProtocol.DEFAULT_MODEL,
            MiMoProtocol.model(AsrConfig(providerId = "mimo")),
        )
        assertEquals(
            "auto",
            MiMoProtocol.language(AsrConfig(providerId = "mimo")),
        )
    }

    @Test
    fun sseLinesBecomeDeltasAndTerminalEvents() {
        assertEquals(
            MiMoProtocol.Event.Delta("你好"),
            MiMoProtocol.parseSseLine(
                """data: {"choices":[{"delta":{"content":"你好"},"finish_reason":null}]}""",
            ),
        )
        assertEquals(
            MiMoProtocol.Event.Done,
            MiMoProtocol.parseSseLine("""data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"""),
        )
        assertEquals(
            MiMoProtocol.Event.Failure("Recognition output exceeded the maximum token length"),
            MiMoProtocol.parseSseLine("""data: {"choices":[{"delta":{},"finish_reason":"length"}]}"""),
        )
        assertEquals(
            MiMoProtocol.Event.Failure("boom"),
            MiMoProtocol.parseSseLine("""data: {"error":{"message":"boom"}}"""),
        )
        assertNull(MiMoProtocol.parseSseLine("data: [DONE]"))
        assertNull(MiMoProtocol.parseSseLine(": keep-alive"))
        assertNull(MiMoProtocol.parseSseLine("""data: {"choices":[{"delta":{"content":""}}]}"""))
    }

    @Test
    fun malformedSsePayloadsAreRejected() {
        assertThrows(AsrException::class.java) {
            MiMoProtocol.parseSseLine("data: not json")
        }
    }

    @Test
    fun errorMessagePrefersTheServerDetail() {
        assertEquals("boom", MiMoProtocol.extractErrorMessage("""{"error":{"message":"boom"}}"""))
        assertEquals("nope", MiMoProtocol.extractErrorMessage("""{"message":"nope"}"""))
        assertEquals("plain text", MiMoProtocol.extractErrorMessage("plain text"))
    }

    @Test
    fun oversizedAudioIsRefusedBeforeUpload() {
        val wav = ByteArray(8 * 1024 * 1024)
        val failure = assertThrows(AsrException::class.java) {
            MiMoProtocol.buildBody(AsrConfig(providerId = "mimo", apiKey = "k"), wav)
        }
        assertTrue(failure.message!!.contains("audio limit"))
    }

    @Test
    fun bodyIsJsonSerializable() {
        val body = MiMoProtocol.buildBody(AsrConfig(providerId = "mimo", apiKey = "k"), ByteArray(2))
        assertTrue(JSONObject(body.toString()).has("messages"))
    }
}
