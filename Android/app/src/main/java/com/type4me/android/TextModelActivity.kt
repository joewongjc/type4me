package com.type4me.android

import android.os.Bundle
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Toast
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.doOnLayout
import androidx.core.view.isVisible
import androidx.core.view.updatePadding
import androidx.core.widget.doAfterTextChanged
import androidx.lifecycle.lifecycleScope
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.type4me.android.ui.applyNavBarTopInset
import com.type4me.android.ui.formText
import com.type4me.android.ui.shortError
import com.type4me.android.ui.showFormResult
import com.type4me.android.data.ConfigStore
import com.type4me.android.data.LlmConfig
import com.type4me.android.data.Presets
import com.type4me.android.databinding.ActivityTextModelBinding
import com.type4me.android.llm.ChatClient
import com.type4me.android.llm.ThinkingField
import com.type4me.android.llm.ThinkingPolicy
import com.type4me.android.llm.ThinkingUnavailable
import java.lang.ref.WeakReference
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class TextModelActivity : AppCompatActivity() {

    private lateinit var binding: ActivityTextModelBinding
    private val chatClient = ChatClient()
    private var loading = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        binding = ActivityTextModelBinding.inflate(layoutInflater)
        setContentView(binding.root)
        applyInsets()

        binding.back.setOnClickListener { finish() }
        binding.saveLlm.setOnClickListener { saveLlm() }
        binding.testLlm.setOnClickListener { testLlm() }
        binding.deleteLlm.setOnClickListener { confirmDelete() }
        setupSpinner()
        loadConfig()
        binding.llmThinking.setOnCheckedChangeListener { _, _ -> updateThinkingHint() }
        binding.llmModel.doAfterTextChanged { updateThinkingAvailability() }
        binding.root.doOnLayout { attachPresetListener() }
    }

    override fun onResume() {
        super.onResume()
        binding.deleteLlm.isVisible = ConfigStore.llmProfile(this, selectedPresetId()) != null
    }

    private fun applyInsets() {
        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            val keyboard = insets.getInsets(WindowInsetsCompat.Type.ime())
            binding.toolbar.applyNavBarTopInset(bars.top)
            view.updatePadding(bottom = maxOf(bars.bottom, keyboard.bottom))
            insets
        }
    }

    private fun setupSpinner() {
        binding.llmPreset.adapter = ArrayAdapter(
            this,
            android.R.layout.simple_spinner_item,
            Presets.llm.map { if (it.id == "custom") getString(R.string.custom_provider) else it.displayName },
        ).apply { setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item) }
    }

    private fun attachPresetListener() {
        binding.llmPreset.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(
                parent: AdapterView<*>?,
                view: View?,
                position: Int,
                id: Long,
            ) {
                if (loading) return
                val preset = Presets.llm.getOrElse(position) { Presets.llm.last() }
                val saved = ConfigStore.llmProfile(this@TextModelActivity, preset.id)
                binding.llmBaseUrl.setText(saved?.baseUrl ?: preset.baseUrl)
                binding.llmModel.setText(saved?.model ?: preset.model)
                binding.llmApiKey.setText(saved?.apiKey.orEmpty())
                binding.llmThinking.isChecked =
                    saved?.disableThinking ?: ThinkingPolicy.defaultDisabled(preset.id)
                updateThinkingAvailability()
                binding.deleteLlm.isVisible = saved != null
            }

            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }
    }

    private fun loadConfig() {
        loading = true
        try {
            val presetId = ConfigStore.llmPresetId(this)
            val index = Presets.llm.indexOfFirst { it.id == presetId }.coerceAtLeast(0)
            binding.llmPreset.setSelection(index, false)
            val preset = Presets.llm[index]
            val saved = ConfigStore.llmProfile(this, preset.id)
            binding.llmBaseUrl.setText(saved?.baseUrl ?: preset.baseUrl)
            binding.llmModel.setText(saved?.model ?: preset.model)
            binding.llmApiKey.setText(saved?.apiKey.orEmpty())
            binding.llmThinking.isChecked =
                saved?.disableThinking ?: ThinkingPolicy.defaultDisabled(preset.id)
            updateThinkingAvailability()
            binding.deleteLlm.isVisible = saved != null
        } finally {
            loading = false
        }
    }

    private fun saveLlm() {
        val baseUrl = formText(binding.llmBaseUrl)
        val model = formText(binding.llmModel)
        if (baseUrl.isEmpty() && model.isEmpty()) {
            ConfigStore.deleteLlmProfile(this, selectedPresetId())
            Toast.makeText(this, R.string.llm_cleared, Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        if (baseUrl.isEmpty() || model.isEmpty()) {
            Toast.makeText(this, R.string.asr_required, Toast.LENGTH_SHORT).show()
            return
        }
        val saved = runCatching {
            ConfigStore.saveLlm(
                this,
                selectedPresetId(),
                currentConfig(),
            )
        }.isSuccess
        if (!saved) {
            Toast.makeText(this, R.string.save_failed, Toast.LENGTH_SHORT).show()
            return
        }
        Toast.makeText(this, R.string.saved, Toast.LENGTH_SHORT).show()
        finish()
    }

    private fun testLlm() {
        val baseUrl = formText(binding.llmBaseUrl)
        val model = formText(binding.llmModel)
        if (baseUrl.isEmpty() || model.isEmpty()) {
            Toast.makeText(this, R.string.asr_required, Toast.LENGTH_SHORT).show()
            return
        }
        val config = currentConfig()
        val testButton = binding.testLlm
        testButton.isEnabled = false
        val buttonRef = WeakReference(testButton)
        showResult(getString(R.string.testing), error = false)
        lifecycleScope.launch {
            try {
                val outcome = runCatching { chatClient.test(config) }
                if (!isActive) return@launch
                outcome
                    .onSuccess { ms -> showResult(getString(R.string.test_ok, ms), error = false) }
                    .onFailure { error ->
                        showResult(getString(R.string.test_failed, shortError(error)), error = true)
                    }
            } finally {
                buttonRef.get()?.takeIf { it.isAttachedToWindow }?.isEnabled = true
            }
        }
    }

    private fun confirmDelete() {
        val presetId = selectedPresetId()
        val active = ConfigStore.llmPresetId(this) == presetId
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.remove_text_model_title)
            .setMessage(
                if (active) {
                    R.string.remove_text_model_message
                } else {
                    R.string.remove_text_model_inactive_message
                },
            )
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.remove) { _, _ ->
                ConfigStore.deleteLlmProfile(this, presetId)
                if (active) {
                    finish()
                } else {
                    val preset = Presets.llmById(presetId)
                    binding.llmBaseUrl.setText(preset.baseUrl)
                    binding.llmModel.setText(preset.model)
                    binding.llmApiKey.setText("")
                    binding.llmThinking.isChecked = ThinkingPolicy.defaultDisabled(preset.id)
                    updateThinkingAvailability()
                    binding.deleteLlm.isVisible = false
                }
            }
            .show()
    }

    private fun selectedPresetId(): String =
        Presets.llm.getOrElse(binding.llmPreset.selectedItemPosition) { Presets.llm.last() }.id

    private fun currentConfig(): LlmConfig {
        val preset = selectedPreset()
        return LlmConfig(
            baseUrl = formText(binding.llmBaseUrl),
            model = formText(binding.llmModel),
            apiKey = formText(binding.llmApiKey),
            providerId = preset.id,
            thinkingOff = preset.thinkingOff,
            reasoningSplit = preset.reasoningSplit,
            disableThinking = binding.llmThinking.isChecked,
        )
    }

    private fun selectedPreset() =
        Presets.llm.getOrElse(binding.llmPreset.selectedItemPosition) { Presets.llm.last() }

    private fun updateThinkingAvailability() {
        val preset = selectedPreset()
        val supported = ThinkingPolicy.supports(preset.id, formText(binding.llmModel))
        binding.llmThinking.isEnabled = supported
        if (!supported) binding.llmThinking.isChecked = false
        updateThinkingHint()
    }

    private fun updateThinkingHint() {
        val preset = selectedPreset()
        val model = formText(binding.llmModel)
        val reason = ThinkingPolicy.unavailableReason(preset.id, model)
        if (reason != null) {
            binding.llmThinkingHint.setText(
                when (reason) {
                    ThinkingUnavailable.ALWAYS_THINKS -> R.string.thinking_always
                    ThinkingUnavailable.CLAUDE_MODEL -> R.string.thinking_claude_unavailable
                    ThinkingUnavailable.REASONING_SPLIT -> R.string.thinking_reasoning_split
                    ThinkingUnavailable.NO_PARAMETER -> R.string.thinking_no_parameter
                },
            )
            return
        }
        if (!binding.llmThinking.isChecked) {
            binding.llmThinkingHint.setText(R.string.thinking_default)
            return
        }
        val field = ThinkingPolicy.fieldFor(preset.id, model)
        binding.llmThinkingHint.text = when (field) {
            ThinkingField.THINKING -> {
                val type = ThinkingPolicy.claudeOffType(model)
                if (type != null) {
                    getString(R.string.thinking_claude, type)
                } else {
                    getString(R.string.thinking_thinking)
                }
            }

            ThinkingField.ENABLE_THINKING -> getString(R.string.thinking_enable)
            ThinkingField.REASONING_EFFORT -> getString(R.string.thinking_reasoning_effort)
            ThinkingField.REASONING -> getString(R.string.thinking_reasoning)
            ThinkingField.THINK -> getString(R.string.thinking_think)
            null -> getString(R.string.thinking_default)
        }
    }

    private fun showResult(message: String, error: Boolean) =
        showFormResult(binding.llmResult, message, error)
}
