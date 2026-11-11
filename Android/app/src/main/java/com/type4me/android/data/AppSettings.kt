package com.type4me.android.data

import android.content.Context

/** Small preferences that only affect how the keyboard and app behave. */
object AppSettings {
    private const val PREFS = "type4me_prefs"
    private const val KEY_HAPTICS = "key.haptics"
    private const val KEY_SOUNDS = "key.sounds"
    private const val KEY_CLIPBOARD = "keyboard.clipboard"
    private const val KEY_FULL_WIDTH = "keyboard.fullWidthPunctuation"
    private const val KEY_FIELD_CONTEXT = "field.context"
    private const val KEY_AI_CONSENT = "ai.consent"
    private const val KEY_LANGUAGE = "app.language"
    private const val KEY_ONBOARDED = "app.onboarded"

    fun keyHaptics(context: Context): Boolean =
        prefs(context).getBoolean(KEY_HAPTICS, true)

    fun setKeyHaptics(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_HAPTICS, enabled).apply()
    }

    fun keySounds(context: Context): Boolean =
        prefs(context).getBoolean(KEY_SOUNDS, true)

    fun setKeySounds(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_SOUNDS, enabled).apply()
    }

    fun keyboardClipboard(context: Context): Boolean =
        prefs(context).getBoolean(KEY_CLIPBOARD, true)

    fun setKeyboardClipboard(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_CLIPBOARD, enabled).apply()
    }

    fun fullWidthPunctuation(context: Context): Boolean =
        prefs(context).getBoolean(
            KEY_FULL_WIDTH,
            context.resources.configuration.locales[0].language == "zh",
        )

    fun setFullWidthPunctuation(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_FULL_WIDTH, enabled).apply()
    }

    fun fieldContext(context: Context): Boolean =
        prefs(context).getBoolean(KEY_FIELD_CONTEXT, true)

    fun setFieldContext(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_FIELD_CONTEXT, enabled).apply()
    }

    fun aiConsent(context: Context): Boolean =
        prefs(context).getBoolean(KEY_AI_CONSENT, false)

    fun setAiConsent(context: Context, agreed: Boolean) {
        prefs(context).edit().putBoolean(KEY_AI_CONSENT, agreed).apply()
    }

    /** "system", "zh" or "en". */
    fun language(context: Context): String =
        prefs(context).getString(KEY_LANGUAGE, "system").orEmpty()

    fun setLanguage(context: Context, language: String) {
        prefs(context).edit().putString(KEY_LANGUAGE, language).apply()
    }

    fun onboarded(context: Context): Boolean =
        prefs(context).getBoolean(KEY_ONBOARDED, false)

    fun setOnboarded(context: Context, done: Boolean) {
        prefs(context).edit().putBoolean(KEY_ONBOARDED, done).apply()
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
