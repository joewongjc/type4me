package com.type4me.android.ui

import android.content.Context
import android.content.res.ColorStateList
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.TextView
import androidx.annotation.StringRes
import androidx.appcompat.widget.AppCompatImageButton
import androidx.core.content.ContextCompat
import com.type4me.android.R

/** The second-level page bar: a back button and one title. */
fun Context.pageToolbar(title: CharSequence, onBack: () -> Unit): LinearLayout =
    LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(4), 0, dp(12), 0)
        addView(
            AppCompatImageButton(this@pageToolbar).apply {
                val ripple = android.util.TypedValue()
                this@pageToolbar.theme.resolveAttribute(
                    android.R.attr.selectableItemBackgroundBorderless,
                    ripple,
                    true,
                )
                setBackgroundResource(ripple.resourceId)
                setImageResource(R.drawable.ic_back)
                setPadding(dp(10), dp(10), dp(10), dp(10))
                imageTintList = ColorStateList.valueOf(
                    ContextCompat.getColor(this@pageToolbar, R.color.ink),
                )
                contentDescription = getString(R.string.back)
                setOnClickListener { onBack() }
            },
            LinearLayout.LayoutParams(dp(48), dp(56)),
        )
        addView(
            TextView(this@pageToolbar).apply {
                text = title
                textSize = 18f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(color(R.color.ink))
                gravity = Gravity.CENTER_VERTICAL
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
            },
            LinearLayout.LayoutParams(0, dp(56), 1f),
        )
    }

fun Context.pageToolbar(@StringRes title: Int, onBack: () -> Unit): LinearLayout =
    pageToolbar(getString(title), onBack)
