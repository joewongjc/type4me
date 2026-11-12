package com.type4me.android.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyRepeatTimingTest {
    @Test
    fun startsAtInitialInterval() {
        assertEquals(250L, KeyRepeatTiming.interval(0))
    }

    @Test
    fun decreasesLinearly() {
        assertEquals(175L, KeyRepeatTiming.interval(1_000))
    }

    @Test
    fun reachesMinimumAtEndOfRamp() {
        assertEquals(100L, KeyRepeatTiming.interval(KeyRepeatTiming.RAMP_MS))
    }

    @Test
    fun staysAtMinimumAfterRamp() {
        assertEquals(100L, KeyRepeatTiming.interval(60_000))
    }

    @Test
    fun neverGetsSlower() {
        var previous = KeyRepeatTiming.interval(0)
        for (elapsed in 25L..3_000L step 25) {
            val current = KeyRepeatTiming.interval(elapsed)
            assertTrue(current <= previous)
            previous = current
        }
    }
}
