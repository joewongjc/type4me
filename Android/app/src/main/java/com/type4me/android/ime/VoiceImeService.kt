package com.type4me.android.ime

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.inputmethodservice.InputMethodService
import android.os.SystemClock
import android.text.InputType
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.Toast
import androidx.core.content.ContextCompat
import com.type4me.android.MainActivity
import com.type4me.android.R
import com.type4me.android.asr.AsrException
import com.type4me.android.asr.BatchAsr
import com.type4me.android.asr.StreamingAsr
import com.type4me.android.asr.StreamingAsrSession
import com.type4me.android.audio.VoiceRecorder
import com.type4me.android.data.AppSettings
import com.type4me.android.data.AsrConfig
import com.type4me.android.data.ConfigStore
import com.type4me.android.data.Diagnostics
import com.type4me.android.data.HistoryStore
import com.type4me.android.data.VocabularyStore
import com.type4me.android.pipeline.SensitiveText
import com.type4me.android.llm.ChatClient
import com.type4me.android.llm.ChatException
import com.type4me.android.pipeline.Correction
import com.type4me.android.pipeline.CorrectionRequest
import com.type4me.android.pipeline.FieldContext
import com.type4me.android.pipeline.IntelliSense
import com.type4me.android.pipeline.Mode
import com.type4me.android.pipeline.ModeDefinition
import com.type4me.android.pipeline.Prompts
import com.type4me.android.pipeline.TextPipeline
import com.type4me.android.pipeline.TranslationValidator
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException

/**
 * The input method. Unlike the iOS keyboard extension, an Android IME may open
 * the microphone itself, so recording, recognition and text insertion all run
 * in this process.
 */
class VoiceImeService : InputMethodService(), KeyboardView.Listener {

    private enum class Phase { IDLE, RECORDING, LOCKED, PROCESSING }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val chat = ChatClient()

    private var keyboard: KeyboardView? = null
    private var recorder: VoiceRecorder? = null
    private var ticker: Job? = null
    private var work: Job? = null

    private var streamingSession: StreamingAsrSession? = null
    private var audioChannel: Channel<ByteArray>? = null
    private var senderJob: Job? = null
    @Volatile private var streamError: Throwable? = null
    private var streamPartial = ""

    @Volatile private var phase = Phase.IDLE
    private var locked = false
    private var startedAt = 0L
    private var pendingLockedTap = false
    private var startPackage: String? = null
    private var startFieldId = -1
    private var startSendSupported = false
    private var recordingMode = ModeDefinition.builtIn(Mode.QUICK)
    private var recordingHotwords: List<String> = emptyList()
    private var recordingConfig: AsrConfig? = null
    private var correctionRequest: CorrectionRequest? = null
    private var fieldContext: FieldContext? = null
    private var selectedText: String? = null
    private var correctionAttempts: List<String> = emptyList()
    private var lastCorrection: Pair<String, String>? = null

    private val editHistory = EditHistory()
    /** Deleted pieces, newest first, so a clear can put them back for undo. */
    private val recentDeletions = ArrayDeque<String>()
    private var clipboard: ClipboardManager? = null
    private var clipboardHandled: String? = null
    private var clipboardSuggestion: String? = null
    private var clipboardListening = false

    private val clipboardListener = ClipboardManager.OnPrimaryClipChangedListener {
        if (!AppSettings.keyboardClipboard(this) || phase != Phase.IDLE) return@OnPrimaryClipChangedListener
        val item = clipboard?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)
        val text = item?.coerceToText(this)?.toString()?.trim().orEmpty()
        if (text.isEmpty() || text == clipboardHandled) return@OnPrimaryClipChangedListener
        clipboardHandled = text
        clipboardSuggestion = text
        keyboard?.showClipboardSuggestion(text)
        scope.launch {
            delay(180_000)
            if (clipboardSuggestion == text) {
                clipboardSuggestion = null
                keyboard?.hideClipboardSuggestion()
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        clipboard = getSystemService(ClipboardManager::class.java)
        syncClipboardListener()
    }

    private fun syncClipboardListener() {
        val enabled = AppSettings.keyboardClipboard(this)
        if (enabled == clipboardListening) return
        if (enabled) {
            clipboard?.addPrimaryClipChangedListener(clipboardListener)
        } else {
            clipboard?.removePrimaryClipChangedListener(clipboardListener)
            clipboardSuggestion = null
            keyboard?.hideClipboardSuggestion()
        }
        clipboardListening = enabled
    }

    override fun onCreateInputView(): View {
        val view = KeyboardView(this)
        view.listener = this
        keyboard = view
        updateUndoState()
        return view
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        if (phase == Phase.RECORDING || phase == Phase.LOCKED) cancelRecording()
        selectedText = null
        clipboardSuggestion = null
        keyboard?.hideClipboardSuggestion()
        syncClipboardListener()
        refreshKeyboard(info)
        refreshSelection()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        if (phase == Phase.RECORDING || phase == Phase.LOCKED) cancelRecording()
        keyboard?.setCancelArmed(false)
        selectedText = null
        keyboard?.setCorrection(null)
        keyboard?.hideClipboardSuggestion()
        super.onFinishInputView(finishingInput)
    }

    override fun onUpdateSelection(
        oldSelStart: Int,
        oldSelEnd: Int,
        newSelStart: Int,
        newSelEnd: Int,
        candidatesStart: Int,
        candidatesEnd: Int,
    ) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        if (phase == Phase.IDLE) refreshSelection()
    }

