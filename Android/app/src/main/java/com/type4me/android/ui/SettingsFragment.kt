package com.type4me.android.ui

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.inputmethod.InputMethodInfo
import android.view.inputmethod.InputMethodManager
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.content.ContextCompat
import androidx.core.os.LocaleListCompat
import androidx.core.graphics.ColorUtils
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.core.view.updatePadding
import androidx.fragment.app.Fragment
import com.google.android.material.card.MaterialCardView
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.type4me.android.BuildConfig
import com.type4me.android.DiagnosticsActivity
import com.type4me.android.HotwordsActivity
import com.type4me.android.MainActivity
import com.type4me.android.ModesActivity
import com.type4me.android.R
import com.type4me.android.SnippetsActivity
import com.type4me.android.SpeechServiceActivity
import com.type4me.android.TextModelActivity
import com.type4me.android.data.AppSettings
import com.type4me.android.data.AsrKind
import com.type4me.android.data.CjkSpacing
import com.type4me.android.data.ConfigStore
import com.type4me.android.data.HistoryStore
import com.type4me.android.data.Presets
import com.type4me.android.data.TextOutputStore
import com.type4me.android.data.TrailingPunctuation
import com.type4me.android.data.TranslateTarget
import com.type4me.android.data.VocabularyStore
import com.type4me.android.databinding.FragmentSettingsBinding
import com.type4me.android.databinding.ItemSettingsRowBinding
import com.type4me.android.databinding.ItemSettingsSwitchBinding
import com.type4me.android.ime.VoiceImeService
import com.type4me.android.pipeline.Mode
import com.type4me.android.pipeline.ModeDefinition
import com.type4me.android.pipeline.ModeLibrary

/**
 * Settings, as the Mac's grouped pages: a card per topic, each row opening
 * its own page. The keyboard's default mode sits here too.
 */
class SettingsFragment : Fragment(R.layout.fragment_settings) {

    private var binding: FragmentSettingsBinding? = null

    private val requestMicrophone = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { refresh() }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        val b = FragmentSettingsBinding.bind(view)
        binding = b
        view.background = DotGridDrawable(requireContext())
        ViewCompat.setOnApplyWindowInsetsListener(view) { target, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            target.updatePadding(top = bars.top)
            insets
        }
        ViewCompat.requestApplyInsets(view)
        refresh()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    override fun onDestroyView() {
        binding = null
        super.onDestroyView()
    }

    fun refresh() {
        val b = binding ?: return
        b.sections.removeAllViews()
        addSpeechSection()
        addModesSection()
        addVocabularySection()
        addTextOutputSection()
        addSyncSection()
        addKeyboardSection()
        addPrivacySection()
        addGeneralSection()
        addEraseSection()
    }

    // MARK: - Sections

    private fun addSpeechSection() {
        val context = requireContext()
        addSectionHeader(getString(R.string.section_speech_text))
        val card = addCard()
        val hasAsr = ConfigStore.hasAsrConfig(context)
        row(
            card = card,
            icon = R.drawable.ic_waveform,
            title = getString(R.string.speech_service),
            subtitle = asrSubtitle(hasAsr),
            dot = hasAsr,
            chevron = true,
        ) { open(SpeechServiceActivity::class.java) }

        val llm = ConfigStore.llm(context)
        row(
            card = card,
            icon = R.drawable.ic_chat,
            title = getString(R.string.text_model),
            subtitle = llmSubtitle(llm),
            dot = llm != null,
            chevron = true,
        ) { open(TextModelActivity::class.java) }
        footer(getString(R.string.service_footer))
    }

