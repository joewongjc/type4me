package com.type4me.android

import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.lifecycle.lifecycleScope
import com.google.android.material.button.MaterialButton
import com.type4me.android.ui.applyNavBarTopInset
import com.type4me.android.data.ImportSelection
import com.type4me.android.data.PendingImport
import com.type4me.android.data.Presets
import com.type4me.android.data.TransferEndpoint
import com.type4me.android.data.TransferImporter
import com.type4me.android.data.TransferMode
import com.type4me.android.data.TransferPayload
import com.type4me.android.ui.color
import com.type4me.android.ui.dp
import com.type4me.android.ui.pageToolbar
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Shows what a scanned Mac setup contains and lets the user pick what to take. */
class ImportActivity : AppCompatActivity() {

    private lateinit var selection: ImportSelection
    private var scroll: ScrollView? = null
    private var importButton: MaterialButton? = null
    private var importJob: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val payload = PendingImport.payload
        if (payload == null) {
            PendingImport.clear()
            finish()
            return
        }
        selection = savedInstanceState?.let { restoreSelection(it, payload) }
            ?: ImportSelection.all(payload)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(color(R.color.screen_bg))
        }
        val toolbar = pageToolbar(R.string.import_title) { cancelImport() }
        root.addView(toolbar)
        onBackPressedDispatcher.addCallback(
            object : androidx.activity.OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    isEnabled = false
                    cancelImport()
                }
            },
        )

        val scroll = ScrollView(this)
        this.scroll = scroll
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), 0, dp(16), dp(32))
        }
        content.addView(
            TextView(this).apply {
                text = getString(
                    R.string.import_from,
                    payload.sourceName ?: getString(R.string.import_source_unknown),
                )
                textSize = 14f
                setTextColor(color(R.color.ink_secondary))
                setPadding(dp(4), 0, dp(4), dp(10))
            },
        )

        val asrs = payload.allAsrs
        if (asrs.isNotEmpty()) {
            content.addView(section(getString(R.string.import_speech)))
            asrs.forEach { endpoint ->
                val row = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                }
                val check = CheckBox(this).apply {
                    text = endpoint.displayName()
                    isChecked = endpoint.provider in selection.asrs
                    setTextColor(color(R.color.ink))
                    setOnCheckedChangeListener { _, checked ->
                        if (checked) selection.asrs.add(endpoint.provider)
                        else {
                            selection.asrs.remove(endpoint.provider)
                            if (selection.activeAsr == endpoint.provider) {
                                selection.activeAsr = selection.asrs.firstOrNull()
                            }
                        }
                    }
                }
                row.addView(check, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                row.addView(defaultButton(endpoint.provider, selection.activeAsr) {
                    selection.activeAsr = endpoint.provider
                    selection.asrs.add(endpoint.provider)
                })
                content.addView(row)
            }
        }

        val llms = payload.allLlms
        if (llms.isNotEmpty()) {
            content.addView(section(getString(R.string.import_models)))
            llms.forEach { endpoint ->
                val row = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                }
                val check = CheckBox(this).apply {
                    text = endpoint.displayName()
                    isChecked = endpoint.provider in selection.llms
                    setTextColor(color(R.color.ink))
                    setOnCheckedChangeListener { _, checked ->
                        if (checked) selection.llms.add(endpoint.provider)
                        else {
                            selection.llms.remove(endpoint.provider)
                            if (selection.activeLlm == endpoint.provider) {
                                selection.activeLlm = selection.llms.firstOrNull()
                            }
                        }
                    }
                }
                row.addView(check, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                row.addView(defaultButton(endpoint.provider, selection.activeLlm) {
                    selection.activeLlm = endpoint.provider
                    selection.llms.add(endpoint.provider)
                })
                content.addView(row)
            }
        }

        val modes = payload.modes
        if (modes.isNotEmpty()) {
            content.addView(section(getString(R.string.import_modes_section)))
            modes.forEach { mode ->
                content.addView(
                    CheckBox(this).apply {
                        text = mode.displayName()
                        isChecked = mode.id in selection.modes
                        setTextColor(color(R.color.ink))
                        setOnCheckedChangeListener { _, checked ->
                            if (checked) selection.modes.add(mode.id) else selection.modes.remove(mode.id)
                        }
                    },
                )
            }
        }

        if (!payload.hotwords.isNullOrEmpty() || !payload.snippets.isNullOrEmpty()) {
            content.addView(section(getString(R.string.import_vocabulary)))
            if (!payload.hotwords.isNullOrEmpty()) {
                content.addView(
                    CheckBox(this).apply {
                        text = getString(R.string.import_hotwords, payload.hotwords.size)
                        isChecked = selection.hotwords
                        setOnCheckedChangeListener { _, checked -> selection.hotwords = checked }
                    },
                )
            }
            if (!payload.snippets.isNullOrEmpty()) {
                content.addView(
                    CheckBox(this).apply {
                        text = getString(R.string.import_snippets, payload.snippets.size)
                        isChecked = selection.snippets
                        setOnCheckedChangeListener { _, checked -> selection.snippets = checked }
                    },
                )
            }
        }

        if (payload.textOutput != null) {
            content.addView(section(getString(R.string.import_text_output)))
            content.addView(
                CheckBox(this).apply {
                    text = getString(R.string.import_text_output_option)
                    isChecked = selection.textOutput
                    setOnCheckedChangeListener { _, checked -> selection.textOutput = checked }
                },
            )
        }

        val importButton = MaterialButton(this).apply {
            text = getString(R.string.import_action)
            isAllCaps = false
            setOnClickListener { startImport(payload) }
        }
        this.importButton = importButton
        content.addView(
            importButton,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(46)).apply {
                topMargin = dp(18)
            },
        )
        scroll.addView(content)
        root.addView(scroll, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            toolbar.applyNavBarTopInset(bars.top)
            view.updatePadding(bottom = bars.bottom)
            insets
        }
        ViewCompat.requestApplyInsets(root)
        if (savedInstanceState != null) {
            val savedScroll = savedInstanceState.getInt(KEY_SCROLL_Y, 0)
            scroll.post { scroll.scrollTo(0, savedScroll) }
        }
    }

    private fun startImport(payload: TransferPayload) {
        if (importJob?.isActive == true) return
        val button = importButton ?: return
        button.isEnabled = false
        importJob = lifecycleScope.launch {
            val outcome = runCatching {
                withContext(Dispatchers.IO) {
                    TransferImporter.apply(this@ImportActivity, payload, selection)
                }
            }
            if (!isActive) return@launch
            val result = outcome.getOrNull()
            if (result == null) {
                outcome.exceptionOrNull()?.let { Log.e(TAG, "import failed", it) }
                Toast.makeText(
                    this@ImportActivity,
                    R.string.import_failed,
                    Toast.LENGTH_LONG,
                ).show()
                if (isActive) button.isEnabled = true
                return@launch
            }
            PendingImport.clear()
            Toast.makeText(
                this@ImportActivity,
                getString(R.string.import_done, summary(result)),
                Toast.LENGTH_LONG,
            ).show()
            finish()
        }
    }

    private fun cancelImport() {
        importJob?.cancel()
        importJob = null
        PendingImport.clear()
        finish()
    }

    private fun summary(result: com.type4me.android.data.ImportResult): String = buildList {
        result.asrName?.let { add(getString(R.string.import_summary_asr, it)) }
        result.llmName?.let { add(getString(R.string.import_summary_llm, it)) }
        if (result.modeCount > 0) add(getString(R.string.import_modes_count, result.modeCount))
        if (result.hotwordCount > 0) add(getString(R.string.import_hotwords, result.hotwordCount))
        if (result.snippetCount > 0) add(getString(R.string.import_snippets, result.snippetCount))
        if (result.skippedAsr.isNotEmpty()) {
            add(getString(R.string.import_skipped_asr, result.skippedAsr.joinToString()))
        }
        if (result.skippedLlm.isNotEmpty()) {
            add(getString(R.string.import_skipped_llm, result.skippedLlm.joinToString()))
        }
    }.joinToString(getString(R.string.import_summary_separator))

    private fun TransferEndpoint.displayName(): String {
        val known = Presets.asr.firstOrNull { it.id == provider }
        return when {
            known != null && provider == "custom" -> getString(R.string.custom_provider)
            known != null -> known.displayName
            else -> getString(R.string.import_unknown_provider, provider)
        }
    }

    private fun TransferMode.displayName(): String =
        name?.takeIf { it.isNotBlank() } ?: when (kind) {
            "quick" -> getString(R.string.mode_quick)
            "formalWriting" -> getString(R.string.mode_polish)
            "translateEnglish" -> getString(R.string.mode_translate)
            "agentMode" -> getString(R.string.mode_agent)
            "intelliSense" -> getString(R.string.mode_intelli_sense)
            else -> getString(R.string.mode_custom)
        }

    private fun defaultButton(provider: String, active: String?, action: () -> Unit): TextView =
        TextView(this).apply {
            text = if (active == provider) {
                getString(R.string.import_default)
            } else {
                getString(R.string.import_make_default)
            }
            textSize = 12f
            setTextColor(
                color(if (active == provider) R.color.success else R.color.ink_tertiary),
            )
            setPadding(dp(8), dp(6), dp(4), dp(6))
            isClickable = true
            setOnClickListener {
                action()
                recreate()
            }
        }

    private fun section(title: String): TextView = TextView(this).apply {
        text = title
        textSize = 13f
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        setTextColor(color(R.color.ink_secondary))
        setPadding(dp(4), dp(16), dp(4), dp(4))
    }

    /** Keeps the checkbox choices and scroll offset across rotation and default-button recreate. */
    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        if (!this::selection.isInitialized) return
        outState.putStringArrayList(KEY_ASRS, ArrayList(selection.asrs))
        outState.putStringArrayList(KEY_LLMS, ArrayList(selection.llms))
        outState.putStringArrayList(KEY_MODES, ArrayList(selection.modes))
        outState.putString(KEY_ACTIVE_ASR, selection.activeAsr)
        outState.putString(KEY_ACTIVE_LLM, selection.activeLlm)
        outState.putBoolean(KEY_HOTWORDS, selection.hotwords)
        outState.putBoolean(KEY_SNIPPETS, selection.snippets)
        outState.putBoolean(KEY_TEXT_OUTPUT, selection.textOutput)
        outState.putInt(KEY_SCROLL_Y, scroll?.scrollY ?: 0)
    }

    override fun onDestroy() {
        if (importJob?.isActive == true) importJob?.cancel()
        importJob = null
        scroll = null
        importButton = null
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun restoreSelection(state: Bundle, payload: TransferPayload): ImportSelection {
        val defaults = ImportSelection.all(payload)
        return ImportSelection(
            asrs = state.getStringArrayList(KEY_ASRS)?.toMutableSet() ?: defaults.asrs,
            activeAsr = if (state.containsKey(KEY_ACTIVE_ASR)) {
                state.getString(KEY_ACTIVE_ASR)
            } else {
                defaults.activeAsr
            },
            llms = state.getStringArrayList(KEY_LLMS)?.toMutableSet() ?: defaults.llms,
            activeLlm = if (state.containsKey(KEY_ACTIVE_LLM)) {
                state.getString(KEY_ACTIVE_LLM)
            } else {
                defaults.activeLlm
            },
            modes = state.getStringArrayList(KEY_MODES)?.toMutableSet() ?: defaults.modes,
            hotwords = state.getBoolean(KEY_HOTWORDS, defaults.hotwords),
            snippets = state.getBoolean(KEY_SNIPPETS, defaults.snippets),
            textOutput = state.getBoolean(KEY_TEXT_OUTPUT, defaults.textOutput),
        )
    }

    private companion object {
        const val TAG = "ImportActivity"
        const val KEY_ASRS = "selection.asrs"
        const val KEY_ACTIVE_ASR = "selection.activeAsr"
        const val KEY_LLMS = "selection.llms"
        const val KEY_ACTIVE_LLM = "selection.activeLlm"
        const val KEY_MODES = "selection.modes"
        const val KEY_HOTWORDS = "selection.hotwords"
        const val KEY_SNIPPETS = "selection.snippets"
        const val KEY_TEXT_OUTPUT = "selection.textOutput"
        const val KEY_SCROLL_Y = "scroll.y"
    }
}