    override fun onDestroy() {
        if (clipboardListening) clipboard?.removePrimaryClipChangedListener(clipboardListener)
        clipboardListening = false
        clipboard = null
        // Releasing the microphone and the socket can block; keep teardown
        // off the main thread so the IME can be destroyed promptly.
        val record = recorder
        recorder = null
        if (record != null) {
            Thread { runCatching { record.stop() } }.start()
        }
        ticker?.cancel()
        work?.cancel()
        audioChannel?.close()
        senderJob?.cancel()
        val session = streamingSession
        streamingSession = null
        if (session != null) {
            Thread {
                runBlocking { withTimeoutOrNull(1_000) { runCatching { session.cancel() } } }
            }.start()
        }
        scope.cancel()
        super.onDestroy()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // The input view outlives the configuration change, so its
        // hard-coded labels have to be re-read from the new resources.
        keyboard?.refreshStaticText()
        if (phase == Phase.IDLE) refreshKeyboard(currentInputEditorInfo)
    }

    override fun onEvaluateFullscreenMode(): Boolean = false

    override fun onComputeInsets(outInsets: Insets) {
        super.onComputeInsets(outInsets)
        outInsets.touchableInsets = Insets.TOUCHABLE_INSETS_CONTENT
        outInsets.contentTopInsets = outInsets.visibleTopInsets
    }

    // MARK: - Mic

    override fun onMicDown() {
        when (phase) {
            Phase.IDLE -> beginRecording()
            Phase.LOCKED -> pendingLockedTap = true
            else -> Unit
        }
    }

    override fun onMicMove(cancelArmed: Boolean, lockArmed: Boolean, sendArmed: Boolean) {
        if (phase == Phase.RECORDING || phase == Phase.LOCKED) {
            keyboard?.setCancelArmed(cancelArmed)
        }
    }

    override fun onMicUp(
        cancelArmed: Boolean,
        lockArmed: Boolean,
        sendArmed: Boolean,
        quickTap: Boolean,
    ) {
        when (phase) {
            Phase.RECORDING -> when {
                cancelArmed -> cancelRecording()
                sendArmed -> finishRecording(sendAfterDelivery = true)
                lockArmed || quickTap -> {
                    locked = true
                    phase = Phase.LOCKED
                    keyboard?.setRecording(elapsedSeconds(), 0f, true)
                    haptic()
                }

                else -> finishRecording()
            }

            Phase.LOCKED -> {
                when {
                    cancelArmed -> cancelRecording()
                    sendArmed -> finishRecording(sendAfterDelivery = true)
                    pendingLockedTap -> finishRecording()
                }
                pendingLockedTap = false
            }

            else -> Unit
        }
        keyboard?.setCancelArmed(false)
    }

    override fun onCancelRecording() {
        if (phase == Phase.RECORDING || phase == Phase.LOCKED) cancelRecording()
    }

    override fun onLockRecording() {
        if (phase != Phase.RECORDING) return
        locked = true
        phase = Phase.LOCKED
        keyboard?.setRecording(elapsedSeconds(), 0f, true)
        haptic()
    }

    override fun onFinishRecording() {
        if (phase == Phase.LOCKED) finishRecording()
    }

    override fun onSendRecording() {
        if (phase == Phase.RECORDING || phase == Phase.LOCKED) {
            finishRecording(sendAfterDelivery = true)
        }
    }

