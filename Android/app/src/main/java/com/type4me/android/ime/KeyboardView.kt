package com.type4me.android.ime

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.TextUtils
import android.util.AttributeSet
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.animation.AccelerateDecelerateInterpolator
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.ContextCompat
import com.type4me.android.R
import com.type4me.android.data.AppSettings
import com.type4me.android.pipeline.Mode
import com.type4me.android.pipeline.ModeDefinition
import com.type4me.android.pipeline.ModeLibrary

/**
 * The keyboard surface, laid out like the iOS one: a mode dial in the top
 * bar, an undo key, the mic and a delete key in the middle, then globe,
 * punctuation, space and return. The live transcript gets its own scrollable
 * band above the mic so long partials never clip against the keys.
 */
@SuppressLint("ClickableViewAccessibility")
class KeyboardView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : LinearLayout(context, attrs) {

    interface Listener {
        fun onMicDown()
        fun onMicMove(cancelArmed: Boolean, lockArmed: Boolean)
        fun onMicUp(cancelArmed: Boolean, lockArmed: Boolean, quickTap: Boolean)
        fun onCancelRecording()
        fun onLockRecording()
        fun onFinishRecording()
        fun onDelete()
        fun onClear()
        fun onUndo()
        fun onRedo()
        fun onCursorMove(step: Int)
        fun onSpace()
        fun onPunctuation(text: String)
        fun onTogglePunctuationWidth()
        fun onEnter()
        fun onGlobe()
        fun onHideKeyboard()
        fun onSettings()
        fun onModeSelected(mode: ModeDefinition)
        fun onPasteClipboard(text: String)
        fun onDismissClipboard()
        fun onRememberCorrection(word: String)
    }

    var listener: Listener? = null

    private lateinit var modeDial: ModeDialView
    private lateinit var correctionChip: TextView
    private lateinit var statusText: TextView
    private lateinit var timerText: TextView
    private lateinit var partialText: TextView
    private lateinit var placeholderText: TextView
    private lateinit var transcriptScroll: ScrollView
    private lateinit var clipboardBar: LinearLayout
    private lateinit var clipboardLabel: TextView
    private lateinit var micFrame: FrameLayout
    private lateinit var micCircle: View
    private lateinit var micGlow: View
    private lateinit var micIcon: ImageView
    private lateinit var micWaveform: MicWaveformView
    private lateinit var micProgress: ProgressBar
    private lateinit var leftKey: SideKeyView
    private lateinit var rightKey: SideKeyView
    private lateinit var enterKey: TextView
    private lateinit var punctuationKey: TextView
    private lateinit var hideKey: ImageButton
    private lateinit var globeKey: ImageButton
    private lateinit var spaceKey: TextView
    private lateinit var brandKey: FrameLayout

    private var selectedMode = ModeDefinition.builtIn(Mode.QUICK)
    private var ready = false
    private var hasMic = false
    private var hasLlm = true
    private var recording = false
    private var processing = false
    private var locked = false
    private var cancelArmed = false
    private var lockArmed = false
    private var correctionAvailable = false
    private var downX = 0f
    private var downAt = 0L
    private var navigationInset = 0
    private var canUndo = false
    private var canRedo = false
    private var clipboardText: String? = null
    private var glowPulse: ValueAnimator? = null
    private var processingLabel = R.string.kb_processing

    private val repeatHandler = Handler(Looper.getMainLooper())
    private val audioManager by lazy { context.getSystemService(AudioManager::class.java) }
    private var repeatingDelete = false
    private var deleteDownY = 0f
    private var deleteArmed = false
    private var deleteRepeated = false

    private val deleteStart = object : Runnable {
        override fun run() {
            if (deleteArmed) return
            deleteRepeated = true
            repeatingDelete = true
            listener?.onDelete()
            repeatHandler.postDelayed(repeatDelete, 70)
        }
    }

    private val repeatDelete = object : Runnable {
        override fun run() {
            if (!repeatingDelete) return
            listener?.onDelete()
            repeatHandler.postDelayed(this, 70)
        }
    }

    init {
        orientation = VERTICAL
        setBackgroundColor(color(R.color.keyboard_bg))
        applyInsetPadding()
        addView(buildTopBar(), LayoutParams(LayoutParams.MATCH_PARENT, topBarHeight))
        addView(buildCenter(), LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
        addView(buildBottomBar(), LayoutParams(LayoutParams.MATCH_PARENT, bottomBarHeight))
        setModes(ModeLibrary.keyboard(context), ModeLibrary.current(context))
        showIdle()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        // The IME decor parent is a FrameLayout and measures children as
        // MarginLayoutParams; a plain ViewGroup.LayoutParams crashes there.
        applyWindowHeight()
    }

    override fun onApplyWindowInsets(insets: WindowInsets): WindowInsets {
        val bottom = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            insets.getInsets(WindowInsets.Type.navigationBars()).bottom
        } else {
            @Suppress("DEPRECATION")
            insets.systemWindowInsetBottom
        }
        if (bottom != navigationInset) {
            navigationInset = bottom
            applyInsetPadding()
            applyWindowHeight()
        }
        return super.onApplyWindowInsets(insets)
    }

    override fun onDetachedFromWindow() {
        stopGlowPulse()
        repeatingDelete = false
        repeatHandler.removeCallbacks(deleteStart)
        repeatHandler.removeCallbacks(repeatDelete)
        super.onDetachedFromWindow()
    }

