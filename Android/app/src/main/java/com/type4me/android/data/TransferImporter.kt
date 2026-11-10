package com.type4me.android.data

import android.content.Context
import com.type4me.android.llm.ThinkingPolicy
import com.type4me.android.pipeline.Mode
import com.type4me.android.pipeline.ModeDefinition
import com.type4me.android.pipeline.ModeLibrary
import com.type4me.android.pipeline.ModePunctuation

data class ImportResult(
    val asrName: String?,
    val llmName: String?,
    val hotwordCount: Int,
    val snippetCount: Int,
    val modeCount: Int,
    val skippedAsr: List<String>,
    val skippedLlm: List<String>,
)

/**
 * Applies a scanned Mac configuration to this app's stores.
 *
 * The Mac can carry any number of services, models and custom modes; this
 * version keeps one speech service, one text model and the built-in modes,
 * so anything else is reported as skipped instead of being dropped silently.
 */
object TransferImporter {

    /** Speech services this build can speak to. */
    private val openAICompatibleAsr = setOf("openai", "groq", "mistral", "siliconflow", "custom")

    private val llmPresetIds = mapOf(
        "deepseek" to "deepseek",
        "kimi" to "moonshot",
        "moonshot" to "moonshot",
        "bailian" to "bailian",
        "doubao" to "volcengine",
        "volcengine" to "volcengine",
        "openai" to "openai",
        "zhipu" to "zhipu",
        "mimo" to "mimo",
        "minimaxCN" to "minimaxCN",
        "minimaxIntl" to "minimaxIntl",
        "openrouter" to "openrouter",
        "gemini" to "gemini",
        "claude" to "claude",
    )

    fun apply(
        context: Context,
        payload: TransferPayload,
        selection: ImportSelection = ImportSelection.all(payload),
    ): ImportResult {
        val asrEndpoints = payload.allAsrs.filter { it.provider in selection.asrs }
        val importedAsrs = asrEndpoints.mapNotNull { asrConfig(it) }
        importedAsrs.forEach { (presetId, config) ->
            ConfigStore.saveAsr(context, presetId, config)
        }
        selection.activeAsr?.let { active ->
            val match = importedAsrs.firstOrNull { it.first == active }
                ?: importedAsrs.firstOrNull { active == "custom" && it.first == "customhttp" }
            match?.let { (presetId, _) -> ConfigStore.setAsrPreset(context, presetId) }
        }
        val asr = importedAsrs.firstOrNull()

        val llms = payload.allLlms
            .filter { it.provider in selection.llms }
            .mapNotNull { endpoint -> llmConfig(endpoint)?.let { endpoint.provider to it.second } }
        llms.forEach { (provider, config) ->
            ConfigStore.saveLlm(context, llmPresetIds[provider] ?: provider, config)
        }
        selection.activeLlm?.let { active ->
            llms.firstOrNull { it.first == active }?.let { (provider, _) ->
                ConfigStore.setLlmPreset(context, llmPresetIds[provider] ?: provider)
            }
        }

        var modeCount = 0
        payload.modes.filter { it.id in selection.modes }.forEach { incoming ->
            val imported = mode(incoming) ?: return@forEach
            val existing = ModeLibrary.byId(context, imported.id)
            val merged = (existing ?: imported).copy(
                name = incoming.name ?: existing?.name,
                prompt = incoming.prompt?.takeIf { it.isNotBlank() }
                    ?: existing?.prompt
                    ?: imported.prompt,
                onKeyboard = true,
                translateTarget = incoming.targetLanguage ?: existing?.translateTarget,
                punctuation = incoming.punctuation?.let {
                    runCatching { ModePunctuation.valueOf(it) }.getOrNull()
                } ?: existing?.punctuation ?: ModePunctuation.INHERIT,
                shortTextExemption = incoming.shortTextExemption
                    ?: existing?.shortTextExemption
                    ?: 0,
            )
            ModeLibrary.upsert(context, merged)
            modeCount++
        }
        // The Mac stores one translate target globally. Apply it to the
        // built-in Translate mode even when that mode was not checked above.
        payload.modes.firstOrNull { it.targetLanguage != null }
            ?.targetLanguage
            ?.let { target ->
                ModeLibrary.byId(context, Mode.TRANSLATE.name)?.let { mode ->
                    ModeLibrary.upsert(context, mode.copy(translateTarget = target))
                }
            }

        val incomingHotwords = if (selection.hotwords) payload.hotwords.orEmpty() else emptyList()
        val incomingSnippets = if (selection.snippets) payload.snippets.orEmpty() else emptyList()
        if (incomingHotwords.isNotEmpty() || incomingSnippets.isNotEmpty()) {
            val existingHotwords = VocabularyStore.hotwords(context)
            val mergedHotwords = (existingHotwords + incomingHotwords)
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .distinctBy { it.lowercase() }
            val existingSnippets = VocabularyStore.snippets(context)
            val mergedSnippets = existingSnippets.toMutableList()
            incomingSnippets.forEach { snippet ->
                val trigger = snippet.trigger.trim()
                if (trigger.isEmpty()) return@forEach
                val index = mergedSnippets.indexOfFirst {
                    it.trigger.replace(" ", "").lowercase() ==
                        trigger.replace(" ", "").lowercase()
                }
                if (index >= 0) mergedSnippets[index] = snippet else mergedSnippets.add(snippet)
            }
            VocabularyStore.save(context, mergedHotwords, mergedSnippets)
        }

        if (selection.textOutput) {
            payload.textOutput?.let { output ->
                output.cjkSpacing?.let { value ->
                    val spacing = when (value.lowercase()) {
                        "pangu", "on" -> CjkSpacing.PANGU
                        "remove" -> CjkSpacing.REMOVE
                        else -> CjkSpacing.KEEP
                    }
                    TextOutputStore.setSpacing(context, spacing)
                }
                output.trailingPunctuation?.let { value ->
                    val punctuation = when (value.lowercase()) {
                        "period" -> TrailingPunctuation.PERIOD
                        "all" -> TrailingPunctuation.ALL
                        else -> TrailingPunctuation.KEEP
                    }
                    TextOutputStore.setPunctuation(context, punctuation)
                }
                output.cornerQuotes?.let { TextOutputStore.setCornerQuotes(context, it) }
            }
        }

        val skippedAsr = asrEndpoints.filter { asrConfig(it) == null }.map { it.provider }
        val skippedLlm = payload.allLlms
            .filter { it.provider in selection.llms }
            .filter { endpoint -> llms.none { it.first == endpoint.provider } }
            .map { it.provider }

        return ImportResult(
            asrName = asr?.let { Presets.asrById(it.first).displayName },
            llmName = llms.firstOrNull()?.second?.model?.takeIf { it.isNotBlank() },
            hotwordCount = incomingHotwords.size,
            snippetCount = incomingSnippets.size,
            modeCount = modeCount,
            skippedAsr = skippedAsr,
            skippedLlm = skippedLlm,
        )
    }

