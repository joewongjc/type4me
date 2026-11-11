package com.type4me.android.ime

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View
import android.view.animation.LinearInterpolator
import androidx.core.graphics.PathParser
import kotlin.math.min

/**
 * The keyboard microphone, including a quiet voice-level fill inside the
 * microphone capsule. Geometry is identical in idle and listening states;
 * only palette and the capsule's liquid level change.
 */
class RecordingMicView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val sourceMicPath = PathParser.createPathFromPathData(MIC_PATH_DATA)
    private val micPath = Path()
    private val capsuleBounds = RectF()
    private val transform = Matrix()
    private val clipPath = Path()
    private val wavePath = Path()
    private var geometrySize = 0f

    private var animator: ValueAnimator? = null
    private var targetLevel = 0f
    private var level = 0f
    private var elapsed = 0f
    private var lastFrameNanos = 0L

    var idleTint: Int = Color.BLACK
        set(value) {
            field = value
            invalidate()
        }

    var activeTint: Int = Color.BLUE
        set(value) {
            field = value
            invalidate()
        }

    /** Overrides the idle tint for non-recording states such as processing. */
    var iconTint: Int? = null
        set(value) {
            field = value
            invalidate()
        }

    var levelFillColor: Int = Color.CYAN
        set(value) {
            field = value
            invalidate()
        }

    /** The empty capsule surface shown while voice-level fill is animating. */
    var capsuleSurfaceColor: Int = Color.TRANSPARENT
        set(value) {
            field = value
            invalidate()
        }

    fun setLevel(value: Float) {
        // The raw meter already applies gain. A small perceptual curve makes
        // quiet speech produce a visible fill without making loud syllables
        // jump immediately from empty to full.
        targetLevel = kotlin.math.sqrt(value.coerceIn(0f, 1f))
        if (animator == null) {
            level = targetLevel
            invalidate()
        }
    }

    fun start() {
        if (animator != null) return
        targetLevel = 0f
        level = 0f
        elapsed = 0f
        lastFrameNanos = 0L
        if (!ValueAnimator.areAnimatorsEnabled()) {
            invalidate()
            return
        }
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = LOOP_DURATION_MS
            repeatCount = ValueAnimator.INFINITE
            interpolator = LinearInterpolator()
            addUpdateListener {
                val now = System.nanoTime()
                val dt = if (lastFrameNanos == 0L) {
                    0f
                } else {
                    ((now - lastFrameNanos) / 1_000_000_000.0)
                        .toFloat()
                        .coerceIn(0f, 0.05f)
                }
                lastFrameNanos = now
                level += (targetLevel - level) * min(1f, dt * LEVEL_FOLLOW_RATE)
                elapsed += dt
                invalidate()
            }
            start()
        }
    }

    fun stop() {
        animator?.cancel()
        animator = null
        targetLevel = 0f
        level = 0f
        elapsed = 0f
        lastFrameNanos = 0L
        invalidate()
    }

    override fun onDetachedFromWindow() {
        stop()
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        val size = min(width, height).toFloat()
        if (size <= 0f) return
        buildGeometry(size)

        val active = animator != null
        fillPaint.color = if (active) activeTint else (iconTint ?: idleTint)
        // The supplied SVG is a filled compound path, not a collection of
        // approximated strokes. Drawing that parsed path preserves its exact
        // capsule-to-stand proportions at every icon size.
        canvas.drawPath(micPath, fillPaint)
        if (active) paintCapsuleLevel(canvas)
    }

    private fun buildGeometry(size: Float) {
        if (size == geometrySize) return
        geometrySize = size
        transform.reset()
        val scale = size / SVG_VIEWPORT
        transform.setScale(scale, scale)
        micPath.reset()
        sourceMicPath.transform(transform, micPath)
        capsuleBounds.set(
            size * CAPSULE_LEFT,
            size * CAPSULE_TOP,
            size * CAPSULE_RIGHT,
            size * CAPSULE_BOTTOM,
        )
    }

    private fun paintCapsuleLevel(canvas: Canvas) {
        val inset = capsuleBounds.width() * CAPSULE_INSET
        val inner = RectF(capsuleBounds).apply { inset(inset, inset) }
        clipPath.reset()
        clipPath.addRoundRect(
            inner,
            inner.width() / 2f,
            inner.width() / 2f,
            Path.Direction.CW,
        )

        // Keep the capsule open as a coloured surface, then fill it from the
        // bottom according to the live voice meter.
        fillPaint.color = capsuleSurfaceColor
        canvas.drawPath(clipPath, fillPaint)
        if (level <= 0.002f) return

        val fillHeight = inner.height() * level.coerceIn(0f, 1f)
        val surface = inner.bottom - fillHeight
        canvas.save()
        canvas.clipPath(clipPath)

        wavePath.reset()
        wavePath.moveTo(inner.left, surface)
        val wobble = inner.width() * 0.035f
        val half = 8
        for (index in 0..half) {
            val fraction = index / half.toFloat()
            val x = inner.left + inner.width() * fraction
            val y = surface +
                kotlin.math.sin(elapsed * 4f + fraction * Math.PI.toFloat() * 2f) * wobble
            wavePath.lineTo(x, y)
        }
        wavePath.lineTo(inner.right, inner.bottom)
        wavePath.lineTo(inner.left, inner.bottom)
        wavePath.close()
        fillPaint.color = levelFillColor
        canvas.drawPath(wavePath, fillPaint)
        canvas.restore()
    }

    private companion object {
        const val LOOP_DURATION_MS = 4_000L
        const val LEVEL_FOLLOW_RATE = 14f
        const val SVG_VIEWPORT = 1024f

        // Exact normalized bounds of the capsule in the supplied SVG.
        const val CAPSULE_LEFT = 354.917f / SVG_VIEWPORT
        const val CAPSULE_TOP = 70.5f / SVG_VIEWPORT
        const val CAPSULE_RIGHT = 668.584f / SVG_VIEWPORT
        const val CAPSULE_BOTTOM = 655.807f / SVG_VIEWPORT
        const val CAPSULE_INSET = 0.12f

        const val MIC_PATH_DATA =
            "M511.752 70.5c-86.605 0-156.835 69.734-156.835 155.747l0 273.812" +
                "c0 86.013 70.23 155.748 156.835 155.748 86.602 0 156.832-69.735 " +
                "156.832-155.748L668.584 226.247C668.584 140.234 598.354 70.5 " +
                "511.752 70.5L511.752 70.5 511.752 70.5zM243.854 461.102c-18.051 " +
                "0-32.649 14.496-32.649 32.451 0 2.269 0.197 4.436 0.689 6.506l-0.689 " +
                "0c0 151.605 113.922 276.578 261.386 295.713l0 80.687-52.275 0" +
                "c-21.702 0-39.257 17.458-39.257 38.964 0 21.499 17.555 38.957 " +
                "39.257 38.957l182.969 0c21.701 0 39.256-17.458 39.256-38.957 " +
                "0-21.506-17.555-38.964-39.256-38.964L551.01 876.459l0-80.687" +
                "c143.119-18.543 254.383-137.002 260.691-282.688 0.396-2.072 " +
                "0.695-4.243 0.695-6.512 0-0.79-0.197-1.479-0.197-2.167 " +
                "0-1.483 0.197-2.86 0.197-4.345l-0.695 0c-3.058-14.795-16.172-25.94" +
                "-32.057-25.94-15.782 0-28.999 11.145-32.057 25.94l-0.688 0" +
                "c0 129.019-105.344 233.572-235.249 233.572-129.903 " +
                "0-235.249-104.554-235.249-233.572l-0.689 0c0.396-2.07 " +
                "0.689-4.237 0.689-6.506C276.503 475.598 261.906 461.102 " +
                "243.854 461.102L243.854 461.102 243.854 461.102z"
    }
}