    // MARK: - Public state

    fun refresh(
        modes: List<ModeDefinition>,
        mode: ModeDefinition,
        hasService: Boolean,
        hasMicrophone: Boolean,
        hasTextModel: Boolean,
        enterLabel: Int,
        correction: String?,
    ) {
        hasMic = hasMicrophone
        hasLlm = hasTextModel
        ready = hasService && hasMicrophone
        setModes(modes, mode)
        setEnterLabel(enterLabel)
        setCorrection(correction)
        if (!recording && !processing) showIdle()
    }

    fun setUndoState(undo: Boolean, redo: Boolean) {
        canUndo = undo
        canRedo = redo
        if (::leftKey.isInitialized && !recording && !processing) applyIdleSideKeys()
    }

    fun setEnterLabel(label: Int) {
        enterKey.setText(label)
    }

    fun refreshPunctuationLabel() {
        if (::punctuationKey.isInitialized) punctuationKey.text = punctuationLabel()
    }

    /** Re-reads the labels captured at construction after a config change. */
    fun refreshStaticText() {
        val res = context.resources
        if (::hideKey.isInitialized) {
            hideKey.contentDescription = res.getString(R.string.key_hide_keyboard)
        }
        if (::globeKey.isInitialized) {
            globeKey.contentDescription = res.getString(R.string.key_globe)
        }
        if (::spaceKey.isInitialized) {
            spaceKey.contentDescription = res.getString(R.string.key_space_trackpad)
            spaceKey.text = res.getString(R.string.key_space)
        }
        if (::brandKey.isInitialized) {
            brandKey.contentDescription = res.getString(R.string.settings)
        }
        if (::punctuationKey.isInitialized) {
            punctuationKey.contentDescription = res.getString(R.string.key_punctuation)
            punctuationKey.text = punctuationLabel()
        }
        updateMicDescription()
    }

    fun selectedMode(): ModeDefinition = selectedMode

    fun setModes(modes: List<ModeDefinition>, mode: ModeDefinition) {
        val available = modes.ifEmpty { listOf(ModeDefinition.builtIn(Mode.QUICK)) }
        modeDial.setModes(available, mode, hasLlm)
        val effective = mode.takeIf { candidate ->
            available.any { it.id == candidate.id } && (!candidate.usesTextModel || hasLlm)
        } ?: available.firstOrNull { !it.usesTextModel || hasLlm }
            ?: ModeDefinition.builtIn(Mode.QUICK)
        selectedMode = effective
        modeDial.select(effective, notify = false)
    }

    fun setPartial(text: String) {
        partialText.text = text
        if (processing && text.isNotBlank() && statusText.text.isBlank()) {
            statusText.setText(processingLabel)
            statusText.setTextColor(color(R.color.ink_secondary))
        }
        updateTranscript()
        if (text.isNotBlank()) {
            transcriptScroll.post { transcriptScroll.fullScroll(View.FOCUS_DOWN) }
        }
    }

    fun setCorrection(selected: String?) {
        correctionAvailable = !selected.isNullOrBlank()
        if (correctionAvailable) {
            val shown = selected!!.trim().let {
                if (it.length > 10) it.take(10) + "…" else it
            }
            correctionChip.text = context.getString(R.string.kb_correct_selected, shown)
            correctionChip.contentDescription = correctionChip.text
        }
        updateTopBar()
        if (!recording && !processing) showIdle()
    }

    fun showClipboardSuggestion(text: String) {
        if (text.isBlank() || recording || processing || correctionAvailable) return
        clipboardText = text
        val preview = text.replace(Regex("\\s+"), " ").trim().let {
            if (it.length > 80) it.take(80) + "…" else it
        }
        clipboardLabel.text = context.getString(R.string.kb_clipboard_paste, preview)
        clipboardBar.visibility = View.VISIBLE
    }

    fun hideClipboardSuggestion() {
        clipboardText = null
        if (::clipboardBar.isInitialized) clipboardBar.visibility = View.GONE
    }

    fun setRecording(seconds: Int, level: Float, isLocked: Boolean) {
        recording = true
        processing = false
        locked = isLocked
        cancelArmed = false
        lockArmed = false
        cancelDeleteRepeat()
        hideClipboardSuggestion()

        statusText.setText(if (isLocked) R.string.kb_locked else R.string.kb_gesture_hint)
        statusText.setTextColor(color(R.color.ink_secondary))
        timerText.text = formatDuration(seconds)
        timerText.visibility = View.VISIBLE
        placeholderText.setTextColor(color(R.color.transcript_placeholder))
        placeholderText.setText(R.string.kb_recording)

        micIcon.visibility = View.INVISIBLE
        micWaveform.visibility = View.VISIBLE
        micWaveform.start()
        micProgress.visibility = View.GONE
        micGlow.setBackgroundResource(R.drawable.mic_glow)
        micGlow.visibility = View.VISIBLE
        setMicAppearance(recording = true)
        updateMicDescription()

        applyRecordingSideKeys()
        updateTranscript()
        updateTopBar()
        setLevel(level)
    }

    fun setElapsed(seconds: Int) {
        if (recording) timerText.text = formatDuration(seconds)
    }

