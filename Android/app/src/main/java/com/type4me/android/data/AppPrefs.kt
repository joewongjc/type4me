package com.type4me.android.data

import android.content.Context
import android.content.SharedPreferences

internal object AppPrefs {
    private const val NAME = "type4me_prefs"

    fun get(context: Context): SharedPreferences =
        context.getSharedPreferences(NAME, Context.MODE_PRIVATE)
}
