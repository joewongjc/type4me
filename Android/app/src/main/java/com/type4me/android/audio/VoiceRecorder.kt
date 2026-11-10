package com.type4me.android.audio

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Process
import androidx.core.content.ContextCompat
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.sqrt

/**
 * Records 16 kHz mono PCM16 while the keyboard is visible. Android lets an IME
 * hold the microphone itself, which is the main difference from the iOS
 * keyboard-extension design.
 */
class VoiceRecorder(
    private val context: Context,
    private val maxDurationMs: Long = 60_000,
    private val onLevel: (Float) -> Unit,
    private val onLimitReached: () -> Unit,
    private val onAudio: (ByteArray) -> Unit = {},
) {
    private val reading = AtomicBoolean(false)
    private val output = ByteArrayOutputStream()
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    private var startedAt = 0L
    private var stopped = false

    /** Set when the system refuses the microphone because another app has it. */
    var lastError: String? = null
        private set

    fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    // The permission is checked above and the constructor/start calls catch
    // SecurityException, so a revocation between the check and the call ends
    // the recording instead of crashing the IME.
    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        lastError = null
        if (!hasPermission()) {
            lastError = "permission"
            return false
        }
        if (record != null) return true

        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) return false
        val bufferSize = maxOf(minBuffer * 2, SAMPLE_RATE) // 0.5 s of headroom

        val audioRecord = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize,
            )
        } catch (_: Exception) {
            return false
        }

        if (audioRecord.state != AudioRecord.STATE_INITIALIZED) {
            audioRecord.release()
            return false
        }

        record = audioRecord
        output.reset()
        stopped = false
        reading.set(true)
        startedAt = System.currentTimeMillis()

        try {
            audioRecord.startRecording()
        } catch (error: Exception) {
            lastError = if (error is IllegalStateException) "busy" else "unavailable"
            reading.set(false)
            audioRecord.release()
            record = null
            return false
        }

        thread = Thread {
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            // Read in 200 ms slices so streaming services get a steady feed
            // and the level meter moves while the user speaks.
            val buffer = ByteArray(minOf(bufferSize, 6_400))
            try {
                while (reading.get()) {
                    val read = audioRecord.read(buffer, 0, buffer.size)
                    if (read > 0) {
                        output.write(buffer, 0, read)
                        onAudio(buffer.copyOf(read))
                        onLevel(levelOf(buffer, read))
                    } else if (read < 0) {
                        break
                    }
                    if (System.currentTimeMillis() - startedAt >= maxDurationMs) {
                        onLimitReached()
                        break
                    }
                }
            } catch (_: Exception) {
                // A device that revokes the microphone mid-session ends the
                // recording; the service reports the empty result.
            }
        }.apply {
            name = "type4me-recorder"
            start()
        }

        return true
    }

    /** Stops capturing and returns everything recorded, without a WAV header. */
    fun stop(): ByteArray {
        if (stopped) return ByteArray(0)
        stopped = true
        reading.set(false)
        // Stop first so a read blocked on the microphone returns, then join
        // before reading the buffer: nothing may write after this point.
        record?.let { runCatching { it.stop() } }
        thread?.join(800)
        thread = null
        record?.release()
        record = null
        onLevel(0f)
        return output.toByteArray()
    }

    private fun levelOf(buffer: ByteArray, length: Int): Float {
        var sum = 0.0
        var index = 0
        while (index + 1 < length) {
            val sample = (buffer[index].toInt() and 0xFF) or (buffer[index + 1].toInt() shl 8)
            val signed = sample.toShort().toInt()
            sum += signed.toDouble() * signed
            index += 2
        }
        val count = length / 2
        if (count == 0) return 0f
        val rms = sqrt(sum / count) / Short.MAX_VALUE
        return (rms * 12).toFloat().coerceIn(0f, 1f)
    }

    companion object {
        const val SAMPLE_RATE = 16_000
    }
}
