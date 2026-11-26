package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import kotlinx.coroutines.runBlocking
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.ByteString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference

class TencentSessionTest {
    @Test
    fun sendsAudioAsFramesAndEndsWithTheFinalSentence() {
        val partials = CopyOnWriteArrayList<String>()
        val failure = AtomicReference<Throwable?>(null)
        val audioFrames = AtomicReference(0)
        val server = MockWebServer()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    webSocket.send("""{"code":0,"message":"success","voice_id":"v1"}""")
                }

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    audioFrames.set(audioFrames.get() + 1)
                    webSocket.send(
                        """{"code":0,"message":"success","final":0,""" +
                            """"result":{"slice_type":1,"index":0,"voice_text_str":"完成"}}""",
                    )
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (text != """{"type":"end"}""") return
                    webSocket.send(
                        """{"code":0,"message":"success","final":1,""" +
                            """"result":{"slice_type":2,"index":0,"voice_text_str":"完成。"}}""",
                    )
                }
            }),
        )
        server.start()
        try {
            val session = TencentSession(
                onPartial = { partials += it },
                onError = { failure.set(it) },
                endpoint = server.url("/asr/v2/1250000000").toString(),
            )
            val text = runBlocking {
                session.connect(AsrConfig(providerId = "tencent", apiKey = "k", extra = appCredentials()), emptyList())
                session.send(ByteArray(3_200))
                session.send(ByteArray(3_200))
                session.finish()
            }
            assertEquals("完成。", text)
            assertEquals(2, audioFrames.get())
            assertTrue(partials.contains("完成"))
            assertNull(failure.get())
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun handshakeRejectionSurfacesThroughOnError() {
        val failure = AtomicReference<Throwable?>(null)
        val server = MockWebServer()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    webSocket.send("""{"code":4002,"message":"invalid secretid or secretkey"}""")
                    webSocket.close(1000, null)
                }
            }),
        )
        server.start()
        try {
            val session = TencentSession(
                onPartial = {},
                onError = { failure.set(it) },
                endpoint = server.url("/asr/v2/1250000000").toString(),
            )
            runBlocking {
                val thrown = runCatching {
                    session.connect(
                        AsrConfig(providerId = "tencent", apiKey = "k", extra = appCredentials()),
                        emptyList(),
                    )
                }.exceptionOrNull()
                assertTrue(thrown is AsrException)
                assertTrue(thrown!!.message!!.contains("4002"))
                session.cancel()
            }
            assertTrue(failure.get() is AsrException)
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun missingCredentialsAreRejectedBeforeConnecting() {
        val session = TencentSession(onPartial = {}, onError = {})
        runBlocking {
            val thrown = runCatching {
                session.connect(AsrConfig(providerId = "tencent"), emptyList())
            }.exceptionOrNull()
            assertTrue(thrown is AsrException)
            assertTrue(thrown!!.message!!.contains("SecretId"))
        }
    }

    private fun appCredentials(): Map<String, String> = mapOf(
        "appId" to "1250000000",
        "secretId" to "AKIDEXAMPLE",
        "secretKey" to "secret",
    )
}
