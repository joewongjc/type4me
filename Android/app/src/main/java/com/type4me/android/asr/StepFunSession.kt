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
 * StepFun realtime ASR. The session waits for `session.updated` before the
 * caller may stream audio, then commits on finish and waits for the completed
 * transcript.
 */
class StepFunSession(
    private val onPartial: (String) -> Unit,
    private val onError: (Throwable) -> Unit,
) : StreamingAsrSession {
    private val ready = CompletableDeferred<Unit>()
    private val finished = CompletableDeferred<String>()
    private val error = AtomicReference<Throwable?>(null)
    private val lock = Any()
    private var lastText = ""
    @Volatile private var sentCommit = false
    private var socket: WebSocket? = null

    override suspend fun connect(config: AsrConfig, hotwords: List<String>) {
        val request = Request.Builder()
            .url(StepFunProtocol.endpoint(config))
            .header("Authorization", "Bearer ${config.apiKey.trim()}")
            .build()

        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send(StepFunProtocol.buildSessionUpdateMessage(config, hotwords))
            }

            override fun onMessage(webSocket: WebSocket, text: String) = handle(text)

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                val detail = response?.let {
                    runCatching { it.body?.string() }.getOrNull()?.take(200)
                }
                val failure = AsrException(
                    listOfNotNull(t.message, detail).joinToString(": ")
                        .ifBlank { "StepFun connection failed" },
                )
                error.compareAndSet(null, failure)
                if (!sentCommit) onError(failure)
                fail(failure)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (!ready.isCompleted) {
                    fail(
                        AsrException(
                            "StepFun closed before the session was ready ($code)" +
                                if (reason.isBlank()) "" else ": $reason",
                        ),
                    )
                }
                complete(currentText())
            }
        }

        socket = StreamingAsr.client.newWebSocket(request, listener)
        withTimeout(10_000) { ready.await() }
    }

    override suspend fun send(pcm: ByteArray) {
        if (pcm.isEmpty()) return
        socket?.send(StepFunProtocol.buildAppendAudioMessage(pcm))
    }

    override suspend fun finish(): String {
        if (!sentCommit) {
            sentCommit = true
            socket?.send(StepFunProtocol.buildCommitMessage())
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
        val event = runCatching { StepFunProtocol.parse(text) }.getOrElse { failure ->
            report(failure)
            return
        } ?: return

        when (event) {
            StepFunProtocol.Event.SessionReady -> if (!ready.isCompleted) ready.complete(Unit)

            is StepFunProtocol.Event.Transcript -> {
                synchronized(lock) { lastText = event.text }
                onPartial(event.text)
                if (event.final) complete(event.text)
            }

            is StepFunProtocol.Event.Failure -> report(AsrException(event.message))
        }
    }

    private fun report(failure: Throwable) {
        error.compareAndSet(null, failure)
        onError(failure)
        fail(failure)
    }

    private fun fail(failure: Throwable) {
        if (!ready.isCompleted) ready.completeExceptionally(failure)
        complete(currentText())
    }

    private fun complete(text: String) {
        if (!finished.isCompleted) finished.complete(text)
    }

    private fun currentText(): String = synchronized(lock) { lastText.trim() }
}
