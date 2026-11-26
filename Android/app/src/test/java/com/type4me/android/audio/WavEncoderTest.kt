package com.type4me.android.audio

import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class WavEncoderTest {
    @Test
    fun writesAStandardMonoPcmHeader() {
        val pcm = ByteArray(3_200) { 7 }
        val wav = WavEncoder.encode(pcm)
        val buffer = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN)

        assertEquals(44 + pcm.size, wav.size)
        assertEquals("RIFF", String(wav, 0, 4, Charsets.US_ASCII))
        assertEquals(36 + pcm.size, buffer.getInt(4))
        assertEquals("WAVE", String(wav, 8, 4, Charsets.US_ASCII))
        assertEquals("fmt ", String(wav, 12, 4, Charsets.US_ASCII))
        assertEquals(16, buffer.getInt(16))
        assertEquals(1, buffer.getShort(20).toInt())
        assertEquals(1, buffer.getShort(22).toInt())
        assertEquals(16_000, buffer.getInt(24))
        assertEquals(32_000, buffer.getInt(28))
        assertEquals(2, buffer.getShort(32).toInt())
        assertEquals(16, buffer.getShort(34).toInt())
        assertEquals("data", String(wav, 36, 4, Charsets.US_ASCII))
        assertEquals(pcm.size, buffer.getInt(40))
        assertEquals(7, wav[44].toInt())
    }
}
