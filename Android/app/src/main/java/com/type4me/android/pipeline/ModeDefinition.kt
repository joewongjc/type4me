package com.type4me.android.pipeline

import android.content.Context
import com.type4me.android.R
import org.json.JSONObject

/**
 * One mode in the user's library. Built-in modes keep their prompt in code
 * until the user edits it; custom modes always carry their own.
 */
data class ModeDefinition(
    val id: String,
    val kind: Mode,
    val name: String? = null,
    val prompt: String = "",
    val onKeyboard: Boolean = true,
    val translateTarget: String? = null,
    val punctuation: ModePunctuation = ModePunctuation.INHERIT,
    val shortTextExemption: Int = 0,
) {
    val usesTextModel: Boolean get() = kind != Mode.QUICK
    val isBuiltIn: Boolean get() = kind != Mode.CUSTOM
    val translationTarget: TranslateTarget
        get() = translateTarget?.let { TranslateTarget.byCode(it) } ?: TranslateTarget.ENGLISH

    fun label(context: Context): String {
        val custom = name?.trim().orEmpty()
        if (custom.isNotEmpty()) return custom
        if (kind == Mode.TRANSLATE) {
            return context.getString(R.string.mode_translate) + " · " +
                translationTarget.shortTag(context)
        }
        return kind.label(context)
    }

    fun summary(context: Context): String = when (kind) {
        Mode.INTELLI_SENSE -> context.getString(R.string.mode_summary_intelli)
        Mode.QUICK -> context.getString(R.string.mode_summary_quick)
        Mode.POLISH -> context.getString(R.string.mode_summary_polish)
        Mode.TRANSLATE -> context.getString(
            R.string.mode_summary_translate,
            translationTarget.label(context),
        )
        Mode.AGENT -> context.getString(R.string.mode_summary_agent)
        Mode.CUSTOM -> prompt.lineSequence().firstOrNull()?.take(80)
            ?: context.getString(R.string.mode_summary_custom)
    }

    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("kind", kind.name)
        .put("name", name ?: JSONObject.NULL)
        .put("prompt", prompt)
        .put("onKeyboard", onKeyboard)
        .put("translateTarget", translateTarget ?: JSONObject.NULL)
        .put("punctuation", punctuation.name)
        .put("shortTextExemption", shortTextExemption)

    companion object {
        fun builtIn(kind: Mode, onKeyboard: Boolean = true): ModeDefinition =
            ModeDefinition(
                id = kind.name,
                kind = kind,
                onKeyboard = onKeyboard,
            )

        fun fromJson(json: JSONObject): ModeDefinition? {
            val kind = runCatching { Mode.valueOf(json.optString("kind")) }.getOrNull() ?: return null
            val id = json.optString("id").takeIf { it.isNotBlank() } ?: kind.name
            return ModeDefinition(
                id = id,
                kind = kind,
                name = json.optStringOrNull("name"),
                prompt = json.optString("prompt"),
                onKeyboard = json.optBoolean("onKeyboard", true),
                translateTarget = json.optStringOrNull("translateTarget"),
                punctuation = runCatching {
                    ModePunctuation.valueOf(json.optString("punctuation"))
                }.getOrDefault(ModePunctuation.INHERIT),
                shortTextExemption = json.optInt("shortTextExemption", 0),
            )
        }

        private fun JSONObject.optStringOrNull(key: String): String? {
            if (!has(key) || isNull(key)) return null
            return optString(key).takeIf { it.isNotBlank() && it != "null" }
        }
    }
}
