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
 * xAI realtime STT. Raw PCM goes up as binary frames; the server signals a
 * ready transcript once per session and answers `audio.done` with the final text.
 */
class GrokSession(
    private val onPartial: (String) -> Unit,
    private val onError: (Throwable) -> Unit,
) : StreamingAsrSession {
    private val opening = CompletableDeferred<Unit>()
    private val ready = CompletableDeferred<Unit>()
    private val finished = CompletableDeferred<String>()
    private val error = AtomicReference<Throwable?>(null)
    private val lock = Any()
    private var state = GrokProtocol.State()
    private var partial = ""
    private var lastEmitted = ""
    @Volatile private var sentEnd = false
    private var receivedFinal = false
    private var socket: WebSocket? = null

    override suspend fun connect(config: AsrConfig, hotwords: List<String>) {
        val url = GrokProtocol.buildWebSocketUrl(config, hotwords)
        if (config.apiKey.isBlank()) throw AsrException("Grok API key is empty")
        val request = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer ${config.apiKey}")
            .build()

        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                opening.complete(Unit)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handle(text)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                if (sentEnd && receivedFinal) {
                    if (!finished.isCompleted) finished.complete(currentText())
                    return
                }
                val detail = response?.let {
                    runCatching { it.body?.string() }.getOrNull()?.take(200)
                }
                val status = response?.code
                val failure = AsrException(
                    when {
                        status == 401 -> "Invalid or disabled Grok API key (HTTP 401)"
                        status == 403 -> "Grok API key not authorized for this service (HTTP 403)"
                        status == 429 -> "Grok rate limit reached (HTTP 429)"
                        else -> listOfNotNull(t.message, detail).joinToString(": ")
                            .ifBlank { "Grok connection failed" }
                    },
                )
                reportSessionFailure(onError, error, failure)
                if (!opening.isCompleted) opening.completeExceptionally(failure)
                if (!ready.isCompleted) ready.completeExceptionally(failure)
                if (!finished.isCompleted) finished.complete(currentText())
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (!receivedFinal) {
                    reportSessionFailure(
                        onError,
                        error,
                        AsrException(
                            "Grok closed before the transcript finished ($code)" +
                                if (reason.isBlank()) "" else ": $reason",
                        ),
                    )
                }
                if (!finished.isCompleted) finished.complete(currentText())
            }
        }

        socket = StreamingAsr.client.newWebSocket(request, listener)
        withTimeout(10_000) { opening.await() }
        withTimeout(10_000) { ready.await() }
    }

    override suspend fun send(pcm: ByteArray) {
        if (pcm.isEmpty()) return
        socket?.send(pcm.toByteString())
    }

    override suspend fun finish(): String {
        if (!sentEnd) {
            sentEnd = true
            socket?.send(GrokProtocol.finalizeMessage())
            socket?.send(GrokProtocol.audioDoneMessage())
        }
        val text = withTimeoutOrNull(12_000) { finished.await() } ?: currentText()
        socket?.cancel()
        socket = null
        return sessionResult(text, error.get())
    }

    override suspend fun cancel() {
        socket?.cancel()
        socket = null
        if (!ready.isCompleted) ready.cancel()
        if (!finished.isCompleted) finished.complete("")
    }

    private fun handle(message: String) {
        val update = runCatching {
            GrokProtocol.parse(message, snapshot(), sentEnd)
        }.getOrElse { failure ->
            reportSessionFailure(onError, error, failure)
            if (!ready.isCompleted) ready.completeExceptionally(failure)
            if (!finished.isCompleted) finished.complete(currentText())
            return
        } ?: return

        if (update.serverReady) {
            ready.complete(Unit)
            return
        }

        val proposed = (update.state.joinedConfirmed + update.partial).trim()
        val completes = update.isFinal && sentEnd
        if (completes) receivedFinal = true
        if (proposed == lastEmitted && !completes) return

        synchronized(lock) {
            state = update.state
            partial = update.partial
        }
        val current = currentText()
        if (current != lastEmitted) {
            lastEmitted = current
            onPartial(current)
        }
        if (completes && !finished.isCompleted) finished.complete(current)
    }

    private fun snapshot(): GrokProtocol.State = synchronized(lock) { state }

    private fun currentText(): String = synchronized(lock) {
        (state.joinedConfirmed + partial).trim()
    }
}
