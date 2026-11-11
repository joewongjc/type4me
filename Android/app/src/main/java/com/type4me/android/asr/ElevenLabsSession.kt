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
 * ElevenLabs Scribe v2 realtime. Audio goes up as base64 JSON chunks; the
 * server acknowledges explicit commits with a final transcript.
 */
class ElevenLabsSession(
    private val onPartial: (String) -> Unit,
    private val onError: (Throwable) -> Unit,
) : StreamingAsrSession {
    private val opening = CompletableDeferred<Unit>()
    private val finished = CompletableDeferred<String>()
    private val error = AtomicReference<Throwable?>(null)
    private val lock = Any()
    private val confirmed = mutableListOf<String>()
    private var partial = ""
    private var lastEmitted = ""
    @Volatile private var sentEnd = false
    @Volatile private var languageCode = ""
    private var socket: WebSocket? = null

    override suspend fun connect(config: AsrConfig, hotwords: List<String>) {
        val url = ElevenLabsProtocol.buildWebSocketUrl(config, hotwords)
        languageCode = config.extraValue("language")
        if (config.apiKey.isBlank()) throw AsrException("ElevenLabs API key is empty")
        val request = Request.Builder()
            .url(url)
            .header("xi-api-key", config.apiKey)
            .build()
        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                opening.complete(Unit)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handle(text)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                if (sentEnd) {
                    if (!finished.isCompleted) finished.complete(currentText())
                    return
                }
                val detail = response?.let {
                    runCatching { it.body?.string() }.getOrNull()?.take(200)
                }
                val failure = AsrException(
                    listOfNotNull(t.message, detail).joinToString(": ")
                        .ifBlank { "ElevenLabs connection failed" },
                )
                error.compareAndSet(null, failure)
                onError(failure)
                if (!opening.isCompleted) opening.completeExceptionally(failure)
                if (!finished.isCompleted) finished.complete(currentText())
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (!finished.isCompleted) finished.complete(currentText())
            }
        }
        socket = StreamingAsr.client.newWebSocket(request, listener)
        withTimeout(10_000) { opening.await() }
    }

    override suspend fun send(pcm: ByteArray) {
        if (pcm.isEmpty()) return
        socket?.send(ElevenLabsProtocol.audioChunkMessage(pcm))
    }

    override suspend fun finish(): String {
        if (!sentEnd) {
            sentEnd = true
            socket?.send(ElevenLabsProtocol.commitMessage())
        }
        val text = withTimeoutOrNull(12_000) { finished.await() } ?: currentText()
        socket?.cancel()
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
            ElevenLabsProtocol.parse(message, snapshot(), sentEnd, languageCode)
        }.getOrElse { failure ->
            error.compareAndSet(null, failure)
            onError(failure)
            if (!finished.isCompleted) finished.complete(currentText())
            return
        } ?: return

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
        if (update.isFinal && sentEnd && !finished.isCompleted) finished.complete(current)
    }

    private fun snapshot(): List<String> = synchronized(lock) { confirmed.toList() }

    private fun currentText(): String = synchronized(lock) {
        (confirmed.joinToString("") + partial).trim()
    }
}
