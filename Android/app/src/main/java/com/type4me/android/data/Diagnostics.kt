package com.type4me.android.data

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** A small on-device log for dictation failures; never leaves the phone by itself. */
object Diagnostics {
    private const val FILE = "diagnostics.log"
    private const val LIMIT = 800
    private const val MAX_BYTES = 128 * 1024
    private const val READ_TIMEOUT_MS = 2_000L

    /** Appends run off the caller's thread; reads queue behind them as a barrier. */
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "type4me-diagnostics").apply { isDaemon = true }
    }

    fun add(context: Context, text: String) {
        val stamp = SimpleDateFormat("HH:mm:ss.SSS", Locale.US).format(Date())
        val file = logFile(context)
        executor.execute { append(file, "$stamp $text") }
    }

    fun read(context: Context): String {
        val file = logFile(context)
        val pending = executor.submit(Callable { runCatching { file.readText() }.getOrDefault("") })
        return runCatching { pending.get(READ_TIMEOUT_MS, TimeUnit.MILLISECONDS) }.getOrElse {
            pending.cancel(false)
            runCatching { file.readText() }.getOrDefault("")
        }
    }

    fun clear(context: Context) {
        val file = logFile(context)
        executor.execute { runCatching { file.writeText("") } }
    }

    private fun logFile(context: Context): File =
        File(context.applicationContext.filesDir, FILE)

    private fun append(file: File, line: String) {
        runCatching {
            if (file.length() > MAX_BYTES) trim(file)
            val separator = if (file.length() > 0L) "\n" else ""
            file.appendText(separator + line)
        }
    }

    /** Keeps the log bounded without reading it on every append. */
    private fun trim(file: File) {
        val lines = runCatching { file.readLines() }.getOrDefault(emptyList())
        file.writeText(lines.takeLast(LIMIT).joinToString("\n"))
    }
}
