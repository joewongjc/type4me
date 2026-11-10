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
 * AssemblyAI streaming session. The session is ready once the server sends
 * `Begin`; keyterms follow as an `UpdateConfiguration`, audio is sent as
 * binary frames, and `Terminate` closes the recording.
 */
class AssemblyAISession(
    private val onPartial: (String) -> Unit,
    private val onError: (Throwable) -> Unit,
) : StreamingAsrSession {
    private val begun = CompletableDeferred<Unit>()
    private val finished = CompletableDeferred<String>()
    private val error = AtomicReference<Throwable?>(null)
    private val accumulator = AssemblyAITranscriptAccumulator()
    private val lock = Any()
    @Volatile private var sentTerminate = false
    private var socket: WebSocket? = null

    override suspend fun connect(config: AsrConfig, hotwords: List<String>) {
        val request = Request.Builder()
            .url(AssemblyAIProtocol.buildUrl(config, enablePunc = enablePunctuation(config)))
            .header("Authorization", config.apiKey.trim())
            .build()

        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = Unit

            override fun onMessage(webSocket: WebSocket, text: String) = handle(text)

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                val detail = response?.let {
                    runCatching { it.body?.string() }.getOrNull()?.take(200)
                }
                val failure = AsrException(
                    listOfNotNull(t.message, detail).joinToString(": ")
                        .ifBlank { "AssemblyAI connection failed" },
                )
                report(failure)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                val message = AssemblyAIProtocol.closeErrorMessage(code, reason)
                if (!begun.isCompleted) {
                    fail(AsrException(message))
                    return
                }
                if (!sentTerminate) {
                    val failure = AsrException(message)
                    error.compareAndSet(null, failure)
                    onError(failure)
                }
                complete(currentText())
            }
        }

        socket = StreamingAsr.client.newWebSocket(request, listener)
        withTimeout(10_000) { begun.await() }
        AssemblyAIProtocol.updateConfigurationMessage(hotwords)?.let { socket?.send(it) }
    }

    override suspend fun send(pcm: ByteArray) {
        if (pcm.isEmpty()) return
        socket?.send(pcm.toByteString())
    }

    override suspend fun finish(): String {
        if (!sentTerminate) {
            sentTerminate = true
            socket?.send(AssemblyAIProtocol.terminateMessage())
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
        val event = runCatching { AssemblyAIProtocol.parse(text) }.getOrElse { failure ->
            report(failure)
            return
        } ?: return

        when (event) {
            AssemblyAIProtocol.Event.Begin -> if (!begun.isCompleted) begun.complete(Unit)

            is AssemblyAIProtocol.Event.Turn -> {
                val transcript = synchronized(lock) {
                    accumulator.apply(event.update)
                    accumulator.transcript()
                }
                onPartial(transcript.authoritativeText)
            }

            AssemblyAIProtocol.Event.Termination -> complete(currentText())

            AssemblyAIProtocol.Event.SpeechStarted -> Unit
        }
    }

    private fun enablePunctuation(config: AsrConfig): Boolean =
        config.extra["format_turns"]?.equals("false", ignoreCase = true) != true

    private fun report(failure: Throwable) {
        error.compareAndSet(null, failure)
        onError(failure)
        fail(failure)
    }

    private fun fail(failure: Throwable) {
        if (!begun.isCompleted) begun.completeExceptionally(failure)
        complete(currentText())
    }

    private fun complete(text: String) {
        if (!finished.isCompleted) finished.complete(text)
    }

    private fun currentText(): String =
        synchronized(lock) { accumulator.transcript().authoritativeText.trim() }
}