    private fun beginRecording() {
        if (isPasswordField(currentInputEditorInfo)) {
            keyboard?.showError(getString(R.string.kb_password_field))
            return
        }
        if (!hasMicrophone()) {
            Diagnostics.add(this, "录音失败：没有麦克风权限")
            keyboard?.showError(getString(R.string.kb_mic_denied))
            openSettings(requestMicrophone = true)
            return
        }
        val config = ConfigStore.asr(this)
        if (!config.isValid) {
            Diagnostics.add(this, "录音失败：识别服务未配置")
            keyboard?.showError(getString(R.string.kb_no_config))
            return
        }
        if (!AppSettings.aiConsent(this)) {
            Diagnostics.add(this, "录音被拦住：还没有同意第三方 AI 服务")
            keyboard?.showError(getString(R.string.kb_ai_consent))
            openSettings(requestMicrophone = false)
            return
        }
        if (phase != Phase.IDLE) return

        recordingMode = keyboard?.selectedMode() ?: ConfigStore.mode(this)
        fieldContext = readFieldContext()
        correctionRequest = selectedText?.takeIf { it.isNotBlank() }?.let { selected ->
            val again = lastCorrection?.second == selected
            val context = fieldContext?.takeUnless { it.isSensitive }
            CorrectionRequest(
                selected = selected,
                before = context?.before.orEmpty().let {
                    if (again) it.dropLast(selected.length) else it
                },
                after = context?.after.orEmpty(),
                attempts = if (again) correctionAttempts else emptyList(),
                again = again,
            )
        }
        recordingHotwords = VocabularyStore.hotwords(this)
        recordingConfig = config
        startPackage = currentInputEditorInfo?.packageName?.toString()
        startFieldId = currentInputEditorInfo?.fieldId ?: -1
        startSendSupported = ChatSendPolicy.canSwipeSend(currentInputEditorInfo)
        streamError = null
        streamPartial = ""
        keyboard?.setPartial("")

        val channel = if (config.isStreaming) Channel<ByteArray>(Channel.UNLIMITED) else null
        audioChannel = channel
        if (channel != null) {
            val session = StreamingAsr.create(
                config = config,
                onPartial = { text ->
                    if (phase != Phase.IDLE) {
                        scope.launch {
                            streamPartial = text
                            keyboard?.setPartial(text)
                        }
                    }
                },
                onError = { error -> streamError = error },
            )
            streamingSession = session
            if (session != null) {
                senderJob = scope.launch(Dispatchers.IO) {
                    try {
                        session.connect(config, recordingHotwords)
                        for (chunk in channel) session.send(chunk)
                    } catch (error: Exception) {
                        if (error !is kotlinx.coroutines.CancellationException) {
                            streamError = error
                        }
                    }
                }
            }
        }

        val record = VoiceRecorder(
            context = this,
            onLevel = { level -> scope.launch { keyboard?.setLevel(level) } },
            onLimitReached = {
                scope.launch {
                    if (phase == Phase.RECORDING || phase == Phase.LOCKED) finishRecording()
                }
            },
            onAudio = { chunk -> channel?.trySend(chunk) },
        )
        if (!record.start()) {
            cancelStreaming()
            Diagnostics.add(this, "录音失败：麦克风 ${record.lastError ?: "unavailable"}")
            keyboard?.showError(
                getString(
                    if (record.lastError == "busy") R.string.kb_mic_busy
                    else R.string.kb_mic_denied,
                ),
            )
            return
        }

        recorder = record
        locked = false
        phase = Phase.RECORDING
        startedAt = SystemClock.elapsedRealtime()
        Diagnostics.add(this, "开始录音 ${config.providerId}")
        keyboard?.setRecording(0, 0f, false)
        haptic()

        ticker?.cancel()
        ticker = scope.launch {
            while (isActive && (phase == Phase.RECORDING || phase == Phase.LOCKED)) {
                keyboard?.setElapsed(elapsedSeconds())
                delay(200)
            }
        }
    }

