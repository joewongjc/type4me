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
 * Microsoft Foundry Realtime session for MAI-Transcribe-2-Streaming. Deltas are final
 * text; the intermediate suffix is replaced on every update. The client commits once
 * when recording ends because the service has no turn detection.
 */
class AzureSession(
    private val onPartial: (String) -> Unit,
    private val onError: (Throwable) -> Unit,
    private val endpoint: String? = null,
) : StreamingAsrSession {
    private val opening = CompletableDeferred<Unit>()
    private val finished = CompletableDeferred<String>()
    private val error = AtomicReference<Throwable?>(null)
    private val lock = Any()
    private var confirmed = ""
    private var intermediate = ""
    private var sentBytes = 0

    @Volatile
    private var awaitingCompletion = false
    private var socket: WebSocket? = null

    override suspend fun connect(config: AsrConfig, hotwords: List<String>) {
        val settings = AzureProtocol.settings(config)
        val request = Request.Builder()
            .url(endpoint ?: AzureProtocol.realtimeUrl(settings))
            .header("api-key", settings.apiKey)
            .build()

        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send(AzureProtocol.sessionUpdateMessage(settings))
                if (!opening.isCompleted) opening.complete(Unit)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handle(text)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                val status = response?.code
                val detail = response?.let {
                    runCatching { it.body?.string() }.getOrNull()?.take(200)
                }
                val failure = AsrException(
                    when {
                        status == 401 || status == 403 ->
                            "Microsoft Azure authentication failed (HTTP $status). " +
                                "Check that the API key matches the resource."
                        status == 404 ->
                            "Microsoft Azure realtime endpoint not found (HTTP 404). " +
                                "Check the resource name and region."
                        status != null && status != 101 ->
                            "Microsoft Azure realtime connection failed (HTTP $status)"
                        else -> listOfNotNull(t.message, detail).joinToString(": ")
                            .ifBlank { "Microsoft Azure realtime connection failed" }
                    },
                )
                fail(failure)
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
        val sent = socket?.send(AzureProtocol.appendMessage(pcm)) ?: return
        if (sent) sentBytes += pcm.size
    }

    override suspend fun finish(): String {
        val current = currentText()
        if (sentBytes < MIN_COMMIT_BYTES) {
            finishWith(current)
            // Cancel rather than wait for a close handshake: a recording this
            // short is already done, and some servers keep the socket open.
            socket?.cancel()
            socket = null
            return current.trim()
        }
        awaitingCompletion = true
        socket?.send(AzureProtocol.COMMIT_MESSAGE)
        val text = withTimeoutOrNull(15_000) { finished.await() } ?: current
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

    private fun handle(text: String) {
        val event = runCatching { AzureProtocol.parseEvent(text) }.getOrElse {
            fail(it)
            return
        }
        when (event) {
            is AzureProtocol.Event.Delta -> {
                synchronized(lock) {
                    confirmed += event.text
                    intermediate = ""
                }
                emitTranscript()
            }

            is AzureProtocol.Event.Intermediate -> {
                synchronized(lock) { intermediate = event.text }
                emitTranscript()
            }

            is AzureProtocol.Event.Completed -> {
                if (awaitingCompletion) {
                    finishWith(event.transcript.ifBlank { currentText() })
                }
            }

            AzureProtocol.Event.Created,
            AzureProtocol.Event.Updated,
            AzureProtocol.Event.Committed,
            AzureProtocol.Event.Ignored,
            -> Unit
        }
    }

    private fun emitTranscript() {
        val text = currentText()
        if (text.isNotBlank()) onPartial(text)
    }

    private fun finishWith(text: String) {
        awaitingCompletion = false
        synchronized(lock) {
            confirmed = text.trim()
            intermediate = ""
        }
        onPartial(confirmed)
        if (!finished.isCompleted) finished.complete(confirmed)
    }

    private fun currentText(): String = synchronized(lock) { (confirmed + intermediate).trim() }

    private fun fail(failure: Throwable) {
        error.compareAndSet(null, failure)
        onError(failure)
        if (!opening.isCompleted) opening.completeExceptionally(failure)
        awaitingCompletion = false
        if (!finished.isCompleted) finished.complete(currentText())
    }

    private companion object {
        /** Commits shorter than this (0.1s of 16-bit mono) are skipped. */
        const val MIN_COMMIT_BYTES = AzureProtocol.SAMPLE_RATE * 2 / 10
    }
}
