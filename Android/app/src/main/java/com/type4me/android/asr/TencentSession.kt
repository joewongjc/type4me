package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString.Companion.toByteString
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference

/**
 * Tencent Cloud realtime ASR V2 session. The signed URL carries every option; audio goes out
 * as binary frames and `{"type":"end"}` asks the server for the final transcript.
 */
class TencentSession(
    private val onPartial: (String) -> Unit,
    private val onError: (Throwable) -> Unit,
    private val endpoint: String? = null,
) : StreamingAsrSession {
    private val handshake = CompletableDeferred<Unit>()
    private val finished = CompletableDeferred<String>()
    private val error = AtomicReference<Throwable?>(null)
    private val state = TencentTranscriptState()
    // WebSocket callbacks write while finish() reads; the state itself is not thread safe.
    private val stateLock = Any()

    @Volatile
    private var sentEnd = false

    @Volatile
    private var receivedFinal = false
    private var socket: WebSocket? = null

    override suspend fun connect(config: AsrConfig, hotwords: List<String>) {
        val url = endpoint ?: TencentCloudSigner.signedWebSocketUrl(
            appId = config.extra["appId"].orEmpty().trim(),
            secretId = config.extra["secretId"].orEmpty().trim().ifBlank { config.apiKey.trim() },
            secretKey = config.extra["secretKey"].orEmpty().trim(),
            parameters = TencentProtocol.liveParameters(hotwords),
            timestamp = System.currentTimeMillis() / 1000,
            nonce = (100_000..999_999_999).random().toLong(),
            voiceId = UUID.randomUUID().toString(),
        )

        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = Unit

            override fun onMessage(webSocket: WebSocket, text: String) {
                handle(text, webSocket)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                if (sentEnd || receivedFinal) {
                    if (!finished.isCompleted) finished.complete(transcriptText())
                    return
                }
                val detail = response?.let {
                    runCatching { it.body?.string() }.getOrNull()?.take(200)
                }
                fail(
                    AsrException(
                        listOfNotNull(t.message, detail).joinToString(": ")
                            .ifBlank { "Tencent Cloud connection failed" },
                    ),
                )
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (!finished.isCompleted) finished.complete(transcriptText())
            }
        }

        socket = StreamingAsr.client.newWebSocket(Request.Builder().url(url).build(), listener)
        val ready = withTimeoutOrNull(10_000) { handshake.await() }
        if (ready == null) {
            socket?.cancel()
            socket = null
            throw AsrException("Tencent Cloud handshake timed out")
        }
    }

    override suspend fun send(pcm: ByteArray) {
        if (pcm.isEmpty()) return
        socket?.send(pcm.toByteString())
    }

    override suspend fun finish(): String {
        if (!sentEnd) {
            sentEnd = true
            socket?.send(END_MESSAGE)
        }
        val text = withTimeoutOrNull(15_000) { finished.await() } ?: transcriptText()
        socket?.cancel()
        socket = null
        val failure = error.get()
        if (text.isBlank() && failure != null) throw failure
        return text.trim()
    }

    override suspend fun cancel() {
        socket?.cancel()
        socket = null
        if (!finished.isCompleted) finished.complete("")
    }

    private fun handle(text: String, webSocket: WebSocket) {
        val parsed = TencentProtocol.decode(text) ?: return

        // The first message is the handshake verdict, not a transcript update.
        if (!handshake.isCompleted) {
            if (parsed.code != 0) {
                fail(AsrException(TencentProtocol.serverErrorText(parsed.code, parsed.message.orEmpty())))
                webSocket.close(1000, null)
            } else {
                handshake.complete(Unit)
            }
            return
        }

        if (parsed.code != 0) {
            fail(AsrException(TencentProtocol.serverErrorText(parsed.code, parsed.message.orEmpty())))
            webSocket.close(1000, null)
            return
        }

        val text = synchronized(stateLock) {
            for (update in parsed.updates) state.apply(update)
            state.text
        }
        if (parsed.updates.isNotEmpty()) onPartial(text)

        if (parsed.final) {
            receivedFinal = true
            val finalText = synchronized(stateLock) {
                state.markFinal()
                state.text
            }
            onPartial(finalText)
            if (!finished.isCompleted) finished.complete(finalText)
        }
    }

    private fun transcriptText(): String = synchronized(stateLock) { state.text }

    private fun fail(failure: Throwable) {
        error.compareAndSet(null, failure)
        onError(failure)
        if (!handshake.isCompleted) handshake.completeExceptionally(failure)
        if (!finished.isCompleted) finished.complete(transcriptText())
    }

    private companion object {
        const val END_MESSAGE = """{"type":"end"}"""
    }
}
