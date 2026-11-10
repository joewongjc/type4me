package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString.Companion.toByteString
import java.util.concurrent.atomic.AtomicReference

/**
 * Deepgram realtime listen. Interim results update the partial line, final
 * results append to the confirmed transcript, and the tail is flushed by
 * CloseStream when the caller finishes.
 */
class DeepgramSession(
    private val onPartial: (String) -> Unit,
    private val onError: (Throwable) -> Unit,
) : StreamingAsrSession {
    private val opened = CompletableDeferred<Unit>()
    private val finished = CompletableDeferred<String>()
    private val error = AtomicReference<Throwable?>(null)
    private val lock = Any()
    private var confirmed: List<String> = emptyList()
    private var lastText = ""
    @Volatile private var sentEnd = false
    private var socket: WebSocket? = null

    override suspend fun connect(config: AsrConfig, hotwords: List<String>) {
        val url = DeepgramProtocol.buildUrl(config, hotwords)
        val key = config.apiKey.trim()
        val request = Request.Builder()
            .url(url)
            .apply {
                if (DeepgramProtocol.usesStandardAuthorization(url)) {
                    header("Authorization", "Token $key")
                } else {
                    header("X-API-Key", key)
                }
            }
            .build()

        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                if (!opened.isCompleted) opened.complete(Unit)
            }

            override fun onMessage(webSocket: WebSocket, text: String) = handle(text)

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                if (sentEnd) {
                    complete(currentText())
                    return
                }
                val detail = response?.let {
                    runCatching { it.body?.string() }.getOrNull()?.take(200)
                }
                val failure = AsrException(
                    listOfNotNull(t.message, detail).joinToString(": ")
                        .ifBlank { "Deepgram connection failed" },
                )
                report(failure)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (!opened.isCompleted) {
                    fail(
                        AsrException(
                            "Deepgram closed before the handshake completed ($code)" +
                                if (reason.isBlank()) "" else ": $reason",
                        ),
                    )
                    return
                }
                // A close before CloseStream lost the recording's tail; report it instead
                // of returning a silently truncated transcript.
                if (!sentEnd) {
                    if (error.get() == null) {
                        report(
                            AsrException(
                                "Deepgram closed before the recording finished ($code)" +
                                    if (reason.isBlank()) "" else ": $reason",
                            ),
                        )
                    } else {
                        complete(currentText())
                    }
                    return
                }
                complete(currentText())
            }
        }

        socket = StreamingAsr.client.newWebSocket(request, listener)
        withTimeout(10_000) { opened.await() }
    }

    override suspend fun send(pcm: ByteArray) {
        if (pcm.isEmpty()) return
        socket?.send(pcm.toByteString())
    }

    override suspend fun finish(): String {
        if (!sentEnd) {
            sentEnd = true
            socket?.send(DeepgramProtocol.closeStreamMessage())
        }
        val text = withTimeoutOrNull(15_000) { finished.await() } ?: currentText()
        socket?.cancel()
        socket = null
        val failure = error.get()
        if (text.isBlank() && failure != null) throw failure
        return text
    }

    override suspend fun cancel() {
        socket?.cancel()
        socket = null
        complete("")
    }

    private fun handle(text: String) {
        val update = runCatching {
            DeepgramProtocol.parse(text, synchronized(lock) { confirmed })
        }.getOrElse { failure ->
            report(failure)
            return
        } ?: return

        synchronized(lock) {
            confirmed = update.confirmedSegments
            if (update.text.isNotBlank()) lastText = update.text
        }
        onPartial(update.text)
        // After CloseStream the server's last final result settles the tail;
        // treating it as completion avoids waiting for the socket close frame.
        if (sentEnd && update.final) complete(currentText())
    }

    private fun report(failure: Throwable) {
        error.compareAndSet(null, failure)
        onError(failure)
        fail(failure)
    }

    private fun fail(failure: Throwable) {
        if (!opened.isCompleted) opened.completeExceptionally(failure)
        complete(currentText())
    }

    private fun complete(text: String) {
        if (!finished.isCompleted) finished.complete(text)
    }

    private fun currentText(): String = synchronized(lock) { lastText.trim() }
}
