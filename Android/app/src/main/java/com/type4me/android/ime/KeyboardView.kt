package com.type4me.android.ime

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
import android.view.View.MeasureSpec
import android.view.WindowInsets
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
 * The keyboard surface has a mode dial in the top bar, an undo key, the mic
 * and a delete key in the middle, then globe, punctuation, space and return.
 * While recording, the top bar's controls step aside for a live transcript.
 */
@SuppressLint("ClickableViewAccessibility")
class KeyboardView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : LinearLayout(context, attrs) {

    interface Listener {
        fun onMicDown()
        fun onMicMove(cancelArmed: Boolean, lockArmed: Boolean, sendArmed: Boolean)
        fun onMicUp(
            cancelArmed: Boolean,
            lockArmed: Boolean,
            sendArmed: Boolean,
            quickTap: Boolean,
        )
        fun onCancelRecording()
        fun onLockRecording()
        fun onFinishRecording()
        fun onSendRecording()
        fun onDelete()
        fun onClear()
        fun onUndo()
        fun onRedo()
        fun onCursorMove(step: Int)
        fun onSpace()
        fun onPunctuation(text: String)
        fun onTogglePunctuationWidth()
        fun onEnter()
        fun onNewline()
        fun onGlobe()
        fun onHideKeyboard()
        fun onSettings()
        fun onModeSelected(mode: ModeDefinition)
        fun onPasteClipboard(text: String)
        fun onDismissClipboard()
        fun onRememberCorrection(word: String)
    }

    var listener: Listener? = null

    private lateinit var topHost: FrameLayout
    private lateinit var topControls: FrameLayout
    private lateinit var topCaptionScroll: ScrollView
    private lateinit var topPartialText: TextView
    private lateinit var topPlaceholderText: TextView
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
    private lateinit var micGlyph: RecordingMicView
    private lateinit var micProgress: ProgressBar
    private lateinit var sendButton: LinearLayout
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
    private var sendArmed = false
    private var sendSupported = false
    private var correctionAvailable = false
    private var downX = 0f
    private var downY = 0f
    private var downAt = 0L
    private var navigationInset = 0
    private var canUndo = false
    private var canRedo = false
    private var clipboardText: String? = null
    private var processingLabel = R.string.kb_processing