    private fun addModesSection() {
        val context = requireContext()
        addSectionHeader(
            getString(R.string.section_my_modes),
            getString(R.string.manage),
        ) { open(ModesActivity::class.java) }
        val card = addCard()
        val saved = ConfigStore.mode(context)
        val hasLlm = ConfigStore.llm(context) != null
        val quick = ModeLibrary.byId(context, Mode.QUICK.name) ?: ModeDefinition.builtIn(Mode.QUICK)
        val effective = if (saved.usesTextModel && !hasLlm) quick else saved
        ModeLibrary.keyboard(context).forEach { mode ->
            val available = !mode.usesTextModel || hasLlm
            row(
                card = card,
                icon = modeIcon(mode.kind),
                title = mode.label(context),
                subtitle = if (available) {
                    mode.summary(context)
                } else {
                    getString(R.string.mode_needs_text_model)
                },
                subtitleLines = 2,
                checked = effective.id == mode.id,
                enabled = available,
            ) {
                ConfigStore.setMode(context, mode)
                refresh()
            }
        }
        footer(getString(R.string.default_mode_footer))
    }

    private fun addVocabularySection() {
        val context = requireContext()
        addSectionHeader(getString(R.string.section_vocabulary))
        val card = addCard()
        row(
            card = card,
            icon = R.drawable.ic_text,
            title = getString(R.string.hotwords),
            value = getString(R.string.hotword_count_format, VocabularyStore.hotwords(context).size),
            chevron = true,
        ) { open(HotwordsActivity::class.java) }
        row(
            card = card,
            icon = R.drawable.ic_text,
            title = getString(R.string.snippets),
            value = getString(R.string.snippet_count_format, VocabularyStore.snippets(context).size),
            chevron = true,
        ) { open(SnippetsActivity::class.java) }
        footer(getString(R.string.vocabulary_footer))
    }

    private fun addTextOutputSection() {
        val context = requireContext()
        addSectionHeader(getString(R.string.section_text_output))
        val card = addCard()
        row(
            card = card,
            icon = R.drawable.ic_text,
            title = getString(R.string.pangu_spacing),
            subtitle = spacingName(TextOutputStore.spacing(context)),
            chevron = true,
        ) { chooseSpacing() }
        row(
            card = card,
            icon = R.drawable.ic_text,
            title = getString(R.string.trailing_punctuation),
            subtitle = punctuationName(TextOutputStore.punctuation(context)),
            chevron = true,
        ) { choosePunctuation() }
        switchRow(
            card = card,
            icon = R.drawable.ic_text,
            title = getString(R.string.corner_quotes),
            subtitle = getString(R.string.corner_quotes_footer),
            checked = TextOutputStore.cornerQuotes(context),
        ) { TextOutputStore.setCornerQuotes(context, it) }
        footer(getString(R.string.text_output_footer))
    }

    private fun addSyncSection() {
        addSectionHeader(getString(R.string.section_sync_mac))
        val card = addCard()
        row(
            card = card,
            icon = R.drawable.ic_qr,
            title = getString(R.string.scan_sync),
            subtitle = getString(R.string.scan_hint),
            chevron = true,
        ) { (activity as? MainActivity)?.openScanner() }
        footer(getString(R.string.sync_footer))
    }

