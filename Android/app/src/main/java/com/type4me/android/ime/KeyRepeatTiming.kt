package com.type4me.android.ime

/**
 * Interval between auto-repeat actions while a key is held. The interval
 * starts at [INITIAL_INTERVAL_MS] and shortens linearly over [RAMP_MS],
 * then stays at [MINIMUM_INTERVAL_MS].
 */
internal object KeyRepeatTiming {
    const val INITIAL_INTERVAL_MS = 250L
    const val MINIMUM_INTERVAL_MS = 100L
    const val RAMP_MS = 2_000L

    fun interval(elapsedMs: Long): Long {
        val progress = elapsedMs.coerceIn(0L, RAMP_MS)
        val span = INITIAL_INTERVAL_MS - MINIMUM_INTERVAL_MS
        return (INITIAL_INTERVAL_MS - span * progress / RAMP_MS)
            .coerceAtLeast(MINIMUM_INTERVAL_MS)
    }
}
