package com.type4me.android.pipeline

import android.content.Context
import com.type4me.android.R

/** A built-in mode kind. Custom modes carry their own prompt and name. */
enum class Mode {
    INTELLI_SENSE,
    QUICK,
    POLISH,
    TRANSLATE,
    AGENT,
    CUSTOM;

    fun label(context: Context): String = context.getString(
        when (this) {
            INTELLI_SENSE -> R.string.mode_intelli_sense
            QUICK -> R.string.mode_quick
            POLISH -> R.string.mode_polish
            TRANSLATE -> R.string.mode_translate
            AGENT -> R.string.mode_agent
            CUSTOM -> R.string.mode_custom
        },
    )

    val usesTextModel: Boolean get() = this != QUICK

    companion object {
        /** Legacy order, used when migrating the old fixed mode list. */
        val keyboardOrder: List<Mode> = listOf(INTELLI_SENSE, QUICK, TRANSLATE, AGENT, POLISH)
    }
}

enum class ModePunctuation {
    INHERIT,
    PRESERVE,
    STRIP_TRAILING,
    QUESTIONS_AND_EXCLAMATIONS,
    REMOVE_ALL,
}