    fun setProcessing(label: Int = R.string.kb_processing) {
        recording = false
        processing = true
        processingLabel = label
        locked = false
        cancelArmed = false
        lockArmed = false
        cancelDeleteRepeat()

        // With no partial yet the label belongs in the transcript band; a
        // blank caption keeps the mic from jumping when words arrive.
        statusText.text = if (partialText.text.isNotBlank()) context.getString(label) else " "
        statusText.setTextColor(color(R.color.ink_secondary))
        timerText.visibility = View.GONE
        placeholderText.setTextColor(color(R.color.transcript_placeholder))
        placeholderText.setText(label)

        micGlow.setBackgroundResource(R.drawable.mic_glow_processing)
        micGlow.visibility = View.VISIBLE
        micWaveform.stop()
        micWaveform.visibility = View.INVISIBLE
        micIcon.visibility = View.INVISIBLE
        micProgress.visibility = View.VISIBLE
        setMicAppearance(recording = false)
        startGlowPulse()
        updateMicDescription()

        applyProcessingSideKeys()
        updateTranscript()
        updateTopBar()
    }

    fun showDone(message: String? = null) {
        finishState()
        statusText.text = message ?: context.getString(R.string.kb_done)
        statusText.setTextColor(color(if (message == null) R.color.success else R.color.ink_secondary))
        statusText.isClickable = false
        statusText.setOnClickListener(null)
        timerText.visibility = View.GONE
    }

    fun showCorrectionDone(message: String, rememberWord: String?) {
        finishState()
        statusText.text = if (rememberWord != null) {
            "$message · ${context.getString(R.string.kb_remember)}"
        } else {
            message
        }
        statusText.setTextColor(color(R.color.success))
        statusText.isClickable = rememberWord != null
        statusText.setOnClickListener {
            rememberWord?.let { listener?.onRememberCorrection(it) }
        }
        timerText.visibility = View.GONE
    }

    fun showError(message: String) {
        finishState()
        // Errors can be a sentence long; the transcript band scrolls, the
        // one-line caption under the mic does not.
        statusText.text = " "
        statusText.setTextColor(color(R.color.ink_secondary))
        statusText.isClickable = false
        statusText.setOnClickListener(null)
        placeholderText.setTextColor(color(R.color.brand_red))
        placeholderText.text = message
        placeholderText.visibility = View.VISIBLE
        timerText.visibility = View.GONE
    }

    fun showIdle() {
        recording = false
        processing = false
        locked = false
        cancelArmed = false
        lockArmed = false
        cancelDeleteRepeat()
        restoreMic()
        timerText.visibility = View.GONE
        setPartial("")
        placeholderText.setTextColor(color(R.color.transcript_placeholder))
        placeholderText.visibility = View.GONE

        statusText.setText(
            when {
                !hasMic -> R.string.kb_idle_no_mic
                !ready -> R.string.kb_idle_no_config
                correctionAvailable -> R.string.kb_correct_hint
                else -> R.string.kb_idle_ready
            },
        )
        statusText.setTextColor(color(R.color.ink_secondary))
        statusText.isClickable = false
        statusText.setOnClickListener(null)
        updateMicDescription()

        applyIdleSideKeys()
        updateTranscript()
        updateTopBar()
    }

    fun setLevel(level: Float) {
        if (!recording) return
        val glowAlpha = (0.25f + level * 0.55f).coerceIn(0f, 1f)
        micGlow.alpha = glowAlpha
        val scale = 0.96f + level * 0.06f
        micGlow.scaleX = scale
        micGlow.scaleY = scale
        micCircle.scaleX = 1f + level * 0.04f
        micCircle.scaleY = 1f + level * 0.04f
        micWaveform.setLevel(level)
    }

    fun setCancelArmed(armed: Boolean) {
        if (!recording) return
        setHoldZones(armed, if (armed) false else lockArmed)
    }

    private fun setHoldZones(cancel: Boolean, lock: Boolean) {
        if (cancelArmed == cancel && lockArmed == lock) return
        cancelArmed = cancel
        lockArmed = lock
        if (::leftKey.isInitialized) leftKey.setDanger(cancel)
        if (::rightKey.isInitialized && !locked) rightKey.setDanger(lock)
        when {
            cancel -> {
                statusText.setText(R.string.kb_cancel_release)
                statusText.setTextColor(color(R.color.brand_red))
            }

            lock -> {
                statusText.setText(R.string.kb_lock_release)
                statusText.setTextColor(color(R.color.brand_red))
            }

            recording -> {
                statusText.setText(if (locked) R.string.kb_locked else R.string.kb_gesture_hint)
                statusText.setTextColor(color(R.color.ink_secondary))
            }
        }
    }

    fun selectMode(mode: ModeDefinition, notify: Boolean = true) {
        selectedMode = mode
        modeDial.select(mode, notify = false)
        if (notify) {
            // The dial already ticked for this detent; only the click sound
            // is left to play here.
            keySoundFeedback()
            listener?.onModeSelected(mode)
        }
    }

    // MARK: - Layout