    private fun asrConfig(endpoint: TransferEndpoint): Pair<String, AsrConfig>? {
        val fields = endpoint.fields
        return when (endpoint.provider) {
            "volcano" -> {
                val apiKey = fields["apiKey"].orEmpty()
                val appKey = fields["appKey"].orEmpty()
                val accessKey = fields["accessKey"].orEmpty()
                val legacy = apiKey.isBlank() && appKey.isNotBlank() && accessKey.isNotBlank()
                if (apiKey.isBlank() && !legacy) {
                    null
                } else {
                    val resource = when (fields["resourceId"]) {
                        Presets.VOLC_RESOURCE_BIG, Presets.VOLC_RESOURCE_SEED -> fields["resourceId"]!!
                        else -> Presets.VOLC_RESOURCE_SEED
                    }
                    "volcano" to AsrConfig(
                        kind = AsrKind.VOLCANO,
                        apiKey = apiKey,
                        appKey = if (legacy) appKey else "",
                        accessKey = if (legacy) accessKey else "",
                        resourceId = resource,
                    )
                }
            }

            "soniox" -> {
                val apiKey = fields["apiKey"].orEmpty()
                if (apiKey.isBlank()) {
                    null
                } else {
                    "soniox" to AsrConfig(
                        kind = AsrKind.SONIOX,
                        model = fields["model"] ?: "stt-rt-v5",
                        apiKey = apiKey,
                        endpointSensitivity = fields["endpointSensitivity"]?.toDoubleOrNull()
                            ?.takeIf { it in -1.0..1.0 } ?: -0.3,
                    )
                }
            }

            "custom" -> {
                // The Mac's Custom provider is a full HTTP template, not the
                // old OpenAI-compatible preset.
                customHttpConfig(fields)
            }

            else -> {
                if (endpoint.provider in openAICompatibleAsr) {
                    val baseUrl = fields["baseURL"].orEmpty()
                    val model = fields["model"].orEmpty()
                    if (baseUrl.isBlank() || model.isBlank()) return null
                    return endpoint.provider to AsrConfig(
                        kind = AsrKind.OPENAI,
                        baseUrl = baseUrl,
                        model = model,
                        apiKey = fields["apiKey"].orEmpty(),
                    )
                }
                val preset = Presets.asr.firstOrNull { it.id == endpoint.provider } ?: return null
                val batch = fields["recognitionMode"] == "batch" && preset.batchKind != null
                val extra = fields.filterKeys {
                    it !in setOf("apiKey", "baseURL", "model", "appKey", "accessKey", "resourceId")
                }
                val fallbackBaseUrl = if (batch) {
                    preset.batchBaseUrl.ifBlank { preset.baseUrl }
                } else {
                    preset.baseUrl
                }
                endpoint.provider to AsrConfig(
                    kind = if (batch) preset.batchKind ?: preset.kind else preset.kind,
                    providerId = endpoint.provider,
                    baseUrl = fields["baseURL"].orEmpty().ifBlank { fallbackBaseUrl },
                    model = fields["model"].orEmpty().ifBlank {
                        if (batch) preset.batchModel else preset.model
                    },
                    apiKey = fields["apiKey"].orEmpty(),
                    appKey = fields["appKey"].orEmpty(),
                    accessKey = fields["accessKey"].orEmpty(),
                    extra = preset.extra + extra,
                )
            }
        }
    }

