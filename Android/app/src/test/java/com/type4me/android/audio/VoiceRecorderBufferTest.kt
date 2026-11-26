package com.type4me.android.audio

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class VoiceRecorderBufferTest {
    @Test
    fun synchronizedSnapshotsKeepEveryCompleteWrite() {
        val buffer = ByteArrayOutputStream()
        val lock = Any()
        val writerStarted = CountDownLatch(1)
        val writerDone = CountDownLatch(1)
        val writer = Thread {
            writerStarted.countDown()
            repeat(100) {
                // The same guard used by VoiceRecorder.stop(): a snapshot can
                // only see writes finished before the lock was acquired.
                synchronized(lock) { buffer.write(byteArrayOf(1, 2, 3, 4), 0, 4) }
            }
            writerDone.countDown()
        }.apply { start() }
        assertTrue(writerStarted.await(1, TimeUnit.SECONDS))

        val snapshot = synchronized(lock) { buffer.toByteArray() }
        assertTrue(writerDone.await(1, TimeUnit.SECONDS))
        writer.join(800)
        if (writer.isAlive) writer.interrupt()
        val final = synchronized(lock) { buffer.toByteArray() }

        assertTrue(snapshot.size % 4 == 0)
        assertEquals(400, final.size)
        assertArrayEquals(snapshot, final.copyOf(snapshot.size))
    }
}