    private fun finishRecording(sendAfterDelivery: Boolean = false) {
        val record = recorder ?: return
        recorder = null
        ticker?.cancel()
        ticker = null
        phase = Phase.PROCESSING

        val mode = recordingMode
        val correction = correctionRequest
        val field = fieldContext
        val config = recordingConfig ?: ConfigStore.asr(this)
        val channel = audioChannel
        val sender = senderJob
        val session = streamingSession
        val hotwords = recordingHotwords

        keyboard?.setProcessing(
            when {
                correction != null -> R.string.kb_correcting
                mode.usesTextModel -> R.string.kb_processing_polish
                else -> R.string.kb_processing
            },
        )
        haptic()

        work?.cancel()
        work = scope.launch {
            try {
                val pcm = withContext(Dispatchers.IO) { record.stop() }
                val raw = if (config.isStreaming) {
                    channel?.close()
                    val joined = withTimeoutOrNull(12_000) { sender?.join(); Unit } != null
                    if (!joined) sender?.cancel()
                    val text = try {
                        withTimeoutOrNull(15_000) { session?.finish() }
                    } catch (error: Exception) {
                        streamError = error
                        null
                    } ?: streamPartial
                    if (text.isBlank()) throw streamError ?: AsrException(getString(R.string.kb_no_speech))
                    text.trim()
                } else {
                    if (pcm.size < 4_000) throw AsrException(getString(R.string.kb_too_short))
                    BatchAsr.transcribe(
                        config = config,
                        pcm = pcm,
                        hotwords = hotwords,
                    ).trim()
                }
                if (raw.isEmpty()) throw AsrException(getString(R.string.kb_no_speech))

                // Snippets run before the mode, so a model sees the corrected words.
                val input = TextPipeline.applySnippets(raw, VocabularyStore.snippets(this@VoiceImeService))

                if (correction != null) {
                    handleCorrection(correction, input)
                } else {
                    val (processed, note) = processMode(mode, input, field)
                    val output = TextPipeline.format(
                        processed,
                        this@VoiceImeService,
                        mode.punctuation,
                    )
                    val delivered = deliver(output)
                    if (delivered && sendAfterDelivery) performSendAction()
                    withContext(Dispatchers.IO) {
                        HistoryStore.add(
                            this@VoiceImeService,
                            createdAt = System.currentTimeMillis(),
                            mode = mode.id,
                            rawText = raw,
                            finalText = output,
                            delivered = delivered,
                            note = note,
                        )
                    }
                    keyboard?.showDone(
                        if (delivered) note else getString(R.string.kb_copied),
                    )
                    Diagnostics.add(
                        this@VoiceImeService,
                        "识别完成 ${output.length} 字，${if (delivered) "已插入" else "已复制"}",
                    )
                }
                phase = Phase.IDLE
                // Correction needs a window for the Remember action. Normal
                // dictation returns to the idle hint immediately, without a
                // transient "Done" state delaying the next action.
                if (correction != null) {
                    scheduleIdle(5_000)
                } else {
                    refreshKeyboard(currentInputEditorInfo)
                    refreshSelection()
                }
            } catch (error: CancellationException) {
                // The service is going away; do not report this as a failure
                // or write into an input connection that may be gone.
                throw error
            } catch (error: Exception) {
                cancelStreaming()
                Diagnostics.add(this@VoiceImeService, "识别失败：${friendly(error)}")
                returnFinish(friendly(error))
            } finally {
                withContext(NonCancellable) {
                    channel?.close()
                    sender?.cancel()
                    runCatching { session?.cancel() }
                }
                if (streamingSession === session) {
                    streamingSession = null
                    audioChannel = null
                    senderJob = null
                }
            }
        }
    }

    private suspend fun processMode(
        mode: ModeDefinition,
        input: String,
        field: FieldContext?,
    ): Pair<String, String?> {
        if (mode.kind == Mode.QUICK) return input to null
        if (mode.shortTextExemption > 0 && input.trim().length < mode.shortTextExemption) {
            return input to null
        }
        val llm = ConfigStore.llm(this)
            ?: return input to getString(R.string.kb_llm_fallback)
        val request = Prompts.request(this, mode, input, field)
            ?: return input to null
        return try {
            var output = chat.complete(llm, request)
            if (mode.kind == Mode.TRANSLATE) {
                val checked = TranslationValidator.check(
                    output = output,
                    target = mode.translationTarget,
                    raw = input,
                )
                if (checked.retry) {
                    output = chat.complete(llm, Prompts.translationRetry(mode.translationTarget, input))
                    val second = TranslationValidator.check(
                        output = output,
                        target = mode.translationTarget,
                        raw = input,
                    )
                    if (second.retry) return input to getString(R.string.kb_translation_fallback)
                }
            }
            val checked = if (mode.kind == Mode.INTELLI_SENSE) {
                IntelliSense.check(input, output)
            } else {
                output
            }
            TextPipeline.clean(checked) to null
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            input to getString(R.string.kb_llm_fallback)
        }
    }

    private suspend fun handleCorrection(request: CorrectionRequest, spoken: String) {
        val llm = ConfigStore.llm(this)
        val chinese = resources.configuration.locales[0].language == "zh"
        val occurrences = Correction.occurrences(request.before, request.selected, request.after)
        val result = if (llm != null) {
            val raw = try {
                chat.complete(llm, Correction.request(request, spoken, chinese))
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                null
            }
            raw?.let { Correction.resolve(it, request.selected, request.attempts, occurrences.size) }
        } else {
            null
        }
        val replacement = result?.replacement ?: spoken.takeIf { it != request.selected }

        if (replacement.isNullOrBlank()) {
            keyboard?.showError(getString(R.string.kb_correct_failed))
            return
        }

        val connection = currentInputConnection
        val current = runCatching { connection?.getSelectedText(0)?.toString() }.getOrNull()
        val before = connection?.getTextBeforeCursor(10_000, 0)?.toString().orEmpty()
        val inPlace = if (request.again) {
            current.isNullOrEmpty() && before.endsWith(request.selected)
        } else {
            current == request.selected
        }
        if (connection == null || !inPlace) {
            copyToClipboard(replacement)
            keyboard?.showError(getString(R.string.kb_copied))
            return
        }
        if (request.again) {
            connection.deleteSurroundingTextInCodePoints(
                request.selected.codePointCount(0, request.selected.length),
                0,
            )
        }
        connection.commitText(replacement, 1)
        connection.finishComposingText()
        editHistory.record(EditAction.Correct(request.selected, replacement))
        recentDeletions.clear()
        correctionAttempts = request.attempts + request.selected
        lastCorrection = request.selected to replacement
        updateUndoState()

        val also = result?.also.orEmpty()
        if (also.isNotEmpty()) {
            applyOtherOccurrences(
                connection = connection,
                occurrences = occurrences,
                also = also,
                old = request.selected,
                replacement = replacement,
            )
        }
        val otherCount = also.count { number ->
            occurrences.firstOrNull { it.number == number } != null
        }
        val shown = if (replacement.length > 14) replacement.take(14) + "…" else replacement
        val canRemember = isHotwordSized(replacement)
        keyboard?.showCorrectionDone(
            message = if (otherCount > 0) {
                getString(R.string.kb_correct_done_many, shown, otherCount + 1)
            } else {
                getString(R.string.kb_correct_done, shown)
            },
            rememberWord = replacement.takeIf { canRemember },
        )
    }

