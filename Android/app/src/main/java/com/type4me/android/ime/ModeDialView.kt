package com.type4me.android.ime

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.Configuration
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.TextUtils
import android.util.AttributeSet
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import com.type4me.android.R
import com.type4me.android.pipeline.ModeDefinition

/**
 * The iOS mode dial in native Android views. The capsule selection frame is a
 * fixed child of this FrameLayout; only the inner scroller and its row move.
 * Names scroll under the frame, the nearest name is highlighted, and the dial
 * snaps to it when a real touch scroll settles.
 */
// The touch listener only observes scrolling; the chips handle their own clicks.
@SuppressLint("ClickableViewAccessibility")
class ModeDialView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : FrameLayout(context, attrs) {

    interface Listener {
        fun onModeSelected(mode: ModeDefinition)
        fun onUnavailableMode()
    }

    var listener: Listener? = null

    /** Fires once for every mode the dial passes, like a physical knob detent. */
    var onDetent: (() -> Unit)? = null

    private val scroller = HorizontalScrollView(context)
    private val row = LinearLayout(context)
    private val chips = linkedMapOf<ModeDefinition, TextView>()
    private val settleHandler = Handler(Looper.getMainLooper())

    private var centered: ModeDefinition? = null
    private var committed: ModeDefinition? = null
    private var hasTextModel = true
    private var needsCenter = true
    private var programmaticScroll = false
    private var scrollToken = 0
    private var lastTouchAt = 0L
    private var tickedModeId: String? = null
    private val regularTypeface by lazy { Typeface.create("sans-serif", Typeface.NORMAL) }

    private val settle = Runnable { commitNearest() }

    private val centerAfterRowLayout = object : View.OnLayoutChangeListener {
        override fun onLayoutChange(
            v: View,
            left: Int,
            top: Int,
            right: Int,
            bottom: Int,
            oldLeft: Int,
            oldTop: Int,
            oldRight: Int,
            oldBottom: Int,
        ) {
            v.removeOnLayoutChangeListener(this)
            centerWhenReady()
        }
    }

    init {
        scroller.apply {
            isHorizontalScrollBarEnabled = false
            isFillViewport = false
            isHorizontalFadingEdgeEnabled = true
            setFadingEdgeLength(dp(22))
            overScrollMode = OVER_SCROLL_NEVER
            clipToPadding = false
        }
        row.orientation = LinearLayout.HORIZONTAL
        row.gravity = Gravity.CENTER_VERTICAL
        scroller.addView(
            row,
            LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT),
        )

