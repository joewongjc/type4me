package com.type4me.android.llm

import com.type4me.android.data.LlmConfig
import com.type4me.android.pipeline.Prompts
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class ChatClientThinkingTest {

    @Test
    fun `deepseek request turns thinking off`() = runBlocking {
        val server = MockWebServer()
        server.enqueue(json("""{"choices":[{"message":{"content":"OK"}}]}"""))
        try {
            ChatClient().complete(
                config = config(server, "deepseek", "deepseek-chat", disableThinking = true),
                request = Prompts.Request(system = null, user = "Hi"),
            )
            val body = JSONObject(server.takeRequest().body.readUtf8())
            assertEquals("disabled", body.getJSONObject("thinking").getString("type"))
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun `switching thinking off omits the field`() = runBlocking {
        val server = MockWebServer()
        server.enqueue(json("""{"choices":[{"message":{"content":"OK"}}]}"""))
        try {
            ChatClient().complete(
                config = config(server, "deepseek", "deepseek-chat", disableThinking = false),
                request = Prompts.Request(system = null, user = "Hi"),
            )
            val body = JSONObject(server.takeRequest().body.readUtf8())
            assertFalse(body.has("thinking"))
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun `openai reasoning models use effort none`() = runBlocking {
        val server = MockWebServer()
        server.enqueue(json("""{"choices":[{"message":{"content":"OK"}}]}"""))
        try {
            ChatClient().complete(
                config = config(server, "openai", "gpt-5.5", disableThinking = true),
                request = Prompts.Request(system = null, user = "Hi"),
            )
            val body = JSONObject(server.takeRequest().body.readUtf8())
            assertEquals("none", body.getString("reasoning_effort"))
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun `claude messages use the model specific thinking type`() = runBlocking {
        val server = MockWebServer()
        server.enqueue(json("""{"content":[{"type":"text","text":"OK"}]}"""))
        try {
            ChatClient().complete(
                config = config(server, "claude", "claude-sonnet-5-5", disableThinking = true),
                request = Prompts.Request(system = null, user = "Hi"),
            )
            val body = JSONObject(server.takeRequest().body.readUtf8())
            assertEquals("between_tools", body.getJSONObject("thinking").getString("type"))
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun `openai reasoning models use max completion tokens`() = runBlocking {
        val server = MockWebServer()
        server.enqueue(json("""{"choices":[{"message":{"content":"OK"}}]}"""))
        try {
            ChatClient().complete(
                config = config(server, "openai", "gpt-5.5", disableThinking = true),
                request = Prompts.Request(system = null, user = "Hi"),
            )
            val body = JSONObject(server.takeRequest().body.readUtf8())
            assertEquals(2_400, body.getInt("max_completion_tokens"))
            assertFalse(body.has("max_tokens"))
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun `compatible openai models keep max tokens`() = runBlocking {
        val server = MockWebServer()
        server.enqueue(json("""{"choices":[{"message":{"content":"OK"}}]}"""))
        try {
            ChatClient().complete(
                config = config(server, "openai", "gpt-4o-mini", disableThinking = false),
                request = Prompts.Request(system = null, user = "Hi"),
            )
            val body = JSONObject(server.takeRequest().body.readUtf8())
            assertEquals(2_400, body.getInt("max_tokens"))
            assertFalse(body.has("max_completion_tokens"))
        } finally {
            server.shutdown()
        }
    }

    private fun config(
        server: MockWebServer,
        providerId: String,
        model: String,
        disableThinking: Boolean,
    ) = LlmConfig(
        baseUrl = server.url("/v1").toString().trimEnd('/'),
        model = model,
        apiKey = "test",
        providerId = providerId,
        disableThinking = disableThinking,
    )

    private fun json(body: String) = MockResponse()
        .setHeader("Content-Type", "application/json")
        .setBody(body)
}
