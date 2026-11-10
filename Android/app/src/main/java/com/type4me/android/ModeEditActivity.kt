package com.type4me.android

import android.os.Bundle
import android.text.InputType
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import com.google.android.material.button.MaterialButton
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.type4me.android.ui.applyNavBarTopInset
import com.type4me.android.pipeline.Mode
import com.type4me.android.pipeline.ModeDefinition
import com.type4me.android.pipeline.ModeLibrary
import com.type4me.android.pipeline.ModePunctuation
import com.type4me.android.pipeline.Prompts
import com.type4me.android.pipeline.TranslateTarget
import com.type4me.android.ui.color
import com.type4me.android.ui.dp
import java.util.UUID

/** Create or edit one mode: name, prompt, translation target and per-mode output. */
class ModeEditActivity : AppCompatActivity() {

    private lateinit var name: EditText
    private lateinit var prompt: EditText
    private lateinit var onKeyboard: CheckBox
    private lateinit var target: Spinner
    private lateinit var punctuation: Spinner
    private lateinit var shortText: Spinner
    private lateinit var promptSection: LinearLayout
    private lateinit var targetSection: LinearLayout
    private lateinit var mode: ModeDefinition

    private val shortValues = listOf(0, 10, 20, 30, 40, 50)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val id = intent.getStringExtra(EXTRA_ID)
        mode = id?.let { ModeLibrary.byId(this, it) } ?: newMode()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(color(R.color.screen_bg))
        }
        val toolbar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = android.view.Gravity.CENTER_VERTICAL
            setPadding(dp(4), 0, dp(12), 0)
        }
        toolbar.addView(
            TextView(this).apply {
                text = "‹"
                textSize = 30f
                gravity = android.view.Gravity.CENTER
                setTextColor(color(R.color.ink))
                isClickable = true
                contentDescription = getString(R.string.back)
                setOnClickListener { finish() }
            },
            LinearLayout.LayoutParams(dp(48), dp(56)),
        )
        toolbar.addView(
            TextView(this).apply {
                text = if (id == null) getString(R.string.mode_new) else mode.label(this@ModeEditActivity)
                textSize = 18f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(color(R.color.ink))
                gravity = android.view.Gravity.CENTER_VERTICAL
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
            },
            LinearLayout.LayoutParams(0, dp(56), 1f),
        )
        root.addView(toolbar)

        val scroll = ScrollView(this)
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(4), dp(16), dp(32))
        }
        content.addView(sectionLabel(R.string.mode_name))
        name = EditText(this).apply {
            hint = getString(R.string.mode_name_hint)
            setText(mode.name.orEmpty())
            setSingleLine()
            setTextColor(color(R.color.ink))
        }
        content.addView(name)
        if (mode.isBuiltIn) {
            content.addView(
                TextView(this).apply {
                    text = mode.kind.label(this@ModeEditActivity)
                    textSize = 13f
                    setTextColor(color(R.color.ink_tertiary))
                    setPadding(dp(4), 0, dp(4), dp(8))
                },
            )
        }

        targetSection = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        targetSection.addView(sectionLabel(R.string.mode_translate_target))
        target = Spinner(this).apply {
            adapter = simple(TranslateTarget.entries.map { it.label(this@ModeEditActivity) })
            setSelection(mode.translationTarget.ordinal, false)
        }
        targetSection.addView(target, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(48)))
        content.addView(targetSection)
        targetSection.visibility = if (mode.kind == Mode.TRANSLATE) View.VISIBLE else View.GONE

        promptSection = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        promptSection.addView(sectionLabel(R.string.mode_prompt))
        prompt = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = if (mode.isBuiltIn && mode.kind == Mode.AGENT) 14 else 6
            maxLines = 24
            gravity = android.view.Gravity.TOP
            setText(
                when {
                    mode.prompt.isNotBlank() -> mode.prompt
                    mode.isBuiltIn -> Prompts.defaultPrompt(mode.kind).orEmpty()
                    else -> Prompts.newModeTemplate(isChinese())
                },
            )
            hint = getString(R.string.mode_prompt_hint)
            setTextColor(color(R.color.ink))
        }
        promptSection.addView(prompt)
        content.addView(promptSection)
        val canEditPrompt = mode.kind !in setOf(Mode.QUICK, Mode.INTELLI_SENSE, Mode.TRANSLATE)
        promptSection.visibility = if (canEditPrompt) View.VISIBLE else View.GONE
        if (!canEditPrompt) {
            content.addView(
                TextView(this).apply {
                    text = mode.summary(this@ModeEditActivity)
                    textSize = 14f
                    setTextColor(color(R.color.ink_secondary))
                    setPadding(dp(4), dp(8), dp(4), dp(8))
                },
            )
        }

        content.addView(sectionLabel(R.string.mode_punctuation))
        punctuation = Spinner(this).apply {
            adapter = simple(ModePunctuation.entries.map { punctuationLabel(it) })
            setSelection(mode.punctuation.ordinal, false)
        }
        content.addView(punctuation, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(48)))

        content.addView(sectionLabel(R.string.mode_short_text))
        shortText = Spinner(this).apply {
            adapter = simple(shortValues.map { value ->
                if (value == 0) getString(R.string.mode_short_off)
                else getString(R.string.mode_short_under, value)
            })
            setSelection(shortValues.indexOf(mode.shortTextExemption).coerceAtLeast(0), false)
        }
        content.addView(shortText, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(48)))

        onKeyboard = CheckBox(this).apply {
            text = getString(R.string.mode_on_keyboard)
            setTextColor(color(R.color.ink))
            isChecked = mode.onKeyboard
        }
        content.addView(onKeyboard)

        val save = MaterialButton(this).apply {
            text = getString(R.string.mode_save)
            setOnClickListener { save() }
        }
        content.addView(save, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(46)).apply { topMargin = dp(12) })

        if (!mode.isBuiltIn) {
            val delete = MaterialButton(this).apply {
                text = getString(R.string.mode_delete)
                setTextColor(color(R.color.brand_red))
                setOnClickListener { confirmDelete() }
            }
            content.addView(delete)
        }
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
    }

    private fun newMode(): ModeDefinition = ModeDefinition(
        id = "custom-" + UUID.randomUUID().toString().take(8),
        kind = Mode.CUSTOM,
        name = "",
        prompt = Prompts.newModeTemplate(isChinese()),
        onKeyboard = true,
    )

    private fun save() {
        val customName = name.text?.toString()?.trim().orEmpty()
        if (!mode.isBuiltIn && customName.isEmpty()) {
            Toast.makeText(this, R.string.mode_name_required, Toast.LENGTH_SHORT).show()
            return
        }
        val promptText = prompt.text?.toString()?.trim().orEmpty()
        if (mode.kind !in setOf(Mode.QUICK, Mode.INTELLI_SENSE, Mode.TRANSLATE) &&
            promptText.isEmpty()
        ) {
            Toast.makeText(this, R.string.mode_prompt_required, Toast.LENGTH_SHORT).show()
            return
        }
        val defaultPrompt = Prompts.defaultPrompt(mode.kind)?.trim()
        val storedPrompt = if (mode.isBuiltIn && promptText == defaultPrompt) "" else promptText
        val updated = mode.copy(
            name = customName.ifEmpty { null },
            prompt = storedPrompt,
            onKeyboard = onKeyboard.isChecked,
            translateTarget = TranslateTarget.entries[target.selectedItemPosition].code,
            punctuation = ModePunctuation.entries[punctuation.selectedItemPosition],
            shortTextExemption = shortValues[shortText.selectedItemPosition],
        )
        ModeLibrary.upsert(this, updated)
        finish()
    }

    private fun confirmDelete() {
        MaterialAlertDialogBuilder(this)
            .setTitle(getString(R.string.mode_delete_confirm, mode.label(this)))
            .setMessage(R.string.mode_delete_message)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.delete) { _, _ ->
                ModeLibrary.delete(this, mode.id)
                finish()
            }
            .show()
    }

    private fun sectionLabel(text: Int): TextView = TextView(this).apply {
        setText(text)
        textSize = 13f
        setTextColor(color(R.color.ink_secondary))
        setPadding(dp(4), dp(14), dp(4), dp(4))
    }

    private fun punctuationLabel(mode: ModePunctuation): String = getString(
        when (mode) {
            ModePunctuation.INHERIT -> R.string.mode_punctuation_inherit
            ModePunctuation.PRESERVE -> R.string.mode_punctuation_preserve
            ModePunctuation.STRIP_TRAILING -> R.string.mode_punctuation_strip
            ModePunctuation.QUESTIONS_AND_EXCLAMATIONS -> R.string.mode_punctuation_questions
            ModePunctuation.REMOVE_ALL -> R.string.mode_punctuation_all
        },
    )

    private fun simple(items: List<String>): ArrayAdapter<String> =
        ArrayAdapter(this, android.R.layout.simple_spinner_item, items).apply {
            setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        }

    private fun isChinese(): Boolean = resources.configuration.locales[0].language == "zh"

    companion object {
        const val EXTRA_ID = "mode_id"
    }
}
