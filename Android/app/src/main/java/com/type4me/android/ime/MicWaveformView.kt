package com.type4me.android.ime

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.View
import android.view.animation.LinearInterpolator
import kotlin.math.PI
import kotlin.math.sin

/**
 * A compact live waveform shown inside the mic while recording. Four bars
 * breathe with a travelling phase and grow with the input level, which is
 * enough to read as "listening" without drawing a real spectrogram.
 */
class MicWaveformView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.FILL
    }
    private var level = 0f
    private var phase = 0f
    private var animator: ValueAnimator? = null

    fun setLevel(value: Float) {
        level = value.coerceIn(0f, 1f)
    }

    fun start() {
        if (animator != null) return
        animator = ValueAnimator.ofFloat(0f, (2 * PI).toFloat()).apply {
            duration = 900
            repeatCount = ValueAnimator.INFINITE
            interpolator = LinearInterpolator()
            addUpdateListener { animation ->
                phase = animation.animatedValue as Float
                invalidate()
            }
            start()
        }
    }

    fun stop() {
        animator?.cancel()
        animator = null
        phase = 0f
        level = 0f
        invalidate()
    }

    override fun onDetachedFromWindow() {
        stop()
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        val width = width.toFloat()
        val height = height.toFloat()
        if (width <= 0f || height <= 0f) return

        val gap = width * 0.16f
        val barWidth = (width - gap * (BAR_COUNT - 1)) / BAR_COUNT
        val radius = barWidth / 2f
        // Even silence keeps a soft pulse; louder speech makes the bars taller.
        val scale = 0.35f + 0.65f * level
        for (index in 0 until BAR_COUNT) {
            val swing = 0.5f + 0.5f * sin(phase + index * 1.1f)
            val barHeight = height * (0.18f + 0.62f * swing * scale)
            val left = index * (barWidth + gap)
            val top = (height - barHeight) / 2f
            canvas.drawRoundRect(left, top, left + barWidth, top + barHeight, radius, radius, paint)
        }
    }

    private companion object {
        const val BAR_COUNT = 4
    }
}
