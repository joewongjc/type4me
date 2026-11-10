package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.atomic.AtomicReference

/**
 * Gemini Live transcription. Audio is re-chunked into ~100ms base64 payloads
 * inside an explicit activity window so setup and end-of-turn stay ordered.
 */
class GeminiSession(
    private val onPartial: (String) -> Unit,
    private val onError: (Throwable) -> Unit,
) : StreamingAsrSession {
    private val opening = CompletableDeferred<Unit>()
    private val setup = CompletableDeferred<Unit>()
    private val finished = CompletableDeferred<String>()
    private val error = AtomicReference<Throwable?>(null)
    private val lock = Any()
    private val confirmed = mutableListOf<String>()
    private var partial = ""
    private var lastEmitted = ""
    private var residual = ByteArray(0)
    private var hotwords: List<String> = emptyList()
    @Volatile private var sentEnd = false
    @Volatile private var didStartActivity = false
    private var socket: WebSocket? = null

    override suspend fun connect(config: AsrConfig, hotwords: List<String>) {
        this.hotwords = hotwords
        val url = GeminiProtocol.buildWebSocketUrl(config)
        val setupMessage = GeminiProtocol.setupMessage(config, hotwords)
        val request = Request.Builder().url(url).build()

        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send(setupMessage)
                opening.complete(Unit)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handle(text)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                val detail = response?.let {
                    runCatching { it.body?.string() }.getOrNull()?.take(200)
                }
                val failure = AsrException(
                    listOfNotNull(t.message, detail).joinToString(": ")
                        .ifBlank { "Gemini connection failed" },
                )
                error.compareAndSet(null, failure)
                if (!opening.isCompleted) opening.completeExceptionally(failure)
                if (!setup.isCompleted) setup.completeExceptionally(failure)
                onError(failure)
                if (!finished.isCompleted) finished.complete(currentText())
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                // Gemini reports quota and duration limits as close frames.
                if (sentEnd) {
                    if (!finished.isCompleted) finished.complete(currentText())
                    return
                }
                if (!finished.isCompleted) {
                    val failure = AsrException(
                        "Gemini connection closed before the transcript finished ($code)" +
                            if (reason.isBlank()) "" else ": $reason",
                    )
                    error.compareAndSet(null, failure)
                    onError(failure)
                    finished.complete(currentText())
                }
            }
        }

        socket = StreamingAsr.client.newWebSocket(request, listener)
        withTimeout(10_000) { opening.await() }
        withTimeout(10_000) { setup.await() }
    }

    override suspend fun send(pcm: ByteArray) {
        if (pcm.isEmpty()) return
        val webSocket = socket ?: return
        residual += pcm
        if (!didStartActivity) {
            webSocket.send(GeminiProtocol.activityStartMessage())
            didStartActivity = true
        }
        val (payloads, rest) = GeminiProtocol.sliceAudioPayloads(residual)
        residual = rest
        for (payload in payloads) {
            webSocket.send(GeminiProtocol.audioChunkMessage(payload))
        }
    }

    override suspend fun finish(): String {
        val webSocket = socket
        GeminiProtocol.flushResidualAudio(residual)?.let { tail ->
            residual = ByteArray(0)
            if (!didStartActivity) {
                webSocket?.send(GeminiProtocol.activityStartMessage())
                didStartActivity = true
            }
            webSocket?.send(GeminiProtocol.audioChunkMessage(tail))
        }
        // No audio ever reached the server: nothing to finalize.
        if (!didStartActivity || webSocket == null) {
            val text = currentText()
            socket?.cancel()
            socket = null
            return text
        }
        sentEnd = true
        webSocket.send(GeminiProtocol.activityEndMessage())
        val text = withTimeoutOrNull(12_000) { finished.await() } ?: currentText()
        webSocket.cancel()
        socket = null
        val failure = error.get()
        if (text.isBlank() && failure != null) throw failure
        return text
    }

    override suspend fun cancel() {
        socket?.cancel()
        socket = null
        if (!finished.isCompleted) finished.complete("")
    }

    private fun handle(message: String) {
        val update = runCatching {
            GeminiProtocol.parse(message, snapshot(), sentEnd, hotwords)
        }.getOrElse { failure ->
            error.compareAndSet(null, failure)
            onError(failure)
            if (!setup.isCompleted) setup.completeExceptionally(failure)
            if (!finished.isCompleted) finished.complete(currentText())
            return
        } ?: return

        if (update.isSetupComplete) {
            setup.complete(Unit)
            return
        }
        if (update.goAway) {
            // The server wants the connection to migrate; keep what we have.
            if (!finished.isCompleted) finished.complete(currentText())
            socket?.close(1000, null)
            return
        }

        val proposed = (update.confirmedSegments.joinToString("") + update.partial).trim()
        val completes = update.isFinal && sentEnd
        if (proposed == lastEmitted && !completes) return

        synchronized(lock) {
            confirmed.clear()
            confirmed.addAll(update.confirmedSegments)
            partial = update.partial
        }
        val current = currentText()
        if (current != lastEmitted) {
            lastEmitted = current
            onPartial(current)
        }
        if (completes && !finished.isCompleted) finished.complete(current)
    }

    private fun snapshot(): List<String> = synchronized(lock) { confirmed.toList() }

    private fun currentText(): String = synchronized(lock) {
        (confirmed.joinToString("") + partial).trim()
    }
}
