package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import kotlinx.coroutines.runBlocking
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference

class BailianSessionTest {
    @Test
    fun streamsPartialSentencesAndFinishesOnTaskFinished() {
        val partials = CopyOnWriteArrayList<String>()
        val failure = AtomicReference<Throwable?>(null)
        val server = MockWebServer()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) = Unit

                override fun onMessage(webSocket: WebSocket, text: String) {
                    val header = JSONObject(text).getJSONObject("header")
                    when (header.getString("action")) {
                        "run-task" -> {
                            webSocket.send("""{"header":{"event":"task-started","task_id":"t1"}}""")
                            webSocket.send(sentenceEvent("你好", sentenceEnd = false))
                        }

                        "finish-task" -> {
                            webSocket.send(sentenceEvent("你好，世界", sentenceEnd = true))
                            webSocket.send("""{"header":{"event":"task-finished","task_id":"t1"}}""")
                        }
                    }
                }
            }),
        )
        server.start()
        try {
            val session = BailianSession(
                onPartial = { partials += it },
                onError = { failure.set(it) },
                endpoint = server.url("/inference").toString(),
            )
            val text = runBlocking {
                session.connect(AsrConfig(providerId = "bailian", apiKey = "sk-test"), emptyList())
                session.send(ByteArray(3_200))
                session.finish()
            }
            assertEquals("你好，世界", text)
            assertTrue(partials.contains("你好"))
            assertNull(failure.get())
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun taskFailureSurfacesThroughOnErrorAndFinish() {
        val failure = AtomicReference<Throwable?>(null)
        val server = MockWebServer()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) = Unit

                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (JSONObject(text).getJSONObject("header").getString("action") != "run-task") return
                    webSocket.send(
                        """{"header":{"event":"task-failed","error_code":"InvalidApiKey","error_message":"bad key"}}""",
                    )
                    webSocket.close(1000, null)
                }
            }),
        )
        server.start()
        try {
            val session = BailianSession(onPartial = {}, onError = { failure.set(it) })
            runBlocking {
                val thrown = runCatching {
                    session.connect(
                        AsrConfig(
                            providerId = "bailian",
                            apiKey = "sk-test",
                            baseUrl = server.url("/inference").toString(),
                        ),
                        emptyList(),
                    )
                }.exceptionOrNull()
                assertTrue(thrown is AsrException)
                assertTrue(thrown!!.message!!.contains("bad key"))
                session.cancel()
            }
            assertTrue(failure.get() is AsrException)
        } finally {
            server.shutdown()
        }
    }

    private fun sentenceEvent(text: String, sentenceEnd: Boolean): String =
        """{"header":{"event":"result-generated"},"payload":{"output":{"sentence":""" +
            """{"text":"$text","sentence_end":$sentenceEnd}}}}"""
}
