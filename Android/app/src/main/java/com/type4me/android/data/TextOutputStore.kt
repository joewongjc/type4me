package com.type4me.android.data

import android.content.Context

enum class CjkSpacing {
    PANGU,
    KEEP,
    REMOVE,
}

enum class TrailingPunctuation {
    KEEP,
    PERIOD,
    ALL,
}

/** Text cleanup shared by every dictation, applied just before insertion. */
object TextOutputStore {
    private const val PREFS = "type4me_prefs"
    private const val KEY_SPACING = "text.spacing"
    private const val KEY_PUNCTUATION = "text.punctuation"
    private const val KEY_CORNER_QUOTES = "text.cornerQuotes"

    fun spacing(context: Context): CjkSpacing =
        CjkSpacing.entries.firstOrNull {
            it.name == prefs(context).getString(KEY_SPACING, null)
        } ?: CjkSpacing.PANGU

    fun setSpacing(context: Context, mode: CjkSpacing) {
        prefs(context).edit().putString(KEY_SPACING, mode.name).apply()
    }

    fun punctuation(context: Context): TrailingPunctuation =
        TrailingPunctuation.entries.firstOrNull {
            it.name == prefs(context).getString(KEY_PUNCTUATION, null)
        } ?: TrailingPunctuation.KEEP

    fun setPunctuation(context: Context, mode: TrailingPunctuation) {
        prefs(context).edit().putString(KEY_PUNCTUATION, mode.name).apply()
    }

    fun cornerQuotes(context: Context): Boolean =
        prefs(context).getBoolean(KEY_CORNER_QUOTES, false)

    fun setCornerQuotes(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_CORNER_QUOTES, enabled).apply()
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