    private fun buildTopBar(): View {
        // One shared height keeps the hide button, the mode dial and the
        // settings button visually aligned and equally tall. The bar itself
        // is a little taller so each block's drop shadow has room to draw.
        val barHeight = topBarHeight - dp(4)
        val bar = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(1), 0, dp(3))
            // Child shadows draw into the bar's padding; the default clip
            // would cut every shadow off at the keys' edge.
            clipToPadding = false
        }

        hideKey = ImageButton(context).apply {
            setImageResource(R.drawable.ic_keyboard_hide)
            imageTintList = ColorStateList.valueOf(color(R.color.key_text))
            setBackgroundResource(R.drawable.side_key_background)
            contentDescription = context.getString(R.string.key_hide_keyboard)
            setPadding(dp(10), dp(10), dp(10), dp(10))
            elevation = dp(2).toFloat()
            setOnClickListener {
                tapFeedback()
                listener?.onHideKeyboard()
            }
        }
        bar.addView(hideKey, LayoutParams(barHeight, barHeight))

        val host = FrameLayout(context).apply { clipChildren = false }
        modeDial = ModeDialView(context).apply {
            setBackgroundResource(R.drawable.dial_background)
            elevation = dp(2).toFloat()
            onDetent = { detentFeedback() }
            listener = object : ModeDialView.Listener {
                override fun onModeSelected(mode: ModeDefinition) {
                    selectMode(mode)
                }

                override fun onUnavailableMode() {
                    Toast.makeText(
                        context,
                        R.string.mode_needs_text_model,
                        Toast.LENGTH_SHORT,
                    ).show()
                }
            }
        }
        host.addView(
            modeDial,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        correctionChip = TextView(context).apply {
            textSize = 14f
            gravity = Gravity.CENTER
            includeFontPadding = false
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            setPadding(dp(16), 0, dp(16), 0)
            setTextColor(color(R.color.ink))
            setBackgroundResource(R.drawable.dial_background)
            visibility = View.GONE
        }
        host.addView(
            correctionChip,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        bar.addView(
            host,
            LayoutParams(0, barHeight, 1f).apply {
                marginStart = dp(6)
                marginEnd = dp(6)
            },
        )
        bar.addView(buildBrandButton(), LayoutParams(barHeight, barHeight))
        return bar
    }

    private fun buildBrandButton(): View {
        brandKey = FrameLayout(context).apply {
            setBackgroundResource(R.drawable.side_key_background)
            isClickable = true
            isFocusable = true
            elevation = dp(2).toFloat()
            contentDescription = context.getString(R.string.settings)
            setOnClickListener {
                tapFeedback()
                listener?.onSettings()
            }
        }
        val glyph = ImageView(context).apply {
            setImageResource(R.drawable.ic_mark_glyph)
            imageTintList = ColorStateList.valueOf(color(R.color.ink))
        }
        brandKey.addView(
            glyph,
            FrameLayout.LayoutParams(dp(26), dp(26), Gravity.CENTER),
        )
        val dot = ImageView(context).apply {
            setImageResource(R.drawable.ic_mark_dot)
        }
        brandKey.addView(
            dot,
            FrameLayout.LayoutParams(dp(26), dp(26), Gravity.CENTER),
        )
        return brandKey
    }

    private fun buildCenter(): View {
        val center = LinearLayout(context).apply {
            orientation = VERTICAL
        }

        clipboardBar = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundResource(R.drawable.clipboard_background)
            setPadding(dp(12), 0, dp(4), 0)
            visibility = View.GONE
        }
        val pasteIcon = ImageView(context).apply {
            setImageResource(R.drawable.ic_content_paste)
            imageTintList = ColorStateList.valueOf(color(R.color.key_text))
        }
        clipboardBar.addView(
            pasteIcon,
            LayoutParams(dp(18), dp(18)).apply { marginEnd = dp(8) },
        )
        clipboardLabel = TextView(context).apply {
            textSize = 13f
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            setTextColor(color(R.color.key_text))
            isClickable = true
            setOnClickListener {
                clipboardText?.let { listener?.onPasteClipboard(it) }
                hideClipboardSuggestion()
            }
        }
        clipboardBar.addView(
            clipboardLabel,
            LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f),
        )
        val clipboardClose = ImageButton(context).apply {
            setImageResource(R.drawable.ic_close)
            imageTintList = ColorStateList.valueOf(color(R.color.ink_secondary))
            setBackgroundResource(0)
            contentDescription = context.getString(R.string.kb_clipboard_dismiss)
            setPadding(dp(9), dp(9), dp(9), dp(9))
            setOnClickListener {
                listener?.onDismissClipboard()
                hideClipboardSuggestion()
            }
        }
        clipboardBar.addView(clipboardClose, LayoutParams(dp(36), dp(36)))
        center.addView(
            clipboardBar,
            LayoutParams(LayoutParams.MATCH_PARENT, dp(38)).apply {
                topMargin = dp(4)
                bottomMargin = dp(2)
            },
        )

        transcriptScroll = ScrollView(context).apply {
            isFillViewport = true
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            clipToPadding = false
            setPadding(dp(4), dp(2), dp(4), dp(2))
        }
        val textHost = LinearLayout(context).apply {
            orientation = VERTICAL
            gravity = Gravity.CENTER
        }
        partialText = TextView(context).apply {
            textSize = if (compact) 15f else 17f
            gravity = Gravity.CENTER
            setTextColor(color(R.color.key_text))
            includeFontPadding = false
            setLineSpacing(dp(2).toFloat(), 1f)
            setPadding(dp(18), dp(2), dp(18), dp(2))
            visibility = View.GONE
        }
        textHost.addView(
            partialText,
            LayoutParams(
                LayoutParams.MATCH_PARENT,
                LayoutParams.WRAP_CONTENT,
            ),
        )
        placeholderText = TextView(context).apply {
            textSize = if (compact) 13f else 14f
            gravity = Gravity.CENTER
            setTextColor(color(R.color.transcript_placeholder))
            includeFontPadding = false
            visibility = View.GONE
        }
        textHost.addView(
            placeholderText,
            LayoutParams(
                LayoutParams.MATCH_PARENT,
                LayoutParams.WRAP_CONTENT,
            ),
        )
        transcriptScroll.addView(
            textHost,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
        center.addView(
            transcriptScroll,
            LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f),
        )
        center.addView(
            buildMicRow(),
            LayoutParams(LayoutParams.MATCH_PARENT, micRowHeight),
        )
        return center
    }

    private fun buildMicRow(): View {
        val row = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(2), 0, dp(2))
        }

        leftKey = SideKeyView(context)
        row.addView(leftKey, LayoutParams(sideKeyWidth, sideKeyHeight))

        val column = LinearLayout(context).apply {
            orientation = VERTICAL
            gravity = Gravity.CENTER
        }
        row.addView(column, LayoutParams(0, LayoutParams.MATCH_PARENT, 1f))
        column.addView(buildMic(), LayoutParams(micFrameSize, micFrameSize))

        val caption = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(4), dp(2), dp(4), 0)
        }
        statusText = TextView(context).apply {
            textSize = 12f
            gravity = Gravity.CENTER
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            setTextColor(color(R.color.ink_secondary))
            includeFontPadding = false
        }
        caption.addView(statusText, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
        timerText = TextView(context).apply {
            textSize = 12f
            typeface = Typeface.MONOSPACE
            setTextColor(color(R.color.ink_secondary))
            includeFontPadding = false
            visibility = View.GONE
        }
        caption.addView(
            timerText,
            LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
                marginStart = dp(6)
            },
        )
        column.addView(caption, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))

        rightKey = SideKeyView(context)
        row.addView(rightKey, LayoutParams(sideKeyWidth, sideKeyHeight))
        return row
    }

    private fun buildMic(): View {
        micFrame = FrameLayout(context).apply {
            isClickable = true
            isFocusable = true
            clipChildren = false
            contentDescription = context.getString(R.string.kb_idle_ready)
            setOnClickListener {
                listener?.onMicDown()
                listener?.onMicUp(false, false, true)
            }
        }
        micGlow = View(context).apply {
            setBackgroundResource(R.drawable.mic_glow)
            alpha = 0f
            visibility = View.INVISIBLE
        }
        micFrame.addView(
            micGlow,
            FrameLayout.LayoutParams(
                micFrameSize + dp(12),
                micFrameSize + dp(12),
                Gravity.CENTER,
            ),
        )

        micCircle = View(context).apply {
            setBackgroundResource(R.drawable.mic_circle)
            elevation = dp(5).toFloat()
        }
        micFrame.addView(
            micCircle,
            FrameLayout.LayoutParams(micCircleSize, micCircleSize, Gravity.CENTER),
        )

        micIcon = ImageView(context).apply {
            setImageResource(R.drawable.ic_mic)
            imageTintList = ColorStateList.valueOf(color(R.color.mic_icon))
            // The mic disc has elevation for its shadow; the glyph has to
            // sit above it or the disc paints over the icon.
            elevation = dp(6).toFloat()
        }
        micFrame.addView(
            micIcon,
            FrameLayout.LayoutParams(micIconSize, micIconSize, Gravity.CENTER),
        )

        micWaveform = MicWaveformView(context).apply {
            elevation = dp(6).toFloat()
            visibility = View.INVISIBLE
        }
        micFrame.addView(
            micWaveform,
            FrameLayout.LayoutParams(micIconSize, micIconSize, Gravity.CENTER),
        )

        micProgress = ProgressBar(
            context,
            null,
            android.R.attr.progressBarStyleSmall,
        ).apply {
            indeterminateTintList = ColorStateList.valueOf(color(R.color.mic_icon))
            elevation = dp(6).toFloat()
            visibility = View.GONE
        }
        micFrame.addView(
            micProgress,
            FrameLayout.LayoutParams(dp(28), dp(28), Gravity.CENTER),
        )

        micFrame.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downAt = SystemClock.elapsedRealtime()
                    setHoldZones(false, false)
                    listener?.onMicDown()
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    if (!recording) return@setOnTouchListener true
                    val dx = event.rawX - downX
                    val cancel = dx < -dp(56)
                    val lock = !locked && dx > dp(56)
                    if (cancel != cancelArmed || lock != lockArmed) {
                        tapFeedback()
                        setHoldZones(cancel, lock)
                        listener?.onMicMove(cancel, lock)
                    }
                    true
                }

                MotionEvent.ACTION_UP -> {
                    val quick = SystemClock.elapsedRealtime() - downAt < 250
                    listener?.onMicUp(cancelArmed, lockArmed, quick)
                    setHoldZones(false, false)
                    true
                }

                MotionEvent.ACTION_CANCEL -> {
                    listener?.onMicUp(true, false, false)
                    setHoldZones(false, false)
                    true
                }

                else -> false
            }
        }
        return micFrame
    }

    private fun buildBottomBar(): View {
        val bar = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            // The keys keep their height, but sit this far above the bar's
            // bottom edge so their drop shadow is fully visible.
            setPadding(0, dp(1), 0, dp(11))
            clipToPadding = false
        }

        globeKey = ImageButton(context).apply {
            setImageResource(R.drawable.ic_globe)
            imageTintList = ColorStateList.valueOf(color(R.color.key_text))
            setBackgroundResource(R.drawable.side_key_background)
            contentDescription = context.getString(R.string.key_globe)
            setPadding(dp(8), dp(8), dp(8), dp(8))
            elevation = dp(2).toFloat()
            setOnClickListener {
                tapFeedback()
                listener?.onGlobe()
            }
        }
        bar.addView(globeKey, LayoutParams(dp(44), LayoutParams.MATCH_PARENT))

        punctuationKey = textKey(punctuationLabel(), function = false) {
            listener?.onPunctuation(
                if (AppSettings.fullWidthPunctuation(context)) "，" else ",",
            )
        }
        punctuationKey.contentDescription = context.getString(R.string.key_punctuation)
        punctuationKey.setOnTouchListener(punctuationTouch())
        bar.addView(punctuationKey, keyParams(1.0f))

        spaceKey = textKey(spaceLabel, function = false) { listener?.onSpace() }
        spaceKey.contentDescription = context.getString(R.string.key_space_trackpad)
        var spacePressed = false
        var tracking = false
        var spaceDownX = 0f
        var anchor = 0f
        spaceKey.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    spacePressed = true
                    tracking = false
                    spaceDownX = event.rawX
                    anchor = spaceDownX
                    tapFeedback()
                }

                MotionEvent.ACTION_MOVE -> {
                    if (!spacePressed) return@setOnTouchListener true
                    if (!tracking && kotlin.math.abs(event.rawX - spaceDownX) > dp(12)) {
                        tracking = true
                        anchor = event.rawX
                        spaceKey.text = "↔"
                    }
                    if (tracking) {
                        val steps = ((event.rawX - anchor) / dp(9)).toInt()
                        if (steps != 0) {
                            listener?.onCursorMove(steps)
                            anchor += steps * dp(9)
                            tapFeedback()
                        }
                    }
                }

                MotionEvent.ACTION_UP -> {
                    if (spacePressed && !tracking) listener?.onSpace()
                    spacePressed = false
                    tracking = false
                    spaceKey.text = spaceLabel
                }

                MotionEvent.ACTION_CANCEL -> {
                    spacePressed = false
                    tracking = false
                    spaceKey.text = spaceLabel
                }
            }
            true
        }
        bar.addView(spaceKey, keyParams(3.4f))

        enterKey = textKey(context.getString(R.string.key_enter), function = true) {
            tapFeedback()
            listener?.onEnter()
        }
        bar.addView(enterKey, keyParams(2.0f))

        return bar
    }

    private fun punctuationLabel(): String =
        if (AppSettings.fullWidthPunctuation(context)) "，。" else ",."

    private val spaceLabel: String
        get() = context.getString(R.string.key_space)

    private fun punctuationTouch(): View.OnTouchListener {
        var downY = 0f
        var flicked = false
        var menuShown = false
        val showMenu = Runnable {
            if (flicked) return@Runnable
            menuShown = true
            showPunctuationMenu()
        }
        return View.OnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downY = event.rawY
                    flicked = false
                    menuShown = false
                    repeatHandler.postDelayed(showMenu, 360)
                    tapFeedback()
                }

                MotionEvent.ACTION_MOVE -> {
                    if (!flicked && event.rawY - downY < -dp(18)) {
                        flicked = true
                        repeatHandler.removeCallbacks(showMenu)
                        punctuationKey.text = if (AppSettings.fullWidthPunctuation(context)) "。" else "."
                        punctuationKey.alpha = 0.7f
                    }
                }

                MotionEvent.ACTION_UP -> {
                    repeatHandler.removeCallbacks(showMenu)
                    punctuationKey.alpha = 1f
                    punctuationKey.text = punctuationLabel()
                    if (flicked) {
                        listener?.onPunctuation(if (AppSettings.fullWidthPunctuation(context)) "。" else ".")
                    } else if (!menuShown) {
                        listener?.onPunctuation(if (AppSettings.fullWidthPunctuation(context)) "，" else ",")
                    }
                }

                MotionEvent.ACTION_CANCEL -> {
                    repeatHandler.removeCallbacks(showMenu)
                    punctuationKey.alpha = 1f
                    punctuationKey.text = punctuationLabel()
                }
            }
            true
        }
    }

    private fun showPunctuationMenu() {
        val fullWidth = AppSettings.fullWidthPunctuation(context)
        val marks = if (fullWidth) listOf("。", "？", "！", "、") else listOf(".", "?", "!", "'")
        val menu = PopupMenu(context, punctuationKey)
        marks.forEachIndexed { index, mark -> menu.menu.add(0, index, index, mark) }
        menu.menu.add(0, marks.size, marks.size, context.getString(R.string.key_punctuation_width))
        menu.setOnMenuItemClickListener { item ->
            if (item.itemId == marks.size) {
                listener?.onTogglePunctuationWidth()
                punctuationKey.text = punctuationLabel()
            } else {
                listener?.onPunctuation(marks[item.itemId])
            }
            true
        }
        menu.show()
    }

    private fun textKey(label: String, function: Boolean, onClick: () -> Unit): TextView =
        TextView(context).apply {
            text = label
            textSize = 15f
            gravity = Gravity.CENTER
            includeFontPadding = false
            setTextColor(color(R.color.key_text))
            setBackgroundResource(
                if (function) R.drawable.key_function_background else R.drawable.key_background,
            )
            // A soft drop shadow lifts the key off the keyboard surface.
            elevation = dp(2).toFloat()
            isClickable = true
            isFocusable = true
            setOnClickListener { onClick() }
        }

    private fun keyParams(weight: Float, first: Boolean = false): LayoutParams =
        LayoutParams(0, LayoutParams.MATCH_PARENT, weight).apply {
            if (!first) marginStart = dp(6)
        }

    // MARK: - Side keys

    private fun applyIdleSideKeys(interactive: Boolean = true) {
        if (!::leftKey.isInitialized) return
        val redo = canRedo
        leftKey.setContent(
            if (redo) R.drawable.ic_redo else R.drawable.ic_undo,
            if (redo) R.string.key_redo else R.string.key_undo,
        )
        leftKey.setDanger(false)
        leftKey.setEnabledState(interactive && (canUndo || canRedo))
        leftKey.setOnClickListener {
            if (!interactive) return@setOnClickListener
            tapFeedback()
            if (canRedo) listener?.onRedo() else listener?.onUndo()
        }
        leftKey.setOnTouchListener(null)

        rightKey.setContent(R.drawable.ic_delete, R.string.key_delete)
        rightKey.setDanger(false)
        rightKey.setEnabledState(interactive)
        rightKey.setOnClickListener {
            if (!interactive) return@setOnClickListener
            tapFeedback()
            listener?.onDelete()
        }
        rightKey.setOnTouchListener(if (interactive) deleteTouch() else null)
    }

    private fun applyRecordingSideKeys() {
        if (!::leftKey.isInitialized) return
        leftKey.setContent(R.drawable.ic_close, R.string.key_cancel)
        leftKey.setDanger(cancelArmed)
        leftKey.setEnabledState(true)
        leftKey.setOnTouchListener(null)
        leftKey.setOnClickListener {
            tapFeedback()
            listener?.onCancelRecording()
        }

        if (locked) {
            rightKey.setContent(R.drawable.ic_check, R.string.key_done)
            rightKey.setOnClickListener {
                tapFeedback()
                listener?.onFinishRecording()
            }
        } else {
            rightKey.setContent(R.drawable.ic_lock, R.string.key_lock)
            rightKey.setDanger(lockArmed)
            rightKey.setOnClickListener {
                tapFeedback()
                listener?.onLockRecording()
            }
        }
        rightKey.setEnabledState(true)
        rightKey.setOnTouchListener(null)
    }

    private fun applyProcessingSideKeys() {
        if (!::leftKey.isInitialized) return
        applyIdleSideKeys(interactive = false)
        rightKey.setEnabledState(false)
        rightKey.setOnTouchListener(null)
    }

    private fun deleteTouch(): View.OnTouchListener =
        View.OnTouchListener { _, event ->
            if (recording || processing) return@OnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    rightKey.isPressed = true
                    deleteArmed = false
                    deleteRepeated = false
                    deleteDownY = event.rawY
                    repeatHandler.removeCallbacks(deleteStart)
                    repeatHandler.postDelayed(deleteStart, 420)
                    tapFeedback()
                }

                MotionEvent.ACTION_MOVE -> {
                    if (!deleteArmed && event.rawY - deleteDownY < -dp(36)) {
                        deleteArmed = true
                        repeatingDelete = false
                        repeatHandler.removeCallbacks(deleteStart)
                        repeatHandler.removeCallbacks(repeatDelete)
                        rightKey.setContent(R.drawable.ic_close, R.string.key_clear)
                        rightKey.setDanger(true)
                        rightKey.scaleX = 1.08f
                        rightKey.scaleY = 1.08f
                    }
                }

                MotionEvent.ACTION_UP -> {
                    repeatHandler.removeCallbacks(deleteStart)
                    repeatHandler.removeCallbacks(repeatDelete)
                    repeatingDelete = false
                    rightKey.isPressed = false
                    val armed = deleteArmed
                    val repeated = deleteRepeated
                    resetDeleteVisual()
                    if (armed) listener?.onClear() else if (!repeated) listener?.onDelete()
                }

                MotionEvent.ACTION_CANCEL -> {
                    repeatHandler.removeCallbacks(deleteStart)
                    repeatHandler.removeCallbacks(repeatDelete)
                    repeatingDelete = false
                    rightKey.isPressed = false
                    resetDeleteVisual()
                }
            }
            true
        }

    private fun cancelDeleteRepeat() {
        repeatingDelete = false
        deleteArmed = false
        repeatHandler.removeCallbacks(deleteStart)
        repeatHandler.removeCallbacks(repeatDelete)
        resetDeleteVisual()
    }

    // MARK: - Helpers

    private fun finishState() {
        recording = false
        processing = false
        locked = false
        cancelArmed = false
        lockArmed = false
        cancelDeleteRepeat()
        restoreMic()
        setPartial("")
        placeholderText.visibility = View.GONE
        correctionAvailable = false
        applyIdleSideKeys()
        updateTranscript()
        updateTopBar()
        updateMicDescription()
    }

    private fun updateTranscript() {
        val hasText = partialText.text.isNotBlank()
        partialText.visibility = if (hasText) View.VISIBLE else View.GONE
        placeholderText.visibility =
            if (!hasText && (recording || processing)) View.VISIBLE else View.GONE
    }

    private fun updateTopBar() {
        if (!::modeDial.isInitialized) return
        val idle = !recording && !processing
        val showCorrection = idle && correctionAvailable
        modeDial.visibility = if (idle && !showCorrection) View.VISIBLE else View.GONE
        correctionChip.visibility = if (showCorrection) View.VISIBLE else View.GONE
    }

    private fun updateMicDescription() {
        if (!::micFrame.isInitialized) return
        micFrame.contentDescription = context.getString(
            when {
                processing -> R.string.kb_processing
                recording && locked -> R.string.kb_locked
                recording -> R.string.kb_recording
                else -> R.string.kb_idle_ready
            },
        )
    }

    private fun startGlowPulse() {
        glowPulse?.cancel()
        glowPulse = ValueAnimator.ofFloat(0.45f, 0.85f).apply {
            duration = 900
            repeatMode = ValueAnimator.REVERSE
            repeatCount = ValueAnimator.INFINITE
            interpolator = AccelerateDecelerateInterpolator()
            addUpdateListener { animation ->
                micGlow.alpha = animation.animatedValue as Float
            }
            start()
        }
    }

    private fun stopGlowPulse() {
        glowPulse?.cancel()
        glowPulse = null
    }

    private fun restoreMic() {
        stopGlowPulse()
        if (::micGlow.isInitialized) {
            micGlow.visibility = View.INVISIBLE
            micGlow.alpha = 0f
            micGlow.scaleX = 1f
            micGlow.scaleY = 1f
            micGlow.setBackgroundResource(R.drawable.mic_glow)
        }
        if (::micIcon.isInitialized) {
            micIcon.visibility = View.VISIBLE
            micIcon.imageTintList = ColorStateList.valueOf(color(R.color.mic_icon))
        }
        if (::micWaveform.isInitialized) {
            micWaveform.stop()
            micWaveform.visibility = View.INVISIBLE
        }
        if (::micProgress.isInitialized) micProgress.visibility = View.GONE
        if (::micCircle.isInitialized) {
            micCircle.setBackgroundResource(R.drawable.mic_circle)
            micCircle.scaleX = 1f
            micCircle.scaleY = 1f
        }
        if (::micFrame.isInitialized) micFrame.alpha = 1f
        cancelArmed = false
        lockArmed = false
    }

    private fun setMicAppearance(recording: Boolean) {
        micCircle.setBackgroundResource(
            if (recording) R.drawable.mic_circle_recording else R.drawable.mic_circle,
        )
        micIcon.imageTintList = ColorStateList.valueOf(
            if (recording) Color.WHITE else color(R.color.mic_icon),
        )
    }

    private fun resetDeleteVisual() {
        if (!::rightKey.isInitialized || recording || processing) return
        rightKey.setContent(R.drawable.ic_delete, R.string.key_delete)
        rightKey.setDanger(false)
        rightKey.scaleX = 1f
        rightKey.scaleY = 1f
    }

    private fun tapFeedback() {
        if (AppSettings.keyHaptics(context)) {
            performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        }
        keySoundFeedback()
    }

    private fun detentFeedback() {
        if (AppSettings.keyHaptics(context)) {
            performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        }
    }

    private fun keySoundFeedback() {
        if (AppSettings.keySounds(context)) {
            audioManager?.playSoundEffect(AudioManager.FX_KEYPRESS_STANDARD)
        }
    }

    private fun formatDuration(seconds: Int): String {
        val minutes = seconds / 60
        val remainder = seconds % 60
        return "%02d:%02d".format(minutes, remainder)
    }

    // MARK: - Metrics

    private val compact: Boolean
        get() = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE

    private val topBarHeight: Int
        get() = dp(if (compact) 38 else 42)

    private val micRowHeight: Int
        get() = dp(if (compact) 70 else 84)

    private val bottomBarHeight: Int
        get() = dp(if (compact) 56 else 60)

    private val micFrameSize: Int
        get() = dp(if (compact) 48 else 62)

    private val micCircleSize: Int
        get() = dp(if (compact) 38 else 52)

    private val micIconSize: Int
        get() = dp(if (compact) 18 else 23)

    private val sideKeyWidth: Int
        get() = dp(if (compact) 50 else 60)

    private val sideKeyHeight: Int
        get() = dp(if (compact) 44 else 58)

    private fun bodyHeightPx(): Int {
        val config = resources.configuration
        val height = if (compact) {
            (config.screenHeightDp * 0.55f).coerceIn(230f, 300f)
        } else {
            // The whole IME window is about 35% of the screen. The nav
            // inset lives inside that budget, so only give back the part
            // above a typical gesture bar.
            (config.screenHeightDp * 0.38f).coerceIn(290f, 370f)
        }
        return dp(height.toInt())
    }

    private fun applyWindowHeight() {
        val extraNav = (navigationInset - dp(24)).coerceAtLeast(0)
        val params = layoutParams as? FrameLayout.LayoutParams
            ?: FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                bodyHeightPx() + extraNav,
            )
        params.height = bodyHeightPx() + extraNav
        layoutParams = params
    }

    private fun applyInsetPadding() {
        setPadding(
            dp(14),
            dp(4),
            dp(14),
            dp(8) + navigationInset + dp(SYSTEM_TOOLS_ROOM_DP),
        )
    }

    private fun color(id: Int): Int = ContextCompat.getColor(context, id)

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private companion object {
        /** Free strip under the keys for the system's own keyboard switcher. */
        const val SYSTEM_TOOLS_ROOM_DP = 14
    }
}
