package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import com.type4me.android.data.AsrKind
import com.type4me.android.data.Presets
import kotlinx.coroutines.runBlocking
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference

class VolcSessionTest {
    @Test
    fun streamsPartialTextAndFinishesOnTheLastPacket() {
        val partials = CopyOnWriteArrayList<String>()
        val failure = AtomicReference<Throwable?>(null)
        val server = MockWebServer()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) = Unit

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    val data = bytes.toByteArray()
                    val header = VolcProtocol.decodeHeader(data)
                    when {
                        header.messageType == 1 ->
                            webSocket.send(serverFrame("你好", final = false).toByteString())

                        header.flags == 2 ->
                            webSocket.send(serverFrame("你好，世界。", final = true).toByteString())
                    }
                }

                override fun onMessage(webSocket: WebSocket, text: String) = Unit
            }),
        )
        server.start()
        try {
            val endpoint = server.url("/").toString()
            val session = VolcSession(
                onPartial = { partials += it },
                onError = { failure.set(it) },
                endpoint = endpoint,
            )
            val finalText = runBlocking {
                session.connect(
                    AsrConfig(
                        kind = AsrKind.VOLCANO,
                        apiKey = "secret",
                        resourceId = Presets.VOLC_RESOURCE_SEED,
                    ),
                    emptyList(),
                )
                session.send(ByteArray(3_200))
                session.finish()
            }
            assertEquals("你好，世界。", finalText)
            assertTrue(partials.any { it == "你好" })
            assertEquals(null, failure.get())
        } finally {
            server.shutdown()
        }
    }

    private fun serverFrame(text: String, final: Boolean): ByteArray {
        val payload = """{"result":{"text":"$text"}}""".toByteArray()
        val message = ByteArray(8 + payload.size)
        message[0] = 0x11
        message[1] = ((9 shl 4) or (if (final) 4 else 0)).toByte()
        message[2] = 0x10
        message[3] = 0
        message[4] = (payload.size ushr 24).toByte()
        message[5] = (payload.size ushr 16).toByte()
        message[6] = (payload.size ushr 8).toByte()
        message[7] = payload.size.toByte()
        payload.copyInto(message, 8)
        return message
    }
}
