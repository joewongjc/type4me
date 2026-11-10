package com.type4me.android

import android.os.Bundle
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.doOnLayout
import androidx.core.view.isVisible
import androidx.core.view.updatePadding
import androidx.lifecycle.lifecycleScope
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.type4me.android.ui.applyNavBarTopInset
import com.type4me.android.asr.BatchAsr
import com.type4me.android.asr.StreamingAsr
import com.type4me.android.data.AsrConfig
import com.type4me.android.data.AsrKind
import com.type4me.android.data.AsrPreset
import com.type4me.android.data.ConfigStore
import com.type4me.android.data.Presets
import com.type4me.android.databinding.ActivitySpeechServiceBinding
import kotlinx.coroutines.launch

class SpeechServiceActivity : AppCompatActivity() {

    private lateinit var binding: ActivitySpeechServiceBinding
    private var loading = false
    private var asrKind = AsrKind.OPENAI
    /** Secret extras of the service shown on screen; the editor only shows them masked. */
    private var savedSecretExtras: Map<String, String> = emptyMap()

    private val sensitivities = listOf(-0.5, -0.3, 0.0, 0.3, 0.5)

    private companion object {
        /** Shown instead of a saved secret; a line with this value keeps the stored key. */
        const val SECRET_MASK = "••••"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        binding = ActivitySpeechServiceBinding.inflate(layoutInflater)
        setContentView(binding.root)
        applyInsets()

        binding.back.setOnClickListener { finish() }
        binding.saveAsr.setOnClickListener { saveAsr() }
        binding.testAsr.setOnClickListener { testAsr() }
        binding.deleteAsr.setOnClickListener { confirmDelete() }
        setupSpinners()
        loadConfig()
        // A Spinner can deliver a queued selection callback on first layout,
        // which would overwrite the saved values.
        binding.root.doOnLayout { attachPresetListeners() }
    }

