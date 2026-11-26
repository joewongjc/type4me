package com.type4me.android.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MediaVolumeDuckingTest {
    @Test
    fun mutesMediaWhileRecording() {
        assertEquals(0, MediaVolumeDucking.duckedLevel(15, 15))
        assertEquals(0, MediaVolumeDucking.duckedLevel(1, 10))
    }

    @Test
    fun leavesAlreadySilentOrInvalidLevelsAlone() {
        assertNull(MediaVolumeDucking.duckedLevel(0, 15))
        assertNull(MediaVolumeDucking.duckedLevel(5, 0))
        assertNull(MediaVolumeDucking.duckedLevel(-1, 15))
    }
}