    // Regular Chinese glyphs at 15sp looked washed out; Noto Sans at medium
    // gives the keyboard labels a firmer Android-native rhythm.
    private val regularTypeface by lazy { Typeface.create("sans-serif", Typeface.NORMAL) }
    private val mediumTypeface by lazy { Typeface.create("sans-serif-medium", Typeface.NORMAL) }

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
        sendSupported: Boolean,
        correction: String?,
    ) {
        hasMic = hasMicrophone
        hasLlm = hasTextModel
        ready = hasService && hasMicrophone
        this.sendSupported = sendSupported
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
        topPartialText.text = text
        topPartialText.visibility = if (text.isNotBlank()) View.VISIBLE else View.GONE
        topPlaceholderText.visibility =
            if (text.isBlank() && (recording || processing)) View.VISIBLE else View.GONE
        if (processing && text.isNotBlank() && statusText.text.isBlank()) {
            statusText.setText(processingLabel)
            statusText.setTextColor(color(R.color.ink_secondary))
        }
        updateTranscript()
        if (text.isNotBlank()) {
            transcriptScroll.post { transcriptScroll.fullScroll(View.FOCUS_DOWN) }
            topCaptionScroll.post { topCaptionScroll.fullScroll(View.FOCUS_DOWN) }
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
        micGlyph.setLevel(level)
        locked = isLocked
        cancelArmed = false
        lockArmed = false
        sendArmed = false
        cancelDeleteRepeat()
        hideClipboardSuggestion()

        statusText.setText(
            when {
                isLocked -> R.string.kb_locked
                sendSupported -> R.string.kb_gesture_send_hint
                else -> R.string.kb_gesture_hint
            },
        )
        if (::sendButton.isInitialized) sendButton.visibility = View.GONE
        statusText.setTextColor(color(R.color.ink_secondary))
        timerText.text = formatDuration(seconds)
        timerText.visibility = View.VISIBLE
        placeholderText.setTextColor(color(R.color.transcript_placeholder))
        placeholderText.setText(R.string.kb_recording)
        topPlaceholderText.setText(R.string.kb_recording)
        topPlaceholderText.visibility =
            if (topPartialText.text.isBlank()) View.VISIBLE else View.GONE

        micGlyph.visibility = View.VISIBLE
        micGlyph.start()
        micProgress.visibility = View.GONE
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
        sendArmed = false
        cancelDeleteRepeat()

        // With no partial yet the label belongs in the transcript band; a
        // blank caption keeps the mic from jumping when words arrive.
        statusText.text = if (partialText.text.isNotBlank()) context.getString(label) else " "
        statusText.setTextColor(color(R.color.ink_secondary))
        timerText.visibility = View.GONE
        placeholderText.setTextColor(color(R.color.transcript_placeholder))
        placeholderText.setText(label)
        topPlaceholderText.setText(label)
        topPlaceholderText.visibility =
            if (topPartialText.text.isBlank()) View.VISIBLE else View.GONE

        setMicProcessingAppearance()
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
        sendArmed = false
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
        micGlyph.setLevel(level)
    }

    fun setCancelArmed(armed: Boolean) {
        if (!recording) return
        setHoldZones(armed, if (armed) false else lockArmed, if (armed) false else sendArmed)
    }

    private fun setHoldZones(cancel: Boolean, lock: Boolean, send: Boolean) {
        if (cancelArmed == cancel && lockArmed == lock && sendArmed == send) return
        cancelArmed = cancel
        lockArmed = lock
        sendArmed = send
        if (::leftKey.isInitialized) leftKey.setDanger(cancel)
        if (::rightKey.isInitialized) {
            rightKey.setContent(
                if (locked) R.drawable.ic_check else R.drawable.ic_lock,
                if (locked) R.string.key_done else R.string.key_lock,
            )
            rightKey.setDanger(lock)
        }
        if (::sendButton.isInitialized) {
            sendButton.visibility = if (send) View.VISIBLE else View.GONE
            if (send) sendButton.bringToFront()
            sendButton.animate()
                .scaleX(if (send) 1f else 0.82f)
                .scaleY(if (send) 1f else 0.82f)
                .alpha(if (send) 1f else 0f)
                .setDuration(120L)
                .start()
        }
        when {
            cancel -> {
                statusText.setText(R.string.kb_cancel_release)
                statusText.setTextColor(color(R.color.brand_red))
            }

            send -> {
                statusText.setText(R.string.kb_send_release)
                statusText.setTextColor(color(R.color.brand_red))
            }

            lock -> {
                statusText.setText(R.string.kb_lock_release)
                statusText.setTextColor(color(R.color.brand_red))
            }

            recording -> {
                statusText.setText(
                    when {
                        locked -> R.string.kb_locked
                        sendSupported -> R.string.kb_gesture_send_hint
                        else -> R.string.kb_gesture_hint
                    },
                )
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
        topHost = FrameLayout(context).apply {
            clipChildren = false
            clipToPadding = false
        }
        topControls = FrameLayout(context).apply {
            clipChildren = false
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
        topControls.addView(
            hideKey,
            FrameLayout.LayoutParams(
                barHeight,
                barHeight,
                Gravity.START or Gravity.CENTER_VERTICAL,
            ),
        )

        val host = CappedFrameLayout(context).apply {
            maxWidth = dp(if (compact) 170 else 200)
            clipChildren = false
        }
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
            typeface = mediumTypeface
            gravity = Gravity.CENTER
            includeFontPadding = false
            letterSpacing = 0.01f
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            setPadding(dp(16), 0, dp(16), 0)
            setTextColor(color(R.color.ink))
            setBackgroundResource(R.drawable.dial_background)
            visibility = View.GONE
        }
        // A narrower dial than the old full-width one; the two corner keys
        // keep their places on either side of the middle.
        topControls.addView(
            host,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                barHeight,
                Gravity.CENTER,
            ).apply {
                marginStart = barHeight + dp(6)
                marginEnd = barHeight + dp(6)
            },
        )
        // The correction chip keeps the old wide band; it only shares the
        // row with the dial for a moment and needs room for the words.
        topControls.addView(
            correctionChip,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                barHeight,
                Gravity.CENTER,
            ).apply {
                marginStart = barHeight + dp(6)
                marginEnd = barHeight + dp(6)
            },
        )
        topControls.addView(
            buildBrandButton(),
            FrameLayout.LayoutParams(
                barHeight,
                barHeight,
                Gravity.END or Gravity.CENTER_VERTICAL,
            ),
        )

        topHost.addView(
            topControls,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        // While recording, the controls step out and the top band carries
        // the live transcript, the way the iOS caption does.
        topCaptionScroll = ScrollView(context).apply {
            isFillViewport = true
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            clipToPadding = false
            setPadding(dp(4), dp(2), dp(4), dp(2))
            visibility = View.GONE
        }
        val captionHost = LinearLayout(context).apply {
            orientation = VERTICAL
            gravity = Gravity.CENTER
        }
        topPartialText = TextView(context).apply {
            textSize = if (compact) 14f else 16f
            typeface = mediumTypeface
            gravity = Gravity.CENTER
            setTextColor(color(R.color.key_text))
            includeFontPadding = false
            letterSpacing = 0.01f
            setLineSpacing(dp(3).toFloat(), 1f)
            setPadding(dp(18), dp(1), dp(18), dp(1))
            visibility = View.GONE
        }
        captionHost.addView(
            topPartialText,
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT),
        )
        topPlaceholderText = TextView(context).apply {
            textSize = if (compact) 13f else 14f
            typeface = mediumTypeface
            gravity = Gravity.CENTER
            setTextColor(color(R.color.transcript_placeholder))
            includeFontPadding = false
            letterSpacing = 0.01f
            visibility = View.GONE
        }
        captionHost.addView(
            topPlaceholderText,
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT),
        )
        topCaptionScroll.addView(
            captionHost,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
        topHost.addView(
            topCaptionScroll,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        // The transient send affordance overlays the caption band. It is
        // independent of both the scrolling transcript and the mic row, so
        // it cannot cover the recording disc.
        sendButton = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(14), 0, dp(16), 0)
            setBackgroundResource(R.drawable.send_button_background)
            elevation = dp(6).toFloat()
            isClickable = true
            isFocusable = true
            visibility = View.GONE
            alpha = 0f
            scaleX = 0.82f
            scaleY = 0.82f
            contentDescription = context.getString(R.string.kb_send_release)
            setOnClickListener {
                tapFeedback()
                listener?.onSendRecording()
            }

            val icon = ImageView(context).apply {
                setImageResource(R.drawable.ic_send)
                imageTintList = ColorStateList.valueOf(Color.WHITE)
            }
            addView(icon, LayoutParams(dp(16), dp(16)))
            addView(
                TextView(context).apply {
                    text = context.getString(R.string.key_send)
                    textSize = 13f
                    typeface = mediumTypeface
                    gravity = Gravity.CENTER
                    includeFontPadding = false
                    setTextColor(Color.WHITE)
                },
                LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT).apply {
                    marginStart = dp(6)
                },
            )
        }
        topHost.addView(
            sendButton,
            FrameLayout.LayoutParams(
                dp(88),
                dp(38),
                Gravity.CENTER,
            ),
        )
        return topHost
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
        // The mic row is pinned to the bottom of this area. Recording swaps
        // the top controls for a taller caption, which changes the space
        // above the mic; it must not change the mic row's anchor.
        val center = FrameLayout(context).apply {
            clipChildren = false
            clipToPadding = false
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
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                dp(38),
                Gravity.TOP,
            ).apply {
                topMargin = dp(4)
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
            textSize = if (compact) 14f else 16f
            typeface = mediumTypeface
            letterSpacing = 0.01f
            gravity = Gravity.CENTER
            setTextColor(color(R.color.key_text))
            includeFontPadding = false
            setLineSpacing(dp(3).toFloat(), 1f)
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
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
                Gravity.TOP,
            ).apply {
                bottomMargin = micRowHeight
            },
        )

        center.addView(
            buildMicRow(),
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                micRowHeight,
                Gravity.BOTTOM,
            ),
        )
        return center
    }

    private fun buildMicRow(): View {
        val row = FrameLayout(context).apply {
            clipChildren = false
            clipToPadding = false
        }
        val sideTop = (micFrameSize - sideKeyHeight) / 2

        leftKey = SideKeyView(context)
        row.addView(
            leftKey,
            FrameLayout.LayoutParams(
                sideKeyWidth,
                sideKeyHeight,
                Gravity.START or Gravity.TOP,
            ).apply { topMargin = sideTop },
        )

        row.addView(
            buildMic(),
            FrameLayout.LayoutParams(
                micFrameSize,
                micFrameSize,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL,
            ),
        )

        // The hint and timer sit below the side keys and may use the whole
        // row, so the timer never takes width away from the hint.
        val caption = FrameLayout(context).apply {
            setPadding(dp(4), 0, dp(4), 0)
        }
        statusText = TextView(context).apply {
            textSize = 12f
            typeface = mediumTypeface
            letterSpacing = 0.01f
            gravity = Gravity.CENTER
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            setTextColor(color(R.color.ink_secondary))
            includeFontPadding = false
            // Keep the centered hint clear of the right-side clock.
            setPadding(dp(42), 0, dp(42), 0)
        }
        caption.addView(
            statusText,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
                Gravity.CENTER,
            ),
        )
        timerText = TextView(context).apply {
            textSize = 12f
            typeface = Typeface.MONOSPACE
            setTextColor(color(R.color.ink_secondary))
            includeFontPadding = false
            visibility = View.GONE
        }
        caption.addView(
            timerText,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
                Gravity.END or Gravity.CENTER_VERTICAL,
            ).apply {
                marginEnd = dp(2)
            },
        )
        row.addView(
            caption,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                micRowHeight - micFrameSize,
                Gravity.TOP,
            ).apply { topMargin = micFrameSize },
        )

        rightKey = SideKeyView(context)
        row.addView(
            rightKey,
            FrameLayout.LayoutParams(
                sideKeyWidth,
                sideKeyHeight,
                Gravity.END or Gravity.TOP,
            ).apply { topMargin = sideTop },
        )
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
                listener?.onMicUp(false, false, false, true)
            }
        }
        micCircle = View(context).apply {
            setBackgroundResource(R.drawable.mic_circle)
            elevation = dp(5).toFloat()
        }
        micFrame.addView(
            micCircle,
            FrameLayout.LayoutParams(micCircleSize, micCircleSize, Gravity.CENTER),
        )

        micGlyph = RecordingMicView(context).apply {
            idleTint = color(R.color.mic_icon)
            activeTint = color(R.color.mic_record_icon)
            capsuleSurfaceColor = color(R.color.mic_record_surface)
            levelFillColor = color(R.color.mic_record_fill)
            elevation = dp(6).toFloat()
        }
        micFrame.addView(
            micGlyph,
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
            FrameLayout.LayoutParams(dp(44), dp(44), Gravity.CENTER),
        )

        micFrame.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    downAt = SystemClock.elapsedRealtime()
                    setHoldZones(false, false, false)
                    listener?.onMicDown()
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    if (!recording) return@setOnTouchListener true
                    val dx = event.rawX - downX
                    val dy = downY - event.rawY
                    val send =
                        sendSupported && dy > dp(56) && dy > kotlin.math.abs(dx)
                    val cancel = !send && dx < -dp(56)
                    val lock = !send && !locked && dx > dp(56)
                    if (cancel != cancelArmed || lock != lockArmed || send != sendArmed) {
                        tapFeedback()
                        setHoldZones(cancel, lock, send)
                        listener?.onMicMove(cancel, lock, send)
                    }
                    true
                }

                MotionEvent.ACTION_UP -> {
                    val quick = SystemClock.elapsedRealtime() - downAt < 250
                    listener?.onMicUp(cancelArmed, lockArmed, sendArmed, quick)
                    setHoldZones(false, false, false)
                    true
                }

                MotionEvent.ACTION_CANCEL -> {
                    listener?.onMicUp(true, false, false, false)
                    setHoldZones(false, false, false)
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
                        spaceKey.text = null
                        spaceKey.setCompoundDrawablesWithIntrinsicBounds(
                            R.drawable.ic_cursor_move,
                            0,
                            0,
                            0,
                        )
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
                    restoreSpaceLabel()
                }

                MotionEvent.ACTION_CANCEL -> {
                    spacePressed = false
                    tracking = false
                    restoreSpaceLabel()
                }
            }
            true
        }
        bar.addView(spaceKey, keyParams(3.4f))

        enterKey = textKey(context.getString(R.string.key_enter), function = true) {
            tapFeedback()
            listener?.onEnter()
        }
        // Fields that declare Send/Search/Done etc. still need a way to insert a line break.
        enterKey.setOnLongClickListener {
            if (AppSettings.keyHaptics(context)) {
                performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            }
            listener?.onNewline()
            true
        }
        bar.addView(enterKey, keyParams(2.0f))

        return bar
    }

    private fun restoreSpaceLabel() {
        spaceKey.setCompoundDrawablesWithIntrinsicBounds(0, 0, 0, 0)
        spaceKey.text = spaceLabel
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
            textSize = 16f
            typeface = regularTypeface
            letterSpacing = 0.01f
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
            rightKey.setDanger(false)
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
        sendArmed = false
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
        // Kept in the layout while recording so its weight still holds the
        // mic row against the bottom keys; the live words are up top now.
        transcriptScroll.visibility =
            if (recording || processing) View.INVISIBLE else View.VISIBLE
    }

    private fun updateTopBar() {
        if (!::modeDial.isInitialized || !::topHost.isInitialized) return
        val idle = !recording && !processing
        val showCorrection = idle && correctionAvailable
        modeDial.visibility = if (idle && !showCorrection) View.VISIBLE else View.GONE
        correctionChip.visibility = if (showCorrection) View.VISIBLE else View.GONE
        topControls.visibility = if (idle) View.VISIBLE else View.GONE
        topCaptionScroll.visibility = if (idle) View.GONE else View.VISIBLE

        // The caption band is taller than the button bar: with the controls
        // gone it can hold three lines of live text. The mic row sits below
        // it and does not move when the band grows.
        val target = if (idle) topBarHeight else topCaptionHeight
        val params = topHost.layoutParams
        if (params.height != target) {
            params.height = target
            topHost.layoutParams = params
        }
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

    private fun restoreMic() {
        if (::micGlyph.isInitialized) {
            micGlyph.visibility = View.VISIBLE
            micGlyph.iconTint = color(R.color.mic_icon)
            micGlyph.stop()
        }
        if (::micProgress.isInitialized) micProgress.visibility = View.GONE
        if (::sendButton.isInitialized) {
            sendButton.visibility = View.GONE
            sendButton.alpha = 0f
            sendButton.scaleX = 0.82f
            sendButton.scaleY = 0.82f
        }
        if (::micCircle.isInitialized) {
            micCircle.setBackgroundResource(R.drawable.mic_circle)
            micCircle.scaleX = 1f
            micCircle.scaleY = 1f
        }
        if (::micFrame.isInitialized) micFrame.alpha = 1f
        cancelArmed = false
        lockArmed = false
        sendArmed = false
    }

    private fun setMicAppearance(recording: Boolean) {
        // Keep the disc mounted and use a complete palette swap so crossing a
        // gesture zone can never leave the control half-painted.
        micCircle.visibility = View.VISIBLE
        micCircle.setBackgroundResource(
            if (recording) R.drawable.mic_circle_recording else R.drawable.mic_circle,
        )
        micGlyph.visibility = View.VISIBLE
        micGlyph.iconTint =
            color(if (recording) R.color.mic_record_icon else R.color.mic_icon)
        if (recording) micGlyph.start() else micGlyph.stop()
        micProgress.visibility = View.GONE
        updateMicLayerOrder()
    }

    private fun setMicProcessingAppearance() {
        micCircle.visibility = View.VISIBLE
        micCircle.setBackgroundResource(R.drawable.mic_circle_processing)
        micGlyph.stop()
        micGlyph.iconTint = color(R.color.mic_processing_icon)
        micGlyph.visibility = View.VISIBLE
        micProgress.indeterminateTintList =
            ColorStateList.valueOf(color(R.color.mic_processing_spinner))
        micProgress.visibility = View.VISIBLE
        updateMicLayerOrder()
    }

    private fun updateMicLayerOrder() {
        if (!::micCircle.isInitialized || !::micGlyph.isInitialized) {
            return
        }
        // The progress ring sits behind the mic so the familiar recording
        // glyph remains readable while transcription is running.
        micCircle.bringToFront()
        if (::micProgress.isInitialized) micProgress.bringToFront()
        micGlyph.bringToFront()
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

    /** Room for three lines of live text while the controls step aside. */
    private val topCaptionHeight: Int
        get() = dp(if (compact) 64 else 78)

    /** The touch target plus a compact one-line caption underneath. */
    private val micRowHeight: Int
        get() = micFrameSize + dp(if (compact) 24 else 28)

    private val bottomBarHeight: Int
        get() = dp(if (compact) 50 else 54)

    private val micFrameSize: Int
        get() = dp(if (compact) 76 else 96)

    private val micCircleSize: Int
        get() = dp(if (compact) 64 else 80)

    private val micIconSize: Int
        get() = dp(if (compact) 25 else 31)

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

/** A frame that asks for its parent's width but refuses to grow past a cap. */
@SuppressLint("ViewConstructor")
private class CappedFrameLayout(context: Context) : FrameLayout(context) {
    var maxWidth: Int = Int.MAX_VALUE

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = minOf(MeasureSpec.getSize(widthMeasureSpec), maxWidth)
        super.onMeasure(
            MeasureSpec.makeMeasureSpec(width, MeasureSpec.AT_MOST),
            heightMeasureSpec,
        )
    }
}