        // Added first so the names draw over the frame, not under it.
        val frameHeight = dp(28)
        val pill = View(context).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = frameHeight / 2f
                setColor(ContextCompat.getColor(context, R.color.dial_selected))
                setStroke(dp(1), ContextCompat.getColor(context, R.color.divider))
            }
            isClickable = false
            isFocusable = false
        }
        addView(pill, LayoutParams(dp(92), frameHeight, Gravity.CENTER))
        addView(scroller, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))

        scroller.setOnScrollChangeListener { _, _, _, _, _ ->
            if (programmaticScroll) return@setOnScrollChangeListener
            // Layout and programmatic centring move the offset too. Only a
            // scroll that follows a real touch may change the mode.
            if (SystemClock.uptimeMillis() - lastTouchAt > TOUCH_WINDOW_MS) {
                return@setOnScrollChangeListener
            }
            highlightNearest()
            scheduleSettle()
        }
        scroller.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP,
                MotionEvent.ACTION_CANCEL -> lastTouchAt = SystemClock.uptimeMillis()
            }
            if (event.actionMasked == MotionEvent.ACTION_DOWN ||
                event.actionMasked == MotionEvent.ACTION_MOVE
            ) {
                programmaticScroll = false
                settleHandler.removeCallbacks(settle)
            }
            false
        }
    }

    fun setModes(modes: List<ModeDefinition>, mode: ModeDefinition, textModelAvailable: Boolean) {
        settleHandler.removeCallbacks(settle)
        hasTextModel = textModelAvailable
        tickedModeId = null
        chips.clear()
        row.removeAllViews()
        row.setPadding(0, 0, 0, 0)
        needsCenter = true
        scroller.scrollTo(0, 0)

        modes.forEach { candidate ->
            val chip = TextView(context).apply {
                text = candidate.label(context)
                textSize = 14f
                typeface = regularTypeface
                letterSpacing = 0.01f
                gravity = Gravity.CENTER
                includeFontPadding = false
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
                maxWidth = dp(88)
                minWidth = dp(54)
                setPadding(dp(11), 0, dp(11), 0)
                setBackgroundResource(R.drawable.dial_chip)
                contentDescription = context.getString(R.string.kb_mode, text)
                setOnClickListener { choose(candidate) }
            }
            row.addView(
                chip,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    dp(if (compact) 30 else 32),
                ),
            )
            chips[candidate] = chip
        }

        centered = mode
        committed = mode
        paint(mode)
        requestLayout()
        // The row may need one more layout pass after its end padding is
        // applied. Re-centre late, unless a real touch has taken over.
        postDelayed({
            if (SystemClock.uptimeMillis() - lastTouchAt > TOUCH_WINDOW_MS) {
                needsCenter = false
                centerSelected(animated = false)
            }
        }, 80)
    }

    fun select(mode: ModeDefinition, notify: Boolean = true) {
        centered = mode
        committed = mode
        // A new selection re-arms the detents, so the next drag always ticks.
        tickedModeId = null
        paint(mode)
        post { centerSelected(animated = true) }
        if (notify) listener?.onModeSelected(mode)
    }

    private fun choose(mode: ModeDefinition) {
        if (mode.usesTextModel && !hasTextModel) {
            listener?.onUnavailableMode()
            return
        }
        if (committed?.id == mode.id) {
            post { centerSelected(animated = true) }
            return
        }
        tick(mode)
        select(mode)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        super.onLayout(changed, l, t, r, b)
        if (updateRowPadding()) {
            needsCenter = true
            row.removeOnLayoutChangeListener(centerAfterRowLayout)
            row.addOnLayoutChangeListener(centerAfterRowLayout)
            return
        }
        if (needsCenter && !programmaticScroll) {
            needsCenter = false
            post { centerSelected(animated = false) }
        }
    }

    override fun onDetachedFromWindow() {
        settleHandler.removeCallbacks(settle)
        super.onDetachedFromWindow()
    }

    /** True when the row padding had to grow or shrink for the end names. */
    private fun updateRowPadding(): Boolean {
        val width = scroller.width
        if (width == 0) return false
        val first = chips.values.firstOrNull()?.width ?: 0
        val last = chips.values.lastOrNull()?.width ?: 0
        val left = ((width - first) / 2).coerceAtLeast(0)
        val right = ((width - last) / 2).coerceAtLeast(0)
        if (row.paddingLeft == left && row.paddingRight == right) return false
        row.setPadding(left, 0, right, 0)
        return true
    }

    private fun centerWhenReady() {
        if (!needsCenter || programmaticScroll) return
        needsCenter = false
        centerSelected(animated = false)
    }

    private fun paint(mode: ModeDefinition) {
        chips.forEach { (candidate, chip) ->
            val usable = !candidate.usesTextModel || hasTextModel
            val isSelected = candidate.id == mode.id
            chip.setBackgroundResource(R.drawable.dial_chip)
            // Fake bold keeps each name's measured width fixed, so the
            // centred name cannot nudge sideways as it takes the middle.
            chip.typeface = regularTypeface
            chip.paint.isFakeBoldText = isSelected
            chip.setTextColor(
                ContextCompat.getColor(
                    context,
                    if (isSelected) R.color.ink else R.color.ink_secondary,
                ),
            )
            chip.alpha = if (usable) 1f else 0.38f
        }
    }

    private fun highlightNearest() {
        val nearest = nearestChip(includeUnavailable = true) ?: return
        if (nearest.id == centered?.id) return
        centered = nearest
        paint(nearest)
        tick(nearest)
    }

    /** One haptic per mode crossed, so dragging feels like turning a knob. */
    private fun tick(mode: ModeDefinition) {
        if (mode.id == tickedModeId) return
        tickedModeId = mode.id
        onDetent?.invoke()
    }

    private fun scheduleSettle() {
        settleHandler.removeCallbacks(settle)
        settleHandler.postDelayed(settle, 120)
    }

    private fun commitNearest() {
        if (programmaticScroll) return
        if (SystemClock.uptimeMillis() - lastTouchAt > TOUCH_WINDOW_MS) return
        val mode = nearestChip(includeUnavailable = false) ?: return
        centered = mode
        paint(mode)
        if (committed?.id != mode.id) {
            committed = mode
            // A fast flick can settle on a mode the scroll listener never
            // reported; tick it here so that detent still lands.
            tick(mode)
            listener?.onModeSelected(mode)
        }
        post { centerSelected(animated = true) }
    }

    private fun nearestChip(includeUnavailable: Boolean): ModeDefinition? {
        val width = scroller.width
        if (chips.isEmpty() || width == 0) return null
        val middle = scroller.scrollX + width / 2
        val candidates = if (includeUnavailable) {
            chips
        } else {
            chips.filterKeys { !it.usesTextModel || hasTextModel }
        }
        return candidates.minByOrNull { (_, chip) ->
            kotlin.math.abs(chip.left + chip.width / 2 - middle)
        }?.key
    }

    private fun centerSelected(animated: Boolean) {
        val mode = centered ?: committed ?: return
        val chip = chips[mode] ?: return
        val width = scroller.width
        if (width == 0 || chip.width == 0) return
        val maxScroll = (row.width - width).coerceAtLeast(0)
        val target = (chip.left + chip.width / 2 - width / 2)
            .coerceIn(0, maxScroll)
        val token = ++scrollToken
        programmaticScroll = true
        settleHandler.removeCallbacks(settle)
        if (animated) scroller.smoothScrollTo(target, 0) else scroller.scrollTo(target, 0)
        postDelayed({
            if (token == scrollToken) programmaticScroll = false
        }, 400)
    }

    private val compact: Boolean
        get() = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private companion object {
        const val TOUCH_WINDOW_MS = 800L
    }
}
