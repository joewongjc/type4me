package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BailianProtocolTest {
    @Test
    fun runTaskMessageCarriesModelAndTaskId() {
        val message = JSONObject(
            BailianProtocol.buildRunTaskMessage(
                AsrConfig(providerId = "bailian", apiKey = "sk-test", extra = mapOf("languageHint" to "ZH")),
                "task-1",
            ),
        )
        assertEquals("run-task", message.getJSONObject("header").getString("action"))
        assertEquals("task-1", message.getJSONObject("header").getString("task_id"))
        assertEquals("duplex", message.getJSONObject("header").getString("streaming"))
        val payload = message.getJSONObject("payload")
        assertEquals(BailianProtocol.DEFAULT_MODEL, payload.getString("model"))
        assertEquals("recognition", payload.getString("function"))
        val parameters = payload.getJSONObject("parameters")
        assertEquals("pcm", parameters.getString("format"))
        assertEquals(16_000, parameters.getInt("sample_rate"))
        assertEquals("zh", parameters.getJSONArray("language_hints").getString(0))
    }

    @Test
    fun vocabularyIdAndFinishingMessageUseTheConfiguredTask() {
        val message = JSONObject(
            BailianProtocol.buildRunTaskMessage(
                AsrConfig(
                    providerId = "bailian",
                    apiKey = "sk-test",
                    extra = mapOf("vocabularyId" to " vocab-9 "),
                ),
                "task-2",
            ),
        )
        assertEquals("vocab-9", message.getJSONObject("payload").getJSONObject("parameters").getString("vocabulary_id"))

        val finish = JSONObject(BailianProtocol.buildFinishTaskMessage("task-2"))
        assertEquals("finish-task", finish.getJSONObject("header").getString("action"))
        assertEquals("task-2", finish.getJSONObject("header").getString("task_id"))
    }

    @Test
    fun regionSelectsTheApiSiteAndBaseUrlOverridesIt() {
        val china = BailianProtocol.settings(AsrConfig(providerId = "bailian", apiKey = "sk-test"))
        assertEquals(BailianProtocol.CHINA_ENDPOINT, china.endpoint)
        assertEquals(BailianProtocol.CHINA_HOST, hostOf(BailianProtocol.batchEndpoint(china)))

        val international = BailianProtocol.settings(
            AsrConfig(
                providerId = "bailian",
                apiKey = "sk-global",
                extra = mapOf("region" to "international"),
            ),
        )
        assertEquals(BailianProtocol.INTL_ENDPOINT, international.endpoint)
        assertEquals(BailianProtocol.INTL_HOST, hostOf(BailianProtocol.batchEndpoint(international)))

        val custom = BailianProtocol.settings(
            AsrConfig(
                providerId = "bailian",
                apiKey = "sk-test",
                baseUrl = "https://proxy.example.com/api-ws/v1/inference",
            ),
        )
        assertEquals("wss://proxy.example.com/api-ws/v1/inference", custom.endpoint)
        assertEquals("proxy.example.com", hostOf(BailianProtocol.batchEndpoint(custom)))
    }

    @Test
    fun parsesServerEvents() {
        val started = BailianProtocol.parseEvent("""{"header":{"event":"task-started","task_id":"t1"}}""")
        assertEquals(BailianProtocol.Event.Started("t1"), started)

        val sentence = BailianProtocol.parseEvent(
            """{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"text":"你好","sentence_end":true}}}}""",
        )
        assertEquals(
            BailianProtocol.Event.SentenceEvent(BailianProtocol.Sentence("你好", false, true)),
            sentence,
        )

        val failed = BailianProtocol.parseEvent(
            """{"header":{"event":"task-failed","error_code":"InvalidApiKey","error_message":"bad key"}}""",
        )
        assertEquals(BailianProtocol.Event.Failed("InvalidApiKey", "bad key"), failed)

        assertEquals(BailianProtocol.Event.Finished, BailianProtocol.parseEvent("""{"header":{"event":"task-finished"}}"""))
        assertEquals(null, BailianProtocol.parseEvent("""{"header":{"event":"unknown"}}"""))
    }

    @Test
    fun transcriptKeepsConfirmedSentencesAndReplacesThePartialOne() {
        val transcript = BailianTranscript()
        assertTrue(transcript.apply(BailianProtocol.Sentence("你好", false, true)))
        assertEquals("你好", transcript.text)

        assertTrue(transcript.apply(BailianProtocol.Sentence("世界", false, false)))
        assertEquals("你好世界", transcript.text)

        assertTrue(transcript.apply(BailianProtocol.Sentence("世界。", false, true)))
        assertEquals("你好世界。", transcript.text)

        assertFalse(transcript.apply(BailianProtocol.Sentence("", true, false)))
        assertEquals("你好世界。", transcript.text)
    }

    @Test
    fun transcriptSeparatesLatinSentencesWithASpace() {
        val transcript = BailianTranscript()
        transcript.apply(BailianProtocol.Sentence("Hello", false, true))
        transcript.apply(BailianProtocol.Sentence("world", false, true))
        assertEquals("Hello world", transcript.text)
    }

    @Test
    fun batchBodyInlinesTheRecordingAndParsesTheTranscript() {
        val body = BailianProtocol.buildBatchBody(
            AsrConfig(providerId = "bailian", apiKey = "sk-test"),
            ByteArray(8) { 1 },
        )
        assertEquals(BailianProtocol.DEFAULT_BATCH_MODEL, body.getString("model"))
        assertEquals("wav", body.getJSONObject("parameters").getString("format"))
        val content = body.getJSONObject("input")
            .getJSONArray("messages")
            .getJSONObject(0)
            .getJSONArray("content")
            .getJSONObject(0)
        assertEquals("input_audio", content.getString("type"))
        assertTrue(
            content.getJSONObject("input_audio").getString("data")
                .startsWith("data:audio/wav;base64,"),
        )

        assertEquals(
            "你好世界",
            BailianProtocol.parseBatchResponse("""{"output":{"text":" 你好世界 "}}"""),
        )
        assertEquals(
            "来自 choices",
            BailianProtocol.parseBatchResponse(
                """{"output":{"choices":[{"message":{"content":[{"text":"来自"},{"text":" choices"}]}}]}}""",
            ),
        )
        assertTrue(BailianProtocol.isNoSpeechBody("""{"code":"ASR_RESPONSE_HAVE_NO_WORDS"}"""))
        assertEquals("bad", BailianProtocol.errorDetail("""{"code":"InvalidApiKey","message":"bad"}"""))
        assertEquals("boom", BailianProtocol.errorDetail("""{"error":{"message":"boom"}}"""))
    }

    private fun hostOf(url: String): String = java.net.URI(url).host
}
