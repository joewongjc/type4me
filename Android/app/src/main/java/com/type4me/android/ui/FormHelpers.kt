package com.type4me.android.ui

import android.view.View
import android.widget.TextView
import androidx.core.content.ContextCompat
import com.type4me.android.R

fun formText(view: TextView): String = view.text?.toString()?.trim().orEmpty()

fun showFormResult(result: TextView, message: String, error: Boolean) {
    result.visibility = View.VISIBLE
    result.text = message
    result.setTextColor(
        ContextCompat.getColor(
            result.context,
            if (error) R.color.brand_red else R.color.success,
        ),
    )
}

fun shortError(error: Throwable): String =
    (error.message ?: error.javaClass.simpleName).take(160)
