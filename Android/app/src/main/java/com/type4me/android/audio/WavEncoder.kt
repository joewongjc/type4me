package com.type4me.android.audio

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Wraps 16-bit PCM in the 44-byte WAV header every transcription API accepts. */
object WavEncoder {
    fun encode(pcm: ByteArray): ByteArray {
        val channels = 1
        val bitsPerSample = 16
        val blockAlign = channels * bitsPerSample / 8
        val byteRate = SAMPLE_RATE * blockAlign
        val output = ByteArray(44 + pcm.size)
        val buffer = ByteBuffer.wrap(output).order(ByteOrder.LITTLE_ENDIAN)

        buffer.put("RIFF".toByteArray(Charsets.US_ASCII))
        buffer.putInt(36 + pcm.size)
        buffer.put("WAVE".toByteArray(Charsets.US_ASCII))
        buffer.put("fmt ".toByteArray(Charsets.US_ASCII))
        buffer.putInt(16)
        buffer.putShort(1)
        buffer.putShort(channels.toShort())
        buffer.putInt(SAMPLE_RATE)
        buffer.putInt(byteRate)
        buffer.putShort(blockAlign.toShort())
        buffer.putShort(bitsPerSample.toShort())
        buffer.put("data".toByteArray(Charsets.US_ASCII))
        buffer.putInt(pcm.size)
        buffer.put(pcm)

        return output
    }

    private const val SAMPLE_RATE = 16_000
}