    private fun addKeyboardSection() {
        val context = requireContext()
        addSectionHeader(getString(R.string.section_keyboard))
        val card = addCard()
        val enabled = isImeEnabled()
        val current = isImeCurrent()
        row(
            card = card,
            icon = R.drawable.ic_keyboard,
            title = getString(R.string.ime_name),
            subtitle = when {
                !enabled -> getString(R.string.keyboard_status_off)
                current -> getString(R.string.keyboard_status_current)
                else -> getString(R.string.keyboard_status_not_current)
            },
            dot = enabled,
            chevron = true,
        ) {
            if (enabled) chooseIme() else openImeSettings()
        }
        row(
            card = card,
            icon = R.drawable.ic_ime_settings,
            title = getString(R.string.open_ime_settings),
            chevron = true,
        ) { openImeSettings() }
        row(
            card = card,
            icon = R.drawable.ic_globe,
            title = getString(R.string.choose_ime),
            chevron = true,
        ) { chooseIme() }
        switchRow(
            card = card,
            icon = R.drawable.ic_keyboard,
            title = getString(R.string.key_haptics),
            checked = AppSettings.keyHaptics(context),
        ) { AppSettings.setKeyHaptics(context, it) }
        switchRow(
            card = card,
            icon = R.drawable.ic_keyboard,
            title = getString(R.string.key_sounds),
            checked = AppSettings.keySounds(context),
        ) { AppSettings.setKeySounds(context, it) }
        switchRow(
            card = card,
            icon = R.drawable.ic_keyboard,
            title = getString(R.string.keyboard_clipboard),
            subtitle = getString(R.string.keyboard_clipboard_footer),
            checked = AppSettings.keyboardClipboard(context),
        ) { AppSettings.setKeyboardClipboard(context, it) }
        switchRow(
            card = card,
            icon = R.drawable.ic_keyboard,
            title = getString(R.string.full_width_punctuation),
            subtitle = getString(R.string.full_width_punctuation_footer),
            checked = AppSettings.fullWidthPunctuation(context),
        ) { AppSettings.setFullWidthPunctuation(context, it) }

        val hasMicrophone = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
        row(
            card = card,
            icon = R.drawable.ic_mic,
            title = getString(R.string.mic_title),
            subtitle = getString(if (hasMicrophone) R.string.mic_granted else R.string.mic_denied),
            value = if (hasMicrophone) null else getString(R.string.grant_mic),
            chevron = !hasMicrophone,
        ) {
            if (!hasMicrophone) {
                requestMicrophone.launch(Manifest.permission.RECORD_AUDIO)
            }
        }
    }

    private fun addPrivacySection() {
        val context = requireContext()
        addSectionHeader(getString(R.string.section_privacy))
        val card = addCard()
        switchRow(
            card = card,
            icon = R.drawable.ic_lock,
            title = getString(R.string.read_field_context),
            checked = AppSettings.fieldContext(context),
        ) { AppSettings.setFieldContext(context, it) }
        row(
            card = card,
            icon = R.drawable.ic_lock,
            title = getString(R.string.ai_consent),
            subtitle = getString(
                if (AppSettings.aiConsent(context)) R.string.ai_consent_granted
                else R.string.ai_consent_needed,
            ),
            value = if (AppSettings.aiConsent(context)) null else getString(R.string.ai_consent_agree),
            chevron = true,
        ) { showConsent() }
        footer(getString(R.string.privacy_context_footer))
    }

    private fun addGeneralSection() {
        val context = requireContext()
        addSectionHeader(getString(R.string.section_general))
        val card = addCard()
        row(
            card = card,
            icon = R.drawable.ic_gear,
            title = getString(R.string.scan_open_settings),
            chevron = true,
        ) { openSystemSettings() }

        row(
            card = card,
            icon = R.drawable.ic_globe,
            title = getString(R.string.language),
            subtitle = languageName(AppSettings.language(context)),
            chevron = true,
        ) { chooseLanguage() }

        addSectionHeader(getString(R.string.section_about))
        val about = addCard()
        row(
            card = about,
            icon = R.drawable.ic_info,
            title = getString(R.string.diagnostics),
            chevron = true,
        ) { open(DiagnosticsActivity::class.java) }
        row(
            card = about,
            icon = R.drawable.ic_info,
            title = getString(R.string.version_label),
            value = BuildConfig.VERSION_NAME,
        )
        footer(getString(R.string.about, BuildConfig.VERSION_NAME))
    }

    private fun addEraseSection() {
        val context = requireContext()
        addSectionHeader(getString(R.string.section_erase))
        val card = addCard()
        row(
            card = card,
            icon = R.drawable.ic_trash,
            title = getString(R.string.clear_history),
            destructive = true,
        ) {
            MaterialAlertDialogBuilder(context)
                .setTitle(R.string.confirm_clear_history_title)
                .setMessage(R.string.confirm_clear_history_message)
                .setNegativeButton(R.string.cancel, null)
                .setPositiveButton(R.string.clear) { _, _ ->
                    HistoryStore.clear(context)
                    refresh()
                }
                .show()
        }
        row(
            card = card,
            icon = R.drawable.ic_trash,
            title = getString(R.string.delete_setup),
            destructive = true,
        ) {
            MaterialAlertDialogBuilder(context)
                .setTitle(R.string.confirm_delete_setup_title)
                .setMessage(R.string.confirm_delete_setup_message)
                .setNegativeButton(R.string.cancel, null)
                .setPositiveButton(R.string.delete) { _, _ ->
                    ConfigStore.clearAll(context)
                    refresh()
                    (activity as? MainActivity)?.refreshScreens()
                }
                .show()
        }
    }

