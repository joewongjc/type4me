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

class AzureSessionTest {
    @Test
    fun appendsAudioThenCommitsAndReturnsTheCompletedTranscript() {
        val partials = CopyOnWriteArrayList<String>()
        val failure = AtomicReference<Throwable?>(null)
        val server = MockWebServer()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) = Unit

                override fun onMessage(webSocket: WebSocket, text: String) {
                    when (JSONObject(text).getString("type")) {
                        "session.update" -> {
                            webSocket.send("""{"type":"session.created"}""")
                            webSocket.send("""{"type":"session.updated"}""")
                        }

                        "input_audio_buffer.append" -> {
                            webSocket.send(
                                """{"type":"conversation.item.input_audio_transcription.delta","delta":"你好"}""",
                            )
                            webSocket.send(
                                """{"type":"conversation.item.input_audio_transcription.intermediate","intermediate":"世界"}""",
                            )
                        }

                        "input_audio_buffer.commit" -> {
                            webSocket.send("""{"type":"input_audio_buffer.committed"}""")
                            webSocket.send(
                                """{"type":"conversation.item.input_audio_transcription.completed","transcript":"你好，世界。"}""",
                            )
                        }
                    }
                }
            }),
        )
        server.start()
        try {
            val session = AzureSession(
                onPartial = { partials += it },
                onError = { failure.set(it) },
                endpoint = server.url("/mai/v1/realtime").toString(),
            )
            val text = runBlocking {
                session.connect(AsrConfig(providerId = "azure", apiKey = "k", baseUrl = "my-resource"), emptyList())
                session.send(ByteArray(3_200))
                session.finish()
            }
            assertEquals("你好，世界。", text)
            assertTrue(partials.contains("你好世界"))
            assertNull(failure.get())
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun shortRecordingsSkipTheCommit() {
        val server = MockWebServer()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) = Unit

                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (JSONObject(text).getString("type") != "session.update") return
                    webSocket.send("""{"type":"session.updated"}""")
                }
            }),
        )
        server.start()
        try {
            val session = AzureSession(
                onPartial = {},
                onError = {},
                endpoint = server.url("/mai/v1/realtime").toString(),
            )
            val text = runBlocking {
                session.connect(AsrConfig(providerId = "azure", apiKey = "k", baseUrl = "my-resource"), emptyList())
                session.send(ByteArray(1_600))
                session.finish()
            }
            assertEquals("", text)
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun rejectedHandshakeReportsTheHttpStatus() {
        val failure = AtomicReference<Throwable?>(null)
        val server = MockWebServer()
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":{"message":"bad key"}}"""))
        server.start()
        try {
            val session = AzureSession(
                onPartial = {},
                onError = { failure.set(it) },
                endpoint = server.url("/mai/v1/realtime").toString(),
            )
            runBlocking {
                val thrown = runCatching {
                    session.connect(AsrConfig(providerId = "azure", apiKey = "k", baseUrl = "my-resource"), emptyList())
                }.exceptionOrNull()
                assertTrue(thrown is AsrException)
                assertTrue(thrown!!.message!!.contains("401"))
            }
            assertTrue(failure.get() is AsrException)
        } finally {
            server.shutdown()
        }
    }
}
