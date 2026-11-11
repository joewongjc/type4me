package com.type4me.android.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.drawable.Drawable
import androidx.core.content.ContextCompat
import com.type4me.android.R

/**
 * The Mac Home canvas: a faint dot grid behind the cards. Drawn on demand in
 * screen space so it stays crisp and needs no bitmap asset.
 */
class DotGridDrawable(context: Context) : Drawable() {

    private val density = context.resources.displayMetrics.density
    private val step = 11f * density
    private val radius = 0.75f * density
    private val background = ContextCompat.getColor(context, R.color.screen_bg)
    private val dotColor = ContextCompat.getColor(context, R.color.ink)

    private val backgroundPaint = Paint().apply { color = background }
    private val dotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = dotColor
        alpha = 20
    }

    override fun draw(canvas: Canvas) {
        canvas.drawRect(bounds, backgroundPaint)
        val startX = bounds.left + step / 2
        val startY = bounds.top + step / 2
        var y = startY
        while (y < bounds.bottom) {
            var x = startX
            while (x < bounds.right) {
                canvas.drawCircle(x, y, radius, dotPaint)
                x += step
            }
            y += step
        }
    }

    override fun setAlpha(alpha: Int) = Unit

    override fun setColorFilter(colorFilter: ColorFilter?) = Unit

    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
}
