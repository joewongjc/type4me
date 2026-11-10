package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import com.type4me.android.data.AsrKind
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString.Companion.toByteString
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * A live speech session: audio goes out while the user speaks and partial
 * text comes back through `onPartial`.
 */
interface StreamingAsrSession {
    suspend fun connect(config: AsrConfig, hotwords: List<String>)
    suspend fun send(pcm: ByteArray)
    suspend fun finish(): String
    suspend fun cancel()
}

object StreamingAsr {
    fun create(
        config: AsrConfig,
        onPartial: (String) -> Unit,
        onError: (Throwable) -> Unit,
    ): StreamingAsrSession? {
        PortableStreamingA.create(config.providerId, onPartial, onError)?.let { return it }
        PortableStreamingB.create(config.providerId, onPartial, onError)?.let { return it }
        PortableStreamingC.create(config.providerId, onPartial, onError)?.let { return it }
        return when (config.kind) {
            AsrKind.VOLCANO -> VolcSession(onPartial, onError)
            AsrKind.SONIOX -> SonioxSession(onPartial, onError)
            AsrKind.OPENAI, AsrKind.BATCH, AsrKind.STREAMING -> null
        }
    }

    /** Opens a session, sends a little silence and reports the server's verdict. */
    suspend fun test(config: AsrConfig): Long {
        val failure = AtomicReference<Throwable?>(null)
        val session = create(config, {}, { failure.set(it) })
            ?: throw AsrException("This provider uses a batch endpoint")
        val started = System.currentTimeMillis()
        try {
            session.connect(config, emptyList())
            session.send(ByteArray(6_400))
            delay(1_200)
            failure.get()?.let { throw it }
        } finally {
            withContext(NonCancellable) { runCatching { session.cancel() } }
        }
        return System.currentTimeMillis() - started
    }

    internal val client: OkHttpClient = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .writeTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(20, TimeUnit.SECONDS)
        .build()
}

internal class SonioxSession(
    private val onPartial: (String) -> Unit,
    private val onError: (Throwable) -> Unit,
    private val endpoint: String = SonioxProtocol.ENDPOINT,
) : StreamingAsrSession {
    private val opening = CompletableDeferred<Unit>()
    private val finished = CompletableDeferred<String>()
    private val error = AtomicReference<Throwable?>(null)
    private val lock = Any()
    private val confirmed = StringBuilder()
    private var partial = ""
    @Volatile private var sentEnd = false
    private var socket: WebSocket? = null

    override suspend fun connect(config: AsrConfig, hotwords: List<String>) {
        val request = Request.Builder().url(endpoint).build()
        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send(SonioxProtocol.startMessage(config, hotwords))
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
                    listOfNotNull(t.message, detail).joinToString(": ").ifBlank { "Soniox connection failed" },
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
        socket?.send(pcm.toByteString())
    }

    override suspend fun finish(): String {
        sentEnd = true
        socket?.send("")
        val text = withTimeoutOrNull(15_000) { finished.await() } ?: currentText()
        // The transcript is settled; a forced close avoids keeping the
        // socket (and its OkHttp connection) alive after teardown.
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

    private fun handle(text: String) {
        val update = runCatching { SonioxProtocol.parse(text) }.getOrElse {
            error.compareAndSet(null, it)
            onError(it)
            if (!finished.isCompleted) finished.complete(currentText())
            return
        }
        synchronized(lock) {
            if (update.finalized.isNotEmpty() || update.partial.isNotEmpty()) {
                if (update.finalized.isNotEmpty()) confirmed.append(update.finalized)
                partial = update.partial
            }
        }
        val current = currentText()
        onPartial(current)
        if (update.finished && !finished.isCompleted) finished.complete(current)
    }

    private fun currentText(): String = synchronized(lock) {
        (confirmed.toString() + partial).trim()
    }
}

internal class VolcSession(
    private val onPartial: (String) -> Unit,
    private val onError: (Throwable) -> Unit,
    private val endpoint: String = VolcProtocol.ENDPOINT,
) : StreamingAsrSession {
    private val opening = CompletableDeferred<Unit>()
    private val finished = CompletableDeferred<String>()
    private val error = AtomicReference<Throwable?>(null)
    private val lock = Any()
    private var lastText = ""
    @Volatile private var sentEnd = false
    private var socket: WebSocket? = null

    override suspend fun connect(config: AsrConfig, hotwords: List<String>) {
        val request = Request.Builder()
            .url(endpoint)
            .apply {
                VolcProtocol.buildHeaders(
                    apiKey = config.apiKey,
                    appKey = config.appKey,
                    accessKey = config.accessKey,
                    resourceId = config.resourceId,
                    connectId = UUID.randomUUID().toString(),
                ).forEach { (key, value) -> header(key, value) }
            }
            .build()

        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send(VolcProtocol.fullClientRequest(UUID.randomUUID().toString(), hotwords).toByteString())
                opening.complete(Unit)
            }

            override fun onMessage(webSocket: WebSocket, bytes: okio.ByteString) {
                handle(bytes.toByteArray(), webSocket)
            }

            override fun onMessage(webSocket: WebSocket, text: String) = Unit

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                if (sentEnd) {
                    if (!finished.isCompleted) finished.complete(currentText())
                    return
                }
                val detail = response?.let {
                    runCatching { it.body?.string() }.getOrNull()?.take(200)
                }
                val failure = AsrException(
                    listOfNotNull(t.message, detail).joinToString(": ").ifBlank { "Volcengine connection failed" },
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
        socket?.send(VolcProtocol.audioPacket(pcm, last = false).toByteString())
    }

    override suspend fun finish(): String {
        if (!sentEnd) {
            sentEnd = true
            socket?.send(VolcProtocol.audioPacket(ByteArray(0), last = true).toByteString())
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

    private fun handle(data: ByteArray, webSocket: WebSocket) {
        if (VolcProtocol.isError(data)) {
            val message = VolcProtocol.extractError(data)
            if (!message.isNullOrBlank()) {
                val failure = AsrException(message)
                error.compareAndSet(null, failure)
                onError(failure)
            }
            if (!finished.isCompleted) finished.complete(currentText())
            webSocket.close(1000, null)
            return
        }

        val response = runCatching { VolcProtocol.decode(data) }.getOrElse {
            error.compareAndSet(null, it)
            onError(it)
            if (!finished.isCompleted) finished.complete(currentText())
            return
        }
        synchronized(lock) {
            if (response.text.isNotBlank()) lastText = response.text
        }
        val current = currentText()
        onPartial(current)
        if (response.final && !finished.isCompleted) finished.complete(current)
    }

    private fun currentText(): String = synchronized(lock) { lastText.trim() }
}