    override fun onResume() {
        super.onResume()
        binding.deleteAsr.isVisible =
            ConfigStore.asrProfile(this, selectedPresetId()) != null
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

    private fun setupSpinners() {
        binding.asrPreset.adapter = ArrayAdapter(
            this,
            android.R.layout.simple_spinner_item,
            Presets.asr.map { if (it.id == "custom") getString(R.string.custom_provider) else it.displayName },
        ).apply { setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item) }

        binding.volcAuthMode.adapter = simpleAdapter(
            listOf(
                getString(R.string.asr_auth_api_key),
                getString(R.string.asr_auth_legacy),
            ),
        )
        binding.volcAuthMode.onItemSelectedListener = onSelected { refreshProviderFields() }

        binding.volcResource.adapter = simpleAdapter(
            listOf(
                getString(R.string.asr_resource_seed),
                getString(R.string.asr_resource_big),
            ),
        )

        binding.sonioxSensitivity.adapter = simpleAdapter(
            listOf(
                getString(R.string.sensitivity_patient),
                getString(R.string.sensitivity_recommended),
                getString(R.string.sensitivity_standard),
                getString(R.string.sensitivity_responsive),
                getString(R.string.sensitivity_very_responsive),
            ),
        )
        binding.asrMode.adapter = simpleAdapter(
            listOf(
                getString(R.string.asr_mode_streaming),
                getString(R.string.asr_mode_batch),
            ),
        )
        binding.asrMode.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(
                parent: AdapterView<*>?,
                view: View?,
                position: Int,
                id: Long,
            ) {
                if (loading) return
                val preset = Presets.asrById(selectedPresetId())
                val batch = position == 1
                val kind = if (batch) preset.batchKind ?: preset.kind else preset.kind
                // A programmatic selection replays this callback with the kind already
                // applied; leave the values that were just filled from the saved config.
                if (kind == asrKind) return
                asrKind = kind
                val baseUrl = if (batch) preset.batchBaseUrl else preset.baseUrl
                if (baseUrl.isNotBlank()) binding.asrBaseUrl.setText(baseUrl)
                if (batch && preset.batchModel.isNotBlank()) {
                    binding.asrModel.setText(preset.batchModel)
                } else if (preset.model.isNotBlank()) {
                    binding.asrModel.setText(preset.model)
                }
                refreshProviderFields()
            }

            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }
    }

    private fun attachPresetListeners() {
        binding.asrPreset.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(
                parent: AdapterView<*>?,
                view: View?,
                position: Int,
                id: Long,
            ) {
                if (loading) return
                val preset = Presets.asr.getOrElse(position) { Presets.asr.last() }
                val saved = ConfigStore.asrProfile(this@SpeechServiceActivity, preset.id)
                if (saved != null) fillFromConfig(saved) else applyAsrPreset(preset)
                binding.deleteAsr.isVisible = saved != null
            }

            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }
    }

    private fun applyAsrPreset(preset: AsrPreset) {
        asrKind = preset.kind
        savedSecretExtras = emptyMap()
        binding.asrMode.setSelection(0, false)
        when (preset.kind) {
            AsrKind.OPENAI -> {
                if (preset.id != "custom") {
                    binding.asrBaseUrl.setText(preset.baseUrl)
                    binding.asrModel.setText(preset.model)
                }
            }

            AsrKind.VOLCANO -> {
                binding.volcAuthMode.setSelection(0)
                binding.volcResource.setSelection(
                    if (preset.resourceId == Presets.VOLC_RESOURCE_BIG) 1 else 0,
                )
            }

            AsrKind.SONIOX -> {
                binding.sonioxSensitivity.setSelection(sensitivityIndex(preset.sensitivity))
            }

            AsrKind.STREAMING, AsrKind.BATCH -> {
                if (preset.id != "custom") {
                    binding.asrBaseUrl.setText(preset.baseUrl)
                    binding.asrModel.setText(preset.model)
                }
                binding.asrExtra.setText(extraText(preset.extra))
            }
        }
        refreshProviderFields()
    }

    private fun refreshProviderFields() {
        val kind = asrKind
        val preset = Presets.asrById(selectedPresetId())
        binding.asrModeLabel.isVisible = preset.supportsBatch
        binding.asrMode.isVisible = preset.supportsBatch
        binding.asrBaseUrlLayout.isVisible = kind == AsrKind.OPENAI ||
            kind == AsrKind.STREAMING || kind == AsrKind.BATCH
        binding.asrModelLayout.isVisible = binding.asrBaseUrlLayout.isVisible
        binding.volcFields.isVisible = kind == AsrKind.VOLCANO
        binding.sonioxFields.isVisible = kind == AsrKind.SONIOX
        binding.asrExtraLayout.isVisible = kind == AsrKind.STREAMING || kind == AsrKind.BATCH

        val legacy = binding.volcAuthMode.selectedItemPosition == 1
        binding.asrApiKeyLayout.isVisible = !(kind == AsrKind.VOLCANO && legacy)
        binding.volcAppKeyLayout.isVisible = kind == AsrKind.VOLCANO && legacy
        binding.volcAccessKeyLayout.isVisible = kind == AsrKind.VOLCANO && legacy
    }

    private fun loadConfig() {
        loading = true
        try {
            val asrPresetId = ConfigStore.asrPresetId(this)
            val asrPresetIndex = Presets.asr.indexOfFirst { it.id == asrPresetId }.coerceAtLeast(0)
            binding.asrPreset.setSelection(asrPresetIndex, false)
            asrKind = Presets.asr[asrPresetIndex].kind

            val saved = ConfigStore.asrProfile(this, asrPresetId)
            if (saved != null) {
                fillFromConfig(saved)
            } else {
                applyAsrPreset(Presets.asr[asrPresetIndex])
            }
            refreshProviderFields()
            binding.deleteAsr.isVisible = saved != null
        } finally {
            loading = false
        }
    }

    private fun fillFromConfig(asr: AsrConfig) {
        asrKind = asr.kind
        val preset = Presets.asrById(selectedPresetId())
        val batch = preset.batchKind != null && asr.kind == preset.batchKind
        binding.asrMode.setSelection(if (batch) 1 else 0, false)
        binding.asrBaseUrl.setText(
            if (batch) batchBaseUrlFor(asr.baseUrl, preset) else asr.baseUrl,
        )
        binding.asrModel.setText(asr.model)
        binding.asrApiKey.setText(asr.apiKey)
        binding.volcAppKey.setText(asr.appKey)
        binding.volcAccessKey.setText(asr.accessKey)
        binding.volcAuthMode.setSelection(
            if (asr.appKey.isNotBlank() && asr.apiKey.isBlank()) 1 else 0,
            false,
        )
        binding.volcResource.setSelection(
            if (asr.resourceId == Presets.VOLC_RESOURCE_BIG) 1 else 0,
            false,
        )
        binding.sonioxSensitivity.setSelection(
            sensitivityIndex(asr.endpointSensitivity),
            false,
        )
        savedSecretExtras = asr.extra.filterKeys { ConfigStore.isSecretExtra(it) }
        binding.asrExtra.setText(extraText(asr.extra))
        refreshProviderFields()
        binding.deleteAsr.isVisible = true
    }

    private fun saveAsr() {
        val config = currentAsr()
        if (!config.isValid) {
            Toast.makeText(this, R.string.asr_incomplete, Toast.LENGTH_SHORT).show()
            return
        }
        val presetId = selectedPresetId()
        ConfigStore.saveAsr(this, presetId, config)
        Toast.makeText(this, R.string.saved, Toast.LENGTH_SHORT).show()
        finish()
    }

    private fun testAsr() {
        val config = currentAsr()
        if (!config.isValid) {
            Toast.makeText(this, R.string.asr_incomplete, Toast.LENGTH_SHORT).show()
            return
        }
        binding.testAsr.isEnabled = false
        showResult(getString(R.string.testing), error = false)
        lifecycleScope.launch {
            runCatching {
                if (config.isStreaming) StreamingAsr.test(config) else BatchAsr.test(config)
            }
                .onSuccess { ms ->
                    showResult(getString(R.string.test_ok, ms), error = false)
                }
                .onFailure { error ->
                    showResult(getString(R.string.test_failed, short(error)), error = true)
                }
            binding.testAsr.isEnabled = true
        }
    }

    private fun confirmDelete() {
        val presetId = selectedPresetId()
        val wasActive = ConfigStore.asrPresetId(this) == presetId
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.remove_speech_service_title)
            .setMessage(
                if (wasActive) {
                    R.string.remove_speech_service_message
                } else {
                    R.string.remove_speech_service_inactive_message
                },
            )
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.remove) { _, _ ->
                ConfigStore.deleteAsrProfile(this, presetId)
                if (wasActive) {
                    finish()
                } else {
                    applyAsrPreset(Presets.asrById(presetId))
                    binding.deleteAsr.isVisible = false
                }
            }
            .show()
    }

    private fun currentAsr(): AsrConfig = when (asrKind) {
        AsrKind.OPENAI -> AsrConfig(
            kind = AsrKind.OPENAI,
            baseUrl = text(binding.asrBaseUrl),
            model = text(binding.asrModel),
            apiKey = text(binding.asrApiKey),
        )

        AsrKind.VOLCANO -> {
            val legacy = binding.volcAuthMode.selectedItemPosition == 1
            AsrConfig(
                kind = AsrKind.VOLCANO,
                apiKey = if (legacy) "" else text(binding.asrApiKey),
                appKey = if (legacy) text(binding.volcAppKey) else "",
                accessKey = if (legacy) text(binding.volcAccessKey) else "",
                resourceId = if (binding.volcResource.selectedItemPosition == 1) {
                    Presets.VOLC_RESOURCE_BIG
                } else {
                    Presets.VOLC_RESOURCE_SEED
                },
            )
        }

        AsrKind.SONIOX -> AsrConfig(
            kind = AsrKind.SONIOX,
            model = "stt-rt-v5",
            apiKey = text(binding.asrApiKey),
            endpointSensitivity = sensitivities[
                binding.sonioxSensitivity.selectedItemPosition.coerceIn(0, sensitivities.lastIndex)
            ],
        )

        AsrKind.STREAMING, AsrKind.BATCH -> {
            val preset = Presets.asrById(selectedPresetId())
            val presetId = selectedPresetId()
            val batch = preset.supportsBatch && binding.asrMode.selectedItemPosition == 1
            AsrConfig(
                kind = if (batch) preset.batchKind ?: preset.kind else preset.kind,
                providerId = if (presetId == "customhttp") "custom" else presetId,
                baseUrl = text(binding.asrBaseUrl).ifBlank {
                    if (batch) preset.batchBaseUrl.ifBlank { preset.baseUrl } else preset.baseUrl
                },
                model = text(binding.asrModel).ifBlank {
                    if (batch) preset.batchModel else preset.model
                },
                apiKey = text(binding.asrApiKey),
                // Secret extras are shown masked, so keep their saved values and
                // let anything typed in the editor win.
                extra = preset.extra +
                    savedSecretExtras +
                    ConfigStore.secretExtras(this, presetId) +
                    parseExtra(text(binding.asrExtra)),
            )
        }
    }

    private fun batchBaseUrlFor(saved: String, preset: AsrPreset): String {
        if (preset.batchBaseUrl.isBlank()) return saved
        val lower = saved.trim().lowercase()
        return if (lower.startsWith("ws://") || lower.startsWith("wss://")) {
            preset.batchBaseUrl
        } else {
            saved
        }
    }

    private fun extraText(extra: Map<String, String>): String =
        extra.entries.joinToString("\n") { (key, value) ->
            val shown = if (ConfigStore.isSecretExtra(key)) SECRET_MASK else value
            "$key=${escapeExtra(shown)}"
        }

    /** Values are line-based here, so a multi-line value is escaped onto one line. */
    private fun escapeExtra(value: String): String = value
        .replace("\\", "\\\\")
        .replace("\r", "\\r")
        .replace("\n", "\\n")

    private fun unescapeExtra(value: String): String = buildString(value.length) {
        var index = 0
        while (index < value.length) {
            val char = value[index]
            if (char != '\\' || index == value.lastIndex) {
                append(char)
                index++
                continue
            }
            when (val next = value[index + 1]) {
                'n' -> append('\n')
                'r' -> append('\r')
                '\\' -> append('\\')
                else -> {
                    append(char)
                    append(next)
                }
            }
            index += 2
        }
    }

    private fun parseExtra(text: String): Map<String, String> = text.lineSequence()
        .map { it.trim() }
        .filter { it.contains('=') }
        .associate { line ->
            val key = line.substringBefore('=').trim()
            val value = unescapeExtra(line.substringAfter('=', "").trim())
            key to value
        }
        .filterKeys { it.isNotEmpty() }
        .filterValues { it != SECRET_MASK }

    private fun sensitivityIndex(value: Double): Int {
        val index = sensitivities.indexOfFirst { kotlin.math.abs(it - value) < 0.001 }
        return if (index >= 0) index else 1
    }

    private fun selectedPresetId(): String =
        Presets.asr.getOrElse(binding.asrPreset.selectedItemPosition) { Presets.asr.last() }.id

    private fun simpleAdapter(items: List<String>): ArrayAdapter<String> =
        ArrayAdapter(this, android.R.layout.simple_spinner_item, items).apply {
            setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        }

    private fun onSelected(action: () -> Unit) = object : AdapterView.OnItemSelectedListener {
        override fun onItemSelected(
            parent: AdapterView<*>?,
            view: View?,
            position: Int,
            id: Long,
        ) {
            if (!loading) action()
        }

        override fun onNothingSelected(parent: AdapterView<*>?) = Unit
    }

    private fun text(view: TextView): String = view.text?.toString()?.trim().orEmpty()

    private fun showResult(message: String, error: Boolean) {
        binding.asrResult.visibility = View.VISIBLE
        binding.asrResult.text = message
        binding.asrResult.setTextColor(
            ContextCompat.getColor(this, if (error) R.color.brand_red else R.color.success),
        )
    }

    private fun short(error: Throwable): String =
        (error.message ?: error.javaClass.simpleName).take(160)
}