    private fun customHttpConfig(fields: Map<String, String>): Pair<String, AsrConfig>? {
        val url = fields["baseURL"].orEmpty().ifBlank { fields["url"].orEmpty() }
        if (url.isBlank()) return null
        val hasTemplate = !fields["bodyTemplate"].isNullOrBlank() ||
            !fields["jsonTemplate"].isNullOrBlank() ||
            !fields["headers"].isNullOrBlank()
        if (!hasTemplate) {
            // An older OpenAI-compatible custom endpoint.
            return "custom" to AsrConfig(
                kind = AsrKind.OPENAI,
                providerId = "custom",
                baseUrl = url,
                model = fields["model"].orEmpty(),
                apiKey = fields["apiKey"].orEmpty(),
            )
        }
        return "customhttp" to AsrConfig(
            kind = AsrKind.BATCH,
            providerId = "custom",
            baseUrl = url,
            model = fields["model"].orEmpty(),
            apiKey = fields["apiKey"].orEmpty(),
            extra = fields,
        )
    }

    private fun llmConfig(endpoint: TransferEndpoint): Pair<String, LlmConfig>? {
        val baseUrl = endpoint.fields["baseURL"].orEmpty().trimEnd('/')
        val model = endpoint.fields["model"].orEmpty()
        if (baseUrl.isBlank() || model.isBlank()) return null
        val presetId = llmPresetIds[endpoint.provider] ?: "custom"
        val preset = Presets.llm.firstOrNull { it.id == presetId }
        return presetId to LlmConfig(
            baseUrl = baseUrl,
            model = model,
            apiKey = endpoint.fields["apiKey"].orEmpty(),
            providerId = endpoint.provider,
            thinkingOff = preset?.thinkingOff,
            reasoningSplit = preset?.reasoningSplit ?: false,
            disableThinking = ThinkingPolicy.defaultDisabled(endpoint.provider),
        )
    }

    private fun mode(mode: TransferMode): ModeDefinition? = when (mode.kind) {
        "quick" -> ModeDefinition.builtIn(Mode.QUICK)
        "formalWriting" -> ModeDefinition.builtIn(Mode.POLISH)
        "translateEnglish" -> ModeDefinition.builtIn(Mode.TRANSLATE)
        "agentMode" -> ModeDefinition.builtIn(Mode.AGENT)
        "intelliSense" -> ModeDefinition.builtIn(Mode.INTELLI_SENSE)
        "custom" -> {
            val prompt = mode.prompt?.takeIf { it.isNotBlank() } ?: return null
            ModeDefinition(
                id = mode.id.ifBlank { "custom-mac" },
                kind = Mode.CUSTOM,
                name = mode.name ?: "Mac",
                prompt = prompt,
            )
        }
        else -> null
    }
}