    // MARK: - Building blocks

    private fun addSectionHeader(
        title: String,
        actionLabel: String? = null,
        action: (() -> Unit)? = null,
    ) {
        val context = requireContext()
        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(context.dp(4), context.dp(20), context.dp(4), context.dp(6))
        }
        val label = TextView(context).apply {
            text = title
            textSize = 13f
            setTextColor(context.color(R.color.ink_tertiary))
            typeface = Typeface.DEFAULT_BOLD
        }
        header.addView(
            label,
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
        )
        if (actionLabel != null && action != null) {
            val button = TextView(context).apply {
                text = actionLabel
                textSize = 13f
                setTextColor(context.color(R.color.ink))
                setPadding(context.dp(8), context.dp(4), context.dp(4), context.dp(4))
                isClickable = true
                setOnClickListener { action() }
            }
            header.addView(button)
        }
        binding?.sections?.addView(header)
    }

    private fun addCard(): LinearLayout {
        val context = requireContext()
        val card = MaterialCardView(context).apply {
            radius = context.dp(20).toFloat()
            cardElevation = 0f
            setCardBackgroundColor(context.color(R.color.card_bg))
            strokeColor = context.color(R.color.divider)
            strokeWidth = context.dp(1)
        }
        val inner = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        card.addView(
            inner,
            android.widget.FrameLayout.LayoutParams(
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                android.widget.FrameLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
        binding?.sections?.addView(
            card,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
        return inner
    }

    private fun row(
        card: LinearLayout,
        icon: Int,
        title: String,
        subtitle: String? = null,
        subtitleLines: Int = 1,
        value: String? = null,
        dot: Boolean? = null,
        chevron: Boolean = false,
        checked: Boolean = false,
        enabled: Boolean = true,
        destructive: Boolean = false,
        onClick: (() -> Unit)? = null,
    ) {
        if (card.childCount > 0) addDivider(card)
        val context = requireContext()
        val item = ItemSettingsRowBinding.inflate(layoutInflater, card, false)
        item.icon.setImageResource(icon)
        item.icon.imageTintList = ColorStateList.valueOf(
            context.color(if (destructive) R.color.brand_red else R.color.ink),
        )
        item.title.text = title
        item.title.setTextColor(
            context.color(if (destructive) R.color.brand_red else R.color.ink),
        )
        item.subtitle.isVisible = !subtitle.isNullOrEmpty()
        item.subtitle.text = subtitle
        item.subtitle.maxLines = subtitleLines
        item.subtitle.ellipsize = if (subtitleLines == 1) {
            android.text.TextUtils.TruncateAt.MIDDLE
        } else {
            android.text.TextUtils.TruncateAt.END
        }
        item.value.isVisible = !value.isNullOrEmpty()
        item.value.text = value
        item.dot.isVisible = dot != null
        if (dot != null) {
            item.dot.backgroundTintList = ColorStateList.valueOf(
                if (dot) {
                    context.color(R.color.success)
                } else {
                    ColorUtils.setAlphaComponent(context.color(R.color.ink), 46)
                },
            )
        }
        item.chevron.isVisible = chevron
        item.check.isVisible = checked
        item.root.alpha = if (enabled) 1f else 0.4f
        item.root.isClickable = onClick != null
        item.root.isFocusable = onClick != null
        if (onClick != null) {
            item.root.setOnClickListener { if (enabled) onClick() }
        }
        card.addView(item.root)
    }

    private fun switchRow(
        card: LinearLayout,
        icon: Int,
        title: String,
        subtitle: String? = null,
        checked: Boolean,
        onChange: (Boolean) -> Unit,
    ) {
        if (card.childCount > 0) addDivider(card)
        val context = requireContext()
        val item = ItemSettingsSwitchBinding.inflate(layoutInflater, card, false)
        item.icon.setImageResource(icon)
        item.icon.imageTintList = ColorStateList.valueOf(context.color(R.color.ink))
        item.title.text = title
        item.subtitle.isVisible = !subtitle.isNullOrEmpty()
        item.subtitle.text = subtitle
        item.switchView.isChecked = checked
        item.switchView.setOnCheckedChangeListener { _, value -> onChange(value) }
        item.root.setOnClickListener { item.switchView.toggle() }
        card.addView(item.root)
    }

    private fun addDivider(card: LinearLayout) {
        val context = requireContext()
        card.addView(
            View(context).apply { setBackgroundColor(context.color(R.color.divider)) },
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                context.dp(1),
            ).apply { marginStart = context.dp(56) },
        )
    }

    private fun footer(text: String) {
        val context = requireContext()
        val view = TextView(context).apply {
            this.text = text
            textSize = 13f
            setTextColor(context.color(R.color.ink_secondary))
            setPadding(context.dp(4), context.dp(8), context.dp(4), 0)
        }
        binding?.sections?.addView(view)
    }

    // MARK: - Values

    private fun asrSubtitle(hasAsr: Boolean): String {
        if (!hasAsr) return getString(R.string.not_configured)
        val context = requireContext()
        val config = ConfigStore.asr(context)
        val preset = Presets.asrById(ConfigStore.asrPresetId(context))
        val name = if (preset.id == "custom") {
            getString(R.string.custom_provider)
        } else {
            preset.displayName
        }
        val detail = when (config.kind) {
            AsrKind.OPENAI -> config.model
            AsrKind.VOLCANO -> getString(
                if (config.resourceId == Presets.VOLC_RESOURCE_BIG) {
                    R.string.asr_resource_big
                } else {
                    R.string.asr_resource_seed
                },
            )

            AsrKind.SONIOX -> config.model.ifBlank { "stt-rt-v5" }
            AsrKind.STREAMING, AsrKind.BATCH ->
                config.model.ifBlank { config.extra["model"].orEmpty() }
        }
        return if (detail.isBlank()) name else getString(R.string.asr_summary_format, name, detail)
    }

    private fun llmSubtitle(config: com.type4me.android.data.LlmConfig?): String {
        if (config == null) return getString(R.string.not_configured)
        val context = requireContext()
        val preset = Presets.llmById(ConfigStore.llmPresetId(context))
        val name = if (preset.id == "custom") {
            getString(R.string.custom_provider)
        } else {
            preset.displayName
        }
        return if (config.model.isBlank()) name else getString(
            R.string.asr_summary_format,
            name,
            config.model,
        )
    }

    private fun modeIcon(mode: Mode): Int = when (mode) {
        Mode.INTELLI_SENSE -> R.drawable.ic_sparkles
        Mode.QUICK -> R.drawable.ic_bolt
        Mode.POLISH -> R.drawable.ic_wand
        Mode.TRANSLATE -> R.drawable.ic_translate
        Mode.AGENT -> R.drawable.ic_agent
        Mode.CUSTOM -> R.drawable.ic_wand
    }

    private fun targetName(target: TranslateTarget): String = target.label(requireContext())

    private fun spacingName(mode: CjkSpacing): String = getString(
        when (mode) {
            CjkSpacing.PANGU -> R.string.spacing_pangu
            CjkSpacing.KEEP -> R.string.spacing_keep
            CjkSpacing.REMOVE -> R.string.spacing_remove
        },
    )

    private fun punctuationName(mode: TrailingPunctuation): String = getString(
        when (mode) {
            TrailingPunctuation.KEEP -> R.string.punctuation_keep
            TrailingPunctuation.PERIOD -> R.string.punctuation_period
            TrailingPunctuation.ALL -> R.string.punctuation_all
        },
    )

    private fun chooseSpacing() {
        val context = requireContext()
        val values = CjkSpacing.entries.toTypedArray()
        val labels = values.map { spacingName(it) }.toTypedArray()
        MaterialAlertDialogBuilder(context)
            .setTitle(R.string.pangu_spacing)
            .setSingleChoiceItems(labels, values.indexOf(TextOutputStore.spacing(context))) { dialog, which ->
                TextOutputStore.setSpacing(context, values[which])
                dialog.dismiss()
                refresh()
            }
            .show()
    }

    private fun choosePunctuation() {
        val context = requireContext()
        val values = TrailingPunctuation.entries.toTypedArray()
        val labels = values.map { punctuationName(it) }.toTypedArray()
        MaterialAlertDialogBuilder(context)
            .setTitle(R.string.trailing_punctuation)
            .setSingleChoiceItems(
                labels,
                values.indexOf(TextOutputStore.punctuation(context)),
            ) { dialog, which ->
                TextOutputStore.setPunctuation(context, values[which])
                dialog.dismiss()
                refresh()
            }
            .show()
    }

    // MARK: - Actions

    private fun languageName(value: String): String = getString(
        when (value) {
            "zh" -> R.string.language_zh
            "en" -> R.string.language_en
            else -> R.string.language_system
        },
    )

    private fun chooseLanguage() {
        val context = requireContext()
        val values = listOf("system", "zh", "en")
        MaterialAlertDialogBuilder(context)
            .setTitle(R.string.language)
            .setSingleChoiceItems(
                values.map(::languageName).toTypedArray(),
                values.indexOf(AppSettings.language(context)).coerceAtLeast(0),
            ) { dialog, which ->
                val value = values[which]
                AppSettings.setLanguage(context, value)
                val locales = when (value) {
                    "zh" -> LocaleListCompat.forLanguageTags("zh-Hans")
                    "en" -> LocaleListCompat.forLanguageTags("en")
                    else -> LocaleListCompat.getEmptyLocaleList()
                }
                AppCompatDelegate.setApplicationLocales(locales)
                dialog.dismiss()
                refresh()
            }
            .show()
    }

    private fun showConsent() {
        val context = requireContext()
        val agreed = AppSettings.aiConsent(context)
        val dialog = MaterialAlertDialogBuilder(context)
            .setTitle(R.string.ai_consent_title)
            .setMessage(R.string.ai_consent_body)
            .setNegativeButton(R.string.cancel, null)
        if (agreed) {
            dialog.setPositiveButton(R.string.ai_consent_revoke) { _, _ ->
                AppSettings.setAiConsent(context, false)
                refresh()
            }
        } else {
            dialog.setPositiveButton(R.string.ai_consent_agree) { _, _ ->
                AppSettings.setAiConsent(context, true)
                refresh()
            }
        }
        dialog.show()
    }

    private fun open(activity: Class<*>) {
        startActivity(Intent(requireContext(), activity))
    }

    private fun openImeSettings() {
        startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
    }

    private fun chooseIme() {
        requireContext().getSystemService(InputMethodManager::class.java)
            .showInputMethodPicker()
    }

    private fun openSystemSettings() {
        startActivity(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:${requireContext().packageName}"),
            ),
        )
    }

    private fun imeComponent() = ComponentName(requireContext(), VoiceImeService::class.java)

    private fun isOurs(info: InputMethodInfo): Boolean {
        val ours = imeComponent()
        return info.packageName == ours.packageName && info.serviceName == ours.className
    }

    // Android 14 keeps the input-method settings keys readable only to apps
    // targeting 33 or lower, and Android 17 throws instead of returning null.
    // InputMethodManager exposes the same state without that restriction.
    private fun isImeEnabled(): Boolean {
        val imm = requireContext().getSystemService(InputMethodManager::class.java)
        return imm.enabledInputMethodList.any(::isOurs)
    }

    private fun isImeCurrent(): Boolean {
        val context = requireContext()
        val imm = context.getSystemService(InputMethodManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return imm.currentInputMethodInfo?.let(::isOurs) ?: false
        }
        val current = runCatching {
            Settings.Secure.getString(context.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
        }.getOrNull().orEmpty()
        return ComponentName.unflattenFromString(current) == imeComponent()
    }
}
