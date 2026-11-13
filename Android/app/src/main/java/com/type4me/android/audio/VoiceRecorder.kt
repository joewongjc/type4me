package com.type4me.android.audio

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Process
import androidx.core.content.ContextCompat
import com.type4me.android.data.AppPrefs
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
    private val onLevel: (Float) -> Unit,
    private val onLimitReached: () -> Unit,
    private val onAudio: (ByteArray) -> Unit = {},
) {
    private val audioManager by lazy { context.getSystemService(AudioManager::class.java) }
    private val prefs by lazy { AppPrefs.get(context) }
    private var previousMusicVolume: Int? = null

    init {
        // If the IME process was killed while ducked, put the volume back.
        restoreMediaVolume()
    }

    private val reading = AtomicBoolean(false)
    private val output = ByteArrayOutputStream()
    private val outputLock = Any()
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

        duckMediaVolume()
        record = audioRecord
        synchronized(outputLock) { output.reset() }
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
            restoreMediaVolume()
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
                        val chunk = buffer.copyOf(read)
                        synchronized(outputLock) { output.write(chunk, 0, chunk.size) }
                        onAudio(chunk)
                        onLevel(levelOf(chunk, chunk.size))
                    } else if (read < 0) {
                        break
                    }
                    if (System.currentTimeMillis() - startedAt >= MAX_DURATION_MS) {
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
        // Stop first so a read blocked on the microphone returns. A timed-out
        // join leaves the writer alive, so the buffer stays synchronized.
        record?.let { runCatching { it.stop() } }
        val writer = thread
        writer?.join(800)
        if (writer?.isAlive == true) writer.interrupt()
        thread = null
        record?.release()
        record = null
        restoreMediaVolume()
        onLevel(0f)
        return synchronized(outputLock) { output.toByteArray() }
    }

    /** Silences media without pausing playback. */
    private fun duckMediaVolume() {
        val manager = audioManager ?: return
        val max = runCatching { manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC) }
            .getOrNull() ?: return
        val saved = runCatching { manager.getStreamVolume(AudioManager.STREAM_MUSIC) }
            .getOrNull() ?: return
        val ducked = MediaVolumeDucking.duckedLevel(saved, max) ?: return
        previousMusicVolume = saved
        // Persist the value in case the service is killed before stop() runs.
        prefs.edit()
            .putInt(PREF_SAVED_MUSIC_VOLUME, saved)
            .putBoolean(PREF_DUCKING_MUSIC, true)
            .apply()
        runCatching { manager.setStreamVolume(AudioManager.STREAM_MUSIC, ducked, 0) }
    }

    private fun restoreMediaVolume() {
        val saved = previousMusicVolume
            ?: prefs.takeIf { it.getBoolean(PREF_DUCKING_MUSIC, false) }
                ?.getInt(PREF_SAVED_MUSIC_VOLUME, -1)
                ?.takeIf { it >= 0 }
            ?: return
        previousMusicVolume = null
        prefs.edit()
            .remove(PREF_SAVED_MUSIC_VOLUME)
            .remove(PREF_DUCKING_MUSIC)
            .apply()
        runCatching {
            audioManager?.setStreamVolume(AudioManager.STREAM_MUSIC, saved, 0)
        }
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
        private const val MAX_DURATION_MS = 60_000L
        private const val PREF_SAVED_MUSIC_VOLUME = "audio.savedMusicVolume"
        private const val PREF_DUCKING_MUSIC = "audio.duckingMusic"
    }
}
