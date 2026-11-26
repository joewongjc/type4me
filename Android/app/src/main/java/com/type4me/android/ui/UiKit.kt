package com.type4me.android.ui

import android.content.Context
import android.view.View
import android.view.ViewGroup
import androidx.annotation.ColorRes
import androidx.core.content.ContextCompat
import androidx.core.view.updateLayoutParams
import androidx.core.view.updatePadding

private const val NAV_BAR_HEIGHT_DP = 56

fun Context.dp(value: Float): Int = (value * resources.displayMetrics.density).toInt()

fun Context.dp(value: Int): Int = dp(value.toFloat())

fun Context.color(@ColorRes id: Int): Int = ContextCompat.getColor(this, id)

fun View.color(@ColorRes id: Int): Int = context.color(id)

/**
 * Puts the status-bar inset above a second-level page's bar and grows the bar by the same
 * amount, so the title keeps NAV_BAR_HEIGHT_DP of room instead of being squeezed by the inset.
 */
fun View.applyNavBarTopInset(topInset: Int) {
    updatePadding(top = topInset)
    updateLayoutParams<ViewGroup.LayoutParams> { height = topInset + context.dp(NAV_BAR_HEIGHT_DP) }
}
