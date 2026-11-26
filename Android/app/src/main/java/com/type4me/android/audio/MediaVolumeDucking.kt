package com.type4me.android.audio

/** Decides the media stream level during dictation, without Android framework types. */
internal object MediaVolumeDucking {
    /** Mutes media while recording; returns null when it is already silent. */
    fun duckedLevel(current: Int, max: Int): Int? {
        if (max <= 0 || current <= 0) return null
        return 0
    }
}
