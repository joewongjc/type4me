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
 * Alibaba Cloud Bailian realtime session: run-task, raw PCM frames, then finish-task.
 * The server reports sentences; confirmed ones are kept and the current one is replaced.
 */
class BailianSession(
    private val onPartial: (String) -> Unit,
    private val onError: (Throwable) -> Unit,
    private val endpoint: String? = null,
) : StreamingAsrSession {
    private val opening = CompletableDeferred<Unit>()
    private val finished = CompletableDeferred<String>()
    private val error = AtomicReference<Throwable?>(null)
    private val transcript = BailianTranscript()
    // WebSocket callbacks write while finish() reads; the transcript is not thread safe.
    private val transcriptLock = Any()
    private var taskId = ""
    @Volatile private var sentFinish = false
    private var socket: WebSocket? = null

    override suspend fun connect(config: AsrConfig, hotwords: List<String>) {
        val settings = BailianProtocol.settings(config)
        taskId = UUID.randomUUID().toString().lowercase()
        val request = Request.Builder()
            .url(endpoint ?: settings.endpoint)
            .header("Authorization", "Bearer ${settings.apiKey}")
            .build()

        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send(BailianProtocol.buildRunTaskMessage(config, taskId))
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handle(text)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                if (sentFinish) {
                    if (!finished.isCompleted) finished.complete(transcriptText())
                    return
                }
                val detail = response?.let {
                    runCatching { it.body?.string() }.getOrNull()?.take(200)
                }
                val failure = AsrException(
                    listOfNotNull(t.message, detail).joinToString(": ")
                        .ifBlank { "Alibaba Cloud Bailian connection failed" },
                )
                fail(failure)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                if (!opening.isCompleted) {
                    fail(
                        AsrException(
                            "Alibaba Cloud Bailian closed before the task started ($code)" +
                                if (reason.isBlank()) "" else ": $reason",
                        ),
                    )
                }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (!finished.isCompleted) finished.complete(transcriptText())
            }
        }

        socket = StreamingAsr.client.newWebSocket(request, listener)
        val started = withTimeoutOrNull(8_000) { opening.await() }
        if (started == null) {
            socket?.cancel()
            socket = null
            throw AsrException("Alibaba Cloud Bailian task-start handshake timed out")
        }
    }

    override suspend fun send(pcm: ByteArray) {
        if (pcm.isEmpty()) return
        socket?.send(pcm.toByteString())
    }

    override suspend fun finish(): String {
        if (!sentFinish) {
            sentFinish = true
            socket?.send(BailianProtocol.buildFinishTaskMessage(taskId))
        }
        val text = withTimeoutOrNull(12_000) { finished.await() } ?: transcriptText()
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
        val event = runCatching { BailianProtocol.parseEvent(text) }.getOrElse {
            fail(it)
            return
        }
        when (event) {
            is BailianProtocol.Event.Started -> if (!opening.isCompleted) opening.complete(Unit)

            is BailianProtocol.Event.SentenceEvent -> {
                if (!opening.isCompleted) opening.complete(Unit)
                applySentence(event.sentence)?.let { onPartial(it) }
            }

            BailianProtocol.Event.Finished -> if (!finished.isCompleted) finished.complete(transcriptText())

            is BailianProtocol.Event.Failed -> {
                val detail = listOfNotNull(
                    event.code?.let { "[$it]" },
                    event.message,
                ).joinToString(" ")
                fail(
                    AsrException(
                        if (detail.isBlank()) {
                            "Alibaba Cloud Bailian ASR failed"
                        } else {
                            "Alibaba Cloud Bailian ASR failed: $detail"
                        },
                    ),
                )
                socket?.close(1000, null)
            }

            null -> Unit
        }
    }

    /** Applies one sentence and returns the new transcript, or null when nothing changed. */
    private fun applySentence(sentence: BailianProtocol.Sentence): String? =
        synchronized(transcriptLock) {
            if (transcript.apply(sentence)) transcript.text else null
        }

    private fun transcriptText(): String = synchronized(transcriptLock) { transcript.text }

    private fun fail(failure: Throwable) {
        error.compareAndSet(null, failure)
        onError(failure)
        if (!opening.isCompleted) opening.completeExceptionally(failure)
        if (!finished.isCompleted) finished.complete(transcriptText())
    }
}