    /**
     * Replaces the same mistake elsewhere. The keyboard cannot address text
     * by absolute offset, so the cursor is walked there with arrow keys and
     * the selection is made with shift+arrow. Positions are relative to the
     * cursor after the main replacement.
     */
    private fun applyOtherOccurrences(
        connection: InputConnection,
        occurrences: List<com.type4me.android.pipeline.CorrectionOccurrence>,
        also: List<Int>,
        old: String,
        replacement: String,
    ) {
        val oldLength = old.length
        if (oldLength <= 0) return
        val delta = replacement.length - oldLength
        var cursor = 0
        var shift = 0
        val targets = also.mapNotNull { number ->
            occurrences.firstOrNull { it.number == number }
        }.map { it.offset - replacement.length }.sorted()
        targets.forEach { base ->
            val position = base + shift
            val steps = position - cursor
            if (steps != 0) {
                val key = if (steps < 0) KeyEvent.KEYCODE_DPAD_LEFT else KeyEvent.KEYCODE_DPAD_RIGHT
                repeat(kotlin.math.abs(steps)) {
                    connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, key))
                    connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, key))
                }
                cursor = position
            }
            val next = runCatching { connection.getTextAfterCursor(oldLength, 0)?.toString() }
                .getOrNull()
            if (next.isNullOrEmpty() || !next.startsWith(old)) {
                // The text moved; stop rather than change the wrong word.
                return
            }
            repeat(oldLength) {
                connection.sendKeyEvent(
                    KeyEvent(
                        SystemClock.uptimeMillis(),
                        SystemClock.uptimeMillis(),
                        KeyEvent.ACTION_DOWN,
                        KeyEvent.KEYCODE_DPAD_RIGHT,
                        0,
                        KeyEvent.META_SHIFT_ON,
                    ),
                )
                connection.sendKeyEvent(
                    KeyEvent(
                        SystemClock.uptimeMillis(),
                        SystemClock.uptimeMillis(),
                        KeyEvent.ACTION_UP,
                        KeyEvent.KEYCODE_DPAD_RIGHT,
                        0,
                        KeyEvent.META_SHIFT_ON,
                    ),
                )
            }
            connection.commitText(replacement, 1)
            cursor = position + replacement.length
            shift += delta
        }
    }

    private fun isHotwordSized(text: String): Boolean {
        if (text.any { !it.isLetterOrDigit() && !it.isWhitespace() }) return false
        val ideographic = text.any {
            Character.UnicodeScript.of(it.code) == Character.UnicodeScript.HAN
        }
        return if (ideographic) {
            text.count { !it.isWhitespace() } <= 5
        } else {
            text.trim().split(Regex("\\s+")).size <= 2
        }
    }

    override fun onRememberCorrection(word: String) {
        val current = VocabularyStore.hotwords(this)
        if (current.none { it.equals(word, ignoreCase = true) }) {
            VocabularyStore.save(this, listOf(word) + current, VocabularyStore.snippets(this))
        }
        keyboard?.showDone(getString(R.string.kb_correct_remembered))
    }

    private fun deliver(text: String): Boolean {
        val info = currentInputEditorInfo
        val connection = currentInputConnection
        val sameField = startPackage == null ||
            (info?.packageName?.toString() == startPackage &&
                (startFieldId == -1 || info?.fieldId == startFieldId))
        if (connection == null || !sameField || isPasswordField(info)) {
            copyToClipboard(text)
            return false
        }
        val replaced = connection.getSelectedText(0)?.toString().orEmpty()
        connection.commitText(text, 1)
        connection.finishComposingText()
        editHistory.record(EditAction.Insert(text, replaced))
        recentDeletions.clear()
        keyboard?.hideClipboardSuggestion()
        updateUndoState()
        return true
    }

    private fun performSendAction() {
        val connection = currentInputConnection ?: return
        val action = ChatSendPolicy.sendAction(currentInputEditorInfo, startSendSupported) ?: return
        connection.performEditorAction(action)
        editHistory.invalidate()
        recentDeletions.clear()
        updateUndoState()
    }

    private fun cancelRecording() {
        val record = recorder ?: return
        recorder = null
        ticker?.cancel()
        ticker = null
        phase = Phase.IDLE
        locked = false
        pendingLockedTap = false
        correctionRequest = null
        fieldContext = null
        cancelStreaming()
        keyboard?.setPartial("")
        keyboard?.showIdle()
        // Tear the microphone down even if this service is being destroyed
        // before the coroutine scope gets to run.
        Thread { runCatching { record.stop() } }.start()
    }

    private fun cancelStreaming() {
        audioChannel?.close()
        audioChannel = null
        senderJob?.cancel()
        senderJob = null
        val session = streamingSession
        streamingSession = null
        if (session != null) {
            scope.launch(Dispatchers.IO) { runCatching { session.cancel() } }
        }
    }

    private fun copyToClipboard(text: String) {
        val clipboard = getSystemService(ClipboardManager::class.java)
        clipboard.setPrimaryClip(ClipData.newPlainText(getString(R.string.app_name), text))
        clipboardHandled = text
        clipboardSuggestion = null
        keyboard?.hideClipboardSuggestion()
        Toast.makeText(this, R.string.kb_copied, Toast.LENGTH_SHORT).show()
    }

    private fun returnFinish(message: String) {
        keyboard?.showError(message)
        keyboard?.setPartial("")
        phase = Phase.IDLE
        scheduleIdle(3_000)
    }

    private fun scheduleIdle(delayMillis: Long = 1_500) {
        scope.launch {
            delay(delayMillis)
            if (phase == Phase.IDLE) {
                refreshKeyboard(currentInputEditorInfo)
                refreshSelection()
            }
        }
    }

    // MARK: - Keys

    override fun onDelete() {
        val connection = currentInputConnection ?: return
        val selected = connection.getSelectedText(0)?.toString()
        if (!selected.isNullOrEmpty()) {
            recentDeletions.addFirst(selected)
            connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DEL))
            connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DEL))
        } else {
            connection.getTextBeforeCursor(2, 0)?.toString()?.let { before ->
                if (before.isNotEmpty()) recentDeletions.addFirst(before.takeLast(1))
            }
            connection.deleteSurroundingTextInCodePoints(1, 0)
        }
        while (recentDeletions.size > 200) recentDeletions.removeLast()
        forgetCorrection()
        editHistory.invalidate()
        keyboard?.hideClipboardSuggestion()
        updateUndoState()
    }

    override fun onClear() {
        val connection = currentInputConnection ?: return
        val restore = recentDeletions.joinToString("")
        if (restore.isNotEmpty()) connection.commitText(restore, 1)
        val before = connection.getTextBeforeCursor(100_000, 0)?.toString().orEmpty()
        val after = connection.getTextAfterCursor(100_000, 0)?.toString().orEmpty()
        if (before.isEmpty() && after.isEmpty()) {
            recentDeletions.clear()
            return
        }
        val cursor = before.length
        val beforeCount = before.codePointCount(0, before.length)
        val afterCount = after.codePointCount(0, after.length)
        connection.deleteSurroundingTextInCodePoints(beforeCount, afterCount)
        editHistory.record(EditAction.Clear(before + after, cursor, beforeCount, afterCount))
        recentDeletions.clear()
        forgetCorrection()
        updateUndoState()
        keyboard?.showDone(getString(R.string.kb_cleared))
    }

    override fun onUndo() {
        val connection = currentInputConnection ?: return
        val action = editHistory.takeUndo() ?: return
        val before = connection.getTextBeforeCursor(100_000, 0)?.toString().orEmpty()
        val applied = when (action) {
            is EditAction.Insert -> {
                if (!before.endsWith(action.text)) {
                    false
                } else {
                    connection.deleteSurroundingTextInCodePoints(
                        action.text.codePointCount(0, action.text.length),
                        0,
                    )
                    if (action.replaced.isNotEmpty()) connection.commitText(action.replaced, 1)
                    true
                }
            }

            is EditAction.Correct -> {
                if (!before.endsWith(action.new)) {
                    false
                } else {
                    connection.deleteSurroundingTextInCodePoints(
                        action.new.codePointCount(0, action.new.length),
                        0,
                    )
                    connection.commitText(action.old, 1)
                    true
                }
            }

            is EditAction.Clear -> {
                connection.commitText(action.text, 1)
                val back = action.text.length - action.cursor
                repeat(back.coerceAtLeast(0)) {
                    connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_LEFT))
                    connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DPAD_LEFT))
                }
                true
            }
        }
        if (!applied) {
            editHistory.invalidate()
            keyboard?.showError(getString(R.string.kb_undo_failed))
        } else {
            keyboard?.showDone(getString(R.string.kb_undone))
        }
        updateUndoState()
    }

    override fun onRedo() {
        val connection = currentInputConnection ?: return
        val action = editHistory.takeRedo() ?: return
        val before = connection.getTextBeforeCursor(100_000, 0)?.toString().orEmpty()
        val applied = when (action) {
            is EditAction.Insert -> {
                if (!before.endsWith(action.replaced)) {
                    false
                } else {
                    connection.deleteSurroundingTextInCodePoints(
                        action.replaced.codePointCount(0, action.replaced.length),
                        0,
                    )
                    connection.commitText(action.text, 1)
                    true
                }
            }

            is EditAction.Correct -> {
                if (!before.endsWith(action.old)) {
                    false
                } else {
                    connection.deleteSurroundingTextInCodePoints(
                        action.old.codePointCount(0, action.old.length),
                        0,
                    )
                    connection.commitText(action.new, 1)
                    true
                }
            }

            is EditAction.Clear -> {
                connection.deleteSurroundingTextInCodePoints(action.beforeCount, action.afterCount)
                true
            }
        }
        if (!applied) {
            editHistory.invalidate()
            keyboard?.showError(getString(R.string.kb_undo_failed))
        } else {
            keyboard?.showDone(getString(R.string.kb_redone))
        }
        updateUndoState()
    }

    override fun onCursorMove(step: Int) {
        val connection = currentInputConnection ?: return
        val key = if (step < 0) KeyEvent.KEYCODE_DPAD_LEFT else KeyEvent.KEYCODE_DPAD_RIGHT
        repeat(kotlin.math.abs(step)) {
            connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, key))
            connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, key))
        }
        recentDeletions.clear()
    }

    override fun onSpace() {
        commitTyping(" ")
    }

    override fun onPunctuation(text: String) {
        commitTyping(text)
    }

    override fun onTogglePunctuationWidth() {
        AppSettings.setFullWidthPunctuation(this, !AppSettings.fullWidthPunctuation(this))
        keyboard?.refreshPunctuationLabel()
    }

    private fun commitTyping(text: String) {
        currentInputConnection?.commitText(text, 1)
        forgetCorrection()
        editHistory.invalidate()
        recentDeletions.clear()
        keyboard?.hideClipboardSuggestion()
        updateUndoState()
    }

    private fun forgetCorrection() {
        lastCorrection = null
        correctionAttempts = emptyList()
        selectedText = null
        keyboard?.setCorrection(null)
    }

    override fun onEnter() {
        // In a send-capable chat field, tapping the main Send key while the
        // mic is locked should finish the current recording first, then deliver
        // its transcript and trigger the editor action as one operation.
        if (phase == Phase.LOCKED && enterLabel(currentInputEditorInfo) == R.string.key_send) {
            finishRecording(sendAfterDelivery = true)
            return
        }
        val connection = currentInputConnection ?: return
        val action = currentInputEditorInfo?.imeOptions
            ?.and(EditorInfo.IME_MASK_ACTION)
            ?: EditorInfo.IME_ACTION_NONE
        if (action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED) {
            connection.performEditorAction(action)
        } else {
            connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
            connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
        }
        forgetCorrection()
        editHistory.invalidate()
        recentDeletions.clear()
        keyboard?.hideClipboardSuggestion()
        updateUndoState()
    }

    override fun onNewline() {
        // commitText inserts a literal newline even when the field's IME action is Send/Search/Done.
        commitTyping("\n")
    }

    override fun onGlobe() {
        val switched = android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P &&
            switchToNextInputMethod(false)
        if (!switched) {
            getSystemService(InputMethodManager::class.java).showInputMethodPicker()
        }
    }

    override fun onHideKeyboard() {
        requestHideSelf(0)
    }

    override fun onSettings() {
        openSettings(requestMicrophone = false)
    }

    override fun onModeSelected(mode: ModeDefinition) {
        ConfigStore.setMode(this, mode)
        recentDeletions.clear()
        forgetCorrection()
        editHistory.invalidate()
        updateUndoState()
    }

    override fun onPasteClipboard(text: String) {
        val connection = currentInputConnection ?: return
        val replaced = connection.getSelectedText(0)?.toString().orEmpty()
        connection.commitText(text, 1)
        editHistory.record(EditAction.Insert(text, replaced))
        recentDeletions.clear()
        forgetCorrection()
        clipboardHandled = text
        clipboardSuggestion = null
        keyboard?.hideClipboardSuggestion()
        updateUndoState()
    }

    override fun onDismissClipboard() {
        clipboardHandled = clipboardSuggestion
        clipboardSuggestion = null
    }

    private fun updateUndoState() {
        keyboard?.setUndoState(editHistory.canUndo, editHistory.canRedo)
    }

    // MARK: - Helpers

    private fun refreshKeyboard(info: EditorInfo?) {
        val modes = ConfigStore.enabledModes(this)
        val mode = ConfigStore.mode(this)
            .takeIf { saved -> modes.any { it.id == saved.id } }
            ?: modes.first()
        ConfigStore.setMode(this, mode)
        keyboard?.refresh(
            modes = modes,
            mode = mode,
            hasService = ConfigStore.hasAsrConfig(this),
            hasMicrophone = hasMicrophone(),
            hasTextModel = ConfigStore.llm(this) != null,
            enterLabel = enterLabel(info),
            sendSupported = ChatSendPolicy.canSwipeSend(info),
            correction = selectedText,
        )
        updateUndoState()
    }

    private fun refreshSelection() {
        if (phase != Phase.IDLE) return
        val connection = currentInputConnection
        if (connection == null || isPasswordField(currentInputEditorInfo)) {
            selectedText = null
            keyboard?.setCorrection(null)
            return
        }
        val text = runCatching { connection.getSelectedText(0)?.toString() }.getOrNull()
            ?.takeIf { it.isNotBlank() && !SensitiveText.contains(it) }
        if (text != null) {
            selectedText = text
            keyboard?.setCorrection(text)
            return
        }
        // A correction leaves the word just before the cursor; holding the
        // mic again tries another spelling.
        val previous = lastCorrection?.second
        if (previous != null) {
            val before = runCatching { connection.getTextBeforeCursor(previous.length, 0)?.toString() }
                .getOrNull()
            if (before == previous) {
                selectedText = previous
                keyboard?.setCorrection(previous)
                return
            }
        }
        selectedText = null
        keyboard?.setCorrection(null)
    }

    private fun readFieldContext(): FieldContext {
        val info = currentInputEditorInfo
        val password = isPasswordField(info)
        val allowed = AppSettings.fieldContext(this)
        val connection = currentInputConnection
        val before = if (password || !allowed) {
            ""
        } else {
            runCatching { connection?.getTextBeforeCursor(FieldContext.BEFORE_LIMIT, 0)?.toString() }
                .getOrNull().orEmpty()
        }
        val after = if (password || !allowed) {
            ""
        } else {
            runCatching { connection?.getTextAfterCursor(FieldContext.AFTER_LIMIT, 0)?.toString() }
                .getOrNull().orEmpty()
        }
        val sensitive = password || SensitiveText.contains(before + after)
        return FieldContext(
            before = if (sensitive) "" else before.takeLast(FieldContext.BEFORE_LIMIT),
            after = if (sensitive) "" else after.take(FieldContext.AFTER_LIMIT),
            inputType = info?.inputType ?: 0,
            imeAction = info?.imeOptions?.and(EditorInfo.IME_MASK_ACTION) ?: 0,
            isSensitive = sensitive,
        )
    }

    private fun hasMicrophone(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun isPasswordField(info: EditorInfo?): Boolean {
        val type = info?.inputType ?: return false
        val kind = type and InputType.TYPE_MASK_CLASS
        val variation = type and InputType.TYPE_MASK_VARIATION
        return when (kind) {
            InputType.TYPE_CLASS_TEXT -> variation in setOf(
                InputType.TYPE_TEXT_VARIATION_PASSWORD,
                InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
                InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
            )

            InputType.TYPE_CLASS_NUMBER -> variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> false
        }
    }

    private fun elapsedSeconds(): Int =
        ((SystemClock.elapsedRealtime() - startedAt) / 1_000L).toInt()

    private fun enterLabel(info: EditorInfo?): Int {
        return when (info?.imeOptions?.and(EditorInfo.IME_MASK_ACTION)) {
            EditorInfo.IME_ACTION_SEND -> R.string.key_send
            EditorInfo.IME_ACTION_SEARCH -> R.string.key_search
            EditorInfo.IME_ACTION_GO -> R.string.key_go
            EditorInfo.IME_ACTION_DONE -> R.string.key_done
            EditorInfo.IME_ACTION_NEXT -> R.string.key_next
            else -> R.string.key_enter
        }
    }

    private fun openSettings(requestMicrophone: Boolean) {
        val intent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(MainActivity.EXTRA_OPEN_SETTINGS, true)
            .putExtra(MainActivity.EXTRA_REQUEST_MICROPHONE, requestMicrophone)
        startActivity(intent)
    }

    private fun friendly(error: Throwable): String {
        val detail = error.message?.take(180)?.takeIf { it.isNotBlank() }
        return when (error) {
            is AsrException, is ChatException -> detail ?: getString(R.string.kb_no_speech)
            is IOException -> getString(R.string.kb_network, detail ?: error.javaClass.simpleName)
            else -> detail ?: error.javaClass.simpleName
        }
    }

    private fun haptic() {
        if (AppSettings.keyHaptics(this)) {
            keyboard?.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        }
    }
}
