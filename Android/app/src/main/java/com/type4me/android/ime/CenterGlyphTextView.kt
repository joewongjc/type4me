package com.type4me.android.ime

import android.content.Context
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.util.AttributeSet
import androidx.appcompat.widget.AppCompatTextView
import androidx.core.content.ContextCompat

/** A text key that can draw one glyph in the exact center of the key. */
class CenterGlyphTextView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : AppCompatTextView(context, attrs) {

    private var glyph: Drawable? = null
    private var glyphSize = 0

    fun showGlyph(drawableRes: Int, size: Int, tint: Int) {
        glyph = ContextCompat.getDrawable(context, drawableRes)?.mutate()?.apply {
            setTint(tint)
        }
        glyphSize = size
        invalidate()
    }

    fun clearGlyph() {
        if (glyph == null) return
        glyph = null
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val drawable = glyph ?: return
        val left = (width - glyphSize) / 2
        val top = (height - glyphSize) / 2
        drawable.setBounds(left, top, left + glyphSize, top + glyphSize)
        drawable.draw(canvas)
    }
}
