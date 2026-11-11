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
 * Meta Muse realtime ASR in push-to-talk mode: a JSON handshake, 6400-byte
 * binary audio frames, and `endStream` to request the trailing transcript.
 */
class MetaMuseSession(
    private val onPartial: (String) -> Unit,
    private val onError: (Throwable) -> Unit,
) : StreamingAsrSession {
    private val opening = CompletableDeferred<Unit>()
    private val ready = CompletableDeferred<Unit>()
    private val finished = CompletableDeferred<String>()
    private val error = AtomicReference<Throwable?>(null)
    private val lock = Any()
    private val confirmed = mutableListOf<String>()
    private var partial = ""
    private var lastEmitted = ""
    @Volatile private var sentEnd = false
    private var socket: WebSocket? = null

    override suspend fun connect(config: AsrConfig, hotwords: List<String>) {
        val url = MetaMuseProtocol.buildWebSocketUrl(config)
        val handshake = MetaMuseProtocol.handshakeMessage(config, hotwords)
        val request = Request.Builder().url(url).build()

        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                // The handshake must follow the HTTP upgrade, not prefix it.
                webSocket.send(handshake)
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
                        .ifBlank { "Meta Muse connection failed" },
                )
                error.compareAndSet(null, failure)
                if (!opening.isCompleted) opening.completeExceptionally(failure)
                if (!ready.isCompleted) ready.completeExceptionally(failure)
                onError(failure)
                if (!finished.isCompleted) finished.complete(currentText())
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (!finished.isCompleted) finished.complete(currentText())
            }
        }

        socket = StreamingAsr.client.newWebSocket(request, listener)
        withTimeout(10_000) { opening.await() }
        withTimeout(10_000) { ready.await() }
    }

    override suspend fun send(pcm: ByteArray) {
        if (pcm.isEmpty()) return
        val webSocket = socket ?: return
        var offset = 0
        while (offset < pcm.size) {
            val end = minOf(offset + CHUNK_SIZE, pcm.size)
            webSocket.send(pcm.copyOfRange(offset, end).toByteString())
            offset = end
        }
    }

    override suspend fun finish(): String {
        if (!sentEnd) {
            sentEnd = true
            socket?.send(MetaMuseProtocol.endStreamMessage())
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
        if (!ready.isCompleted) ready.cancel()
        if (!finished.isCompleted) finished.complete("")
    }

    private fun handle(message: String) {
        val event = runCatching {
            MetaMuseProtocol.parse(message)
        }.getOrElse { failure ->
            error.compareAndSet(null, failure)
            onError(failure)
            if (!ready.isCompleted) ready.completeExceptionally(failure)
            if (!finished.isCompleted) finished.complete(currentText())
            return
        }

        when (event) {
            is MetaMuseProtocol.Event.SessionReady -> ready.complete(Unit)

            is MetaMuseProtocol.Event.Transcript -> applyTranscript(event.text, event.isFinal)

            is MetaMuseProtocol.Event.Failed -> {
                val failure = AsrException(event.message)
                error.compareAndSet(null, failure)
                onError(failure)
                if (!ready.isCompleted) ready.completeExceptionally(failure)
                if (!finished.isCompleted) finished.complete(currentText())
            }

            is MetaMuseProtocol.Event.Ignored -> Unit
        }
    }

    private fun applyTranscript(text: String, isFinal: Boolean) {
        synchronized(lock) {
            if (isFinal) {
                if (text.isNotEmpty() && confirmed.lastOrNull() != text) confirmed += text
                partial = ""
            } else {
                if (text.isEmpty() && partial.isEmpty()) return
                partial = text
            }
        }
        val current = currentText()
        if (current != lastEmitted) {
            lastEmitted = current
            onPartial(current)
        }
        if (isFinal && sentEnd && !finished.isCompleted) finished.complete(current)
    }

    private fun currentText(): String = synchronized(lock) {
        (confirmed.joinToString("") + partial).trim()
    }

    private companion object {
        const val CHUNK_SIZE = 6_400
    }
}
