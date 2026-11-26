package com.type4me.android.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.RenderEffect
import android.graphics.RenderNode
import android.graphics.Shader
import android.os.Build
import android.util.AttributeSet
import android.view.View
import android.view.ViewOutlineProvider
import android.view.ViewTreeObserver
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import com.type4me.android.R

/**
 * Renders the part of [sourceView] behind this view as a clipped Gaussian
 * blur, giving a floating surface a frosted-glass finish. Android 12+ draws
 * the real blur; older releases keep the opaque surface rendered underneath.
 */
class BackdropBlurView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : View(context, attrs, defStyleAttr) {

    var sourceView: View? = null
        set(value) {
            if (field === value) return
            field?.removeOnLayoutChangeListener(sourceLayoutListener)
            field = value
            value?.addOnLayoutChangeListener(sourceLayoutListener)
            invalidate()
        }

    private val blurRadius = 20f * resources.displayMetrics.density
    private val tintColor = ContextCompat.getColor(context, R.color.tab_bar_glass_tint)
    private val borderColor = ContextCompat.getColor(context, R.color.tab_bar_glass_border)
    private val borderWidth = 1.1f * resources.displayMetrics.density
    private val tintPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = borderWidth
    }

    private val blurRenderer: Any? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) BlurRenderer(this) else null

    private val sourceLayoutListener = OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
        invalidate()
    }
    private val scrollListener = ViewTreeObserver.OnScrollChangedListener { invalidate() }
    private val layoutListener = ViewTreeObserver.OnGlobalLayoutListener { invalidate() }

    init {
        outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                outline.setRoundRect(0, 0, view.width, view.height, view.height / 2f)
            }
        }
        clipToOutline = true
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        viewTreeObserver.addOnScrollChangedListener(scrollListener)
        viewTreeObserver.addOnGlobalLayoutListener(layoutListener)
        sourceView?.addOnLayoutChangeListener(sourceLayoutListener)
    }

    override fun onDetachedFromWindow() {
        viewTreeObserver.removeOnScrollChangedListener(scrollListener)
        viewTreeObserver.removeOnGlobalLayoutListener(layoutListener)
        sourceView?.removeOnLayoutChangeListener(sourceLayoutListener)
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (width == 0 || height == 0) return

        val blurred = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (blurRenderer as? BlurRenderer)?.draw(canvas) == true
        } else {
            false
        }
        if (blurred) {
            tintPaint.color = tintColor
            canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), tintPaint)

            borderPaint.color = borderColor
            val inset = borderWidth / 2f
            val radius = height / 2f
            canvas.drawRoundRect(
                inset,
                inset,
                width - inset,
                height - inset,
                radius,
                radius,
                borderPaint,
            )
        }
    }

    /**
     * Kept in a separate class so devices below API 31 never load RenderNode
     * or RenderEffect when the view class is initialized.
     */
    @RequiresApi(Build.VERSION_CODES.S)
    private class BlurRenderer(private val host: BackdropBlurView) {
        private val renderNode = RenderNode("tabBarBackdrop").apply {
            setRenderEffect(
                RenderEffect.createBlurEffect(
                    host.blurRadius,
                    host.blurRadius,
                    Shader.TileMode.CLAMP,
                ),
            )
        }
        private val sourceLocation = IntArray(2)
        private val hostLocation = IntArray(2)

        fun draw(canvas: Canvas): Boolean {
            val source = host.sourceView ?: return false
            if (source.width == 0 || source.height == 0) return false
            if (!host.isHardwareAccelerated || !source.isHardwareAccelerated) return false

            source.getLocationInWindow(sourceLocation)
            host.getLocationInWindow(hostLocation)
            val dx = (sourceLocation[0] - hostLocation[0]).toFloat()
            val dy = (sourceLocation[1] - hostLocation[1]).toFloat()
            val padding = (host.blurRadius * 2f).toInt()
            val nodeWidth = host.width + padding * 2
            val nodeHeight = host.height + padding * 2

            renderNode.setPosition(0, 0, nodeWidth, nodeHeight)
            val recording = renderNode.beginRecording()
            recording.translate(padding + dx, padding + dy)
            source.draw(recording)
            renderNode.endRecording()

            canvas.save()
            canvas.translate(-padding.toFloat(), -padding.toFloat())
            canvas.drawRenderNode(renderNode)
            canvas.restore()
            return true
        }
    }
}
