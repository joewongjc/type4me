package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import com.type4me.android.data.AsrKind
import kotlinx.coroutines.runBlocking
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference

class SonioxSessionTest {
    @Test
    fun streamsPartialTextAndFinishesOnTheEndFrame() {
        val partials = CopyOnWriteArrayList<String>()
        val failure = AtomicReference<Throwable?>(null)
        val server = MockWebServer()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) = Unit

                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (text.contains("api_key")) {
                        webSocket.send(
                            """{"tokens":[{"text":"你好","is_final":false}]}""",
                        )
                    } else if (text.isEmpty()) {
                        webSocket.send(
                            """{"tokens":[{"text":"你好","is_final":true}],"finished":true}""",
                        )
                    }
                }

                override fun onMessage(webSocket: WebSocket, bytes: okio.ByteString) = Unit
            }),
        )
        server.start()
        try {
            val endpoint = server.url("/").toString()
            val session = SonioxSession(
                onPartial = { partials += it },
                onError = { failure.set(it) },
                endpoint = endpoint,
            )
            val finalText = runBlocking {
                session.connect(
                    AsrConfig(kind = AsrKind.SONIOX, model = "stt-rt-v5", apiKey = "secret"),
                    listOf("Type4Me"),
                )
                session.send(ByteArray(3_200))
                session.finish()
            }
            assertEquals("你好", finalText)
            assertTrue(partials.any { it == "你好" })
            assertEquals(null, failure.get())
        } finally {
            server.shutdown()
        }
    }
}
