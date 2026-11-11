package com.type4me.android.ime

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.util.AttributeSet
import android.view.Gravity
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import com.type4me.android.R

/**
 * The two keys either side of the microphone: icon over a short label.
 * Recording swaps their contents for cancel, lock and done.
 */
class SideKeyView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : LinearLayout(context, attrs) {

    private val icon = ImageView(context)
    private val label = TextView(context)

    init {
        orientation = VERTICAL
        gravity = Gravity.CENTER
        isClickable = true
        isFocusable = true
        setBackgroundResource(R.drawable.side_key_background)
        elevation = dp(2).toFloat()

        icon.imageTintList = ColorStateList.valueOf(color(R.color.key_text))
        addView(icon, LayoutParams(dp(21), dp(21)))

        label.apply {
            textSize = 11f
            typeface = Typeface.create("sans-serif", Typeface.NORMAL)
            letterSpacing = 0.01f
            gravity = Gravity.CENTER
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            setTextColor(color(R.color.key_text))
            includeFontPadding = false
        }
        addView(label, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(3)
        })
    }

    fun setContent(iconRes: Int, labelRes: Int) {
        setContent(iconRes, context.getString(labelRes))
    }

    fun setContent(iconRes: Int, text: String) {
        icon.setImageResource(iconRes)
        label.text = text
        contentDescription = text
    }

    fun setEnabledState(enabled: Boolean) {
        isEnabled = enabled
        alpha = if (enabled) 1f else 0.32f
    }

    fun setDanger(active: Boolean) {
        setBackgroundResource(if (active) R.drawable.side_key_armed else R.drawable.side_key_background)
        val tint = if (active) Color.WHITE else color(R.color.key_text)
        icon.imageTintList = ColorStateList.valueOf(tint)
        label.setTextColor(tint)
    }

    private fun color(id: Int): Int = ContextCompat.getColor(context, id)

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
