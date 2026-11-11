package com.type4me.android.data

import android.content.Context
import com.type4me.android.llm.ThinkingPolicy
import com.type4me.android.pipeline.ModeDefinition
import com.type4me.android.pipeline.ModeLibrary
import org.json.JSONObject

/** Kept in the data package for existing call sites; the list lives with modes. */
typealias TranslateTarget = com.type4me.android.pipeline.TranslateTarget

data class AsrConfig(
    val kind: AsrKind = AsrKind.OPENAI,
    val providerId: String = "",
    val baseUrl: String = "",
    val model: String = "",
    val apiKey: String = "",
    val appKey: String = "",
    val accessKey: String = "",
    val resourceId: String = Presets.VOLC_RESOURCE_SEED,
    val endpointSensitivity: Double = -0.3,
    /** Provider-specific fields (region, language, deployment, headers, …). */
    val extra: Map<String, String> = emptyMap(),
) {
    val isStreaming: Boolean get() = kind != AsrKind.OPENAI && kind != AsrKind.BATCH

    val isValid: Boolean
        get() = when (kind) {
            AsrKind.OPENAI -> baseUrl.isNotBlank() && model.isNotBlank()
            AsrKind.VOLCANO -> resourceId.isNotBlank() &&
                (apiKey.isNotBlank() || (appKey.isNotBlank() && accessKey.isNotBlank()))
            AsrKind.SONIOX -> apiKey.isNotBlank()
            AsrKind.STREAMING, AsrKind.BATCH ->
                providerId.isNotBlank() &&
                    (apiKey.isNotBlank() || appKey.isNotBlank() ||
                        extra["intlApiKey"]?.isNotBlank() == true ||
                        extra["secretId"]?.isNotBlank() == true ||
                        (providerId == "custom" && baseUrl.isNotBlank()))
        }
}

data class LlmConfig(
    val baseUrl: String,
    val model: String,
    val apiKey: String,
    val providerId: String = "custom",
    val reasoningEffort: String? = null,
    /** Legacy transfer hint; request shaping uses [com.type4me.android.llm.ThinkingPolicy]. */
    val thinkingOff: String? = null,
    val reasoningSplit: Boolean = false,
    val disableThinking: Boolean = true,
) {
    val isValid: Boolean get() = baseUrl.isNotBlank() && model.isNotBlank()
}

object ConfigStore {
    private const val PREFS = "type4me"
    private const val KEY_ASR_PRESET = "asr.preset"
    private const val KEY_ASR_PROFILES = "asr.profiles"
    private const val KEY_ASR_KIND = "asr.kind"
    private const val KEY_ASR_BASE_URL = "asr.baseUrl"
    private const val KEY_ASR_MODEL = "asr.model"
    private const val KEY_ASR_APP_KEY = "asr.appKey"
    private const val KEY_ASR_RESOURCE_ID = "asr.resourceId"
    private const val KEY_ASR_SENSITIVITY = "asr.sensitivity"
    private const val KEY_ASR_EXTRA = "asr.extra"
    private const val KEY_ASR_API_KEY = "asr.apiKey"
    private const val KEY_ASR_ACCESS_KEY = "asr.accessKey"
    private const val KEY_ASR_HAS_API_KEY = "asr.hasApiKey"
    private const val KEY_ASR_HAS_ACCESS_KEY = "asr.hasAccessKey"
    private const val KEY_LLM_PRESET = "llm.preset"
    private const val KEY_LLM_PROFILES = "llm.profiles"
    private const val KEY_LLM_BASE_URL = "llm.baseUrl"
    private const val KEY_LLM_MODEL = "llm.model"
    private const val KEY_LLM_API_KEY = "llm.apiKey"
    private const val KEY_MODE = "dictation.mode"
    private const val KEY_ENABLED_MODES = "dictation.enabledModes"
    private const val KEY_TRANSLATE_TARGET = "translate.target"
    private const val KEY_ASR_SAVED = "asr.savedOnce"

    /** Provider fields that must never sit in plain SharedPreferences. */
    private val SECRET_EXTRA_KEYS = setOf(
        "secretKey",
        "secretId",
        "apiKey",
        "intlApiKey",
        "appKey",
        "accessKey",
        "token",
        "accessToken",
        "refreshToken",
    )

    fun isSecretExtra(key: String): Boolean = key in SECRET_EXTRA_KEYS

    // Keystore decryption is too slow for the recording-start path; keep the
    // last decrypted values for this process.
    @Volatile private var cachedAsr: AsrConfig? = null
    @Volatile private var cachedLlm: LlmConfig? = null
    @Volatile private var llmLoaded = false

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun asr(context: Context): AsrConfig {
        cachedAsr?.let { return it }
        val config = asrProfile(context, asrPresetId(context)) ?: legacyAsr(context)
        cachedAsr = config
        return config
    }

    /** A saved speech service for one preset, with its own encrypted keys. */
    fun asrProfile(context: Context, presetId: String): AsrConfig? {
        val profile = asrProfiles(context).optJSONObject(presetId)
            ?: return if (presetId == asrPresetId(context)) {
                legacyAsr(context).takeIf { it.isValid }
            } else {
                null
            }
        val extra = buildMap {
            profile.optJSONObject("extra")?.let { objectJson ->
                for (key in objectJson.keys()) put(key, objectJson.optString(key))
            }
            putAll(secretExtras(context, presetId))
        }
        return AsrConfig(
            kind = runCatching { AsrKind.valueOf(profile.optString("kind")) }
                .getOrDefault(AsrKind.OPENAI),
            providerId = profile.optString("providerId").ifBlank { presetId },
            baseUrl = profile.optString("baseUrl"),
            model = profile.optString("model"),
            apiKey = SecureStore.get(context, "$KEY_ASR_API_KEY.$presetId"),
            appKey = profile.optString("appKey"),
            accessKey = SecureStore.get(context, "$KEY_ASR_ACCESS_KEY.$presetId"),
            resourceId = profile.optString("resourceId").ifBlank { Presets.VOLC_RESOURCE_SEED },
            endpointSensitivity = profile.optDouble("sensitivity", -0.3),
            extra = extra,
        )
    }

    /** The decrypted secret extras saved for one speech service. */
    fun secretExtras(context: Context, presetId: String): Map<String, String> = buildMap {
        SECRET_EXTRA_KEYS.forEach { key ->
            val value = SecureStore.get(context, extraKey(presetId, key))
            if (value.isNotEmpty()) put(key, value)
        }
    }

    private fun legacyAsr(context: Context): AsrConfig {
        val store = prefs(context)
        return AsrConfig(
            kind = AsrKind.entries.firstOrNull {
                it.name == store.getString(KEY_ASR_KIND, null)
            } ?: AsrKind.OPENAI,
            providerId = store.getString(KEY_ASR_PRESET, "").orEmpty(),
            baseUrl = store.getString(KEY_ASR_BASE_URL, "").orEmpty(),
            model = store.getString(KEY_ASR_MODEL, "").orEmpty(),
            apiKey = SecureStore.get(context, KEY_ASR_API_KEY),
            appKey = store.getString(KEY_ASR_APP_KEY, "").orEmpty(),
            accessKey = SecureStore.get(context, KEY_ASR_ACCESS_KEY),
            resourceId = store.getString(KEY_ASR_RESOURCE_ID, Presets.VOLC_RESOURCE_SEED)
                .orEmpty(),
            endpointSensitivity = store.getFloat(KEY_ASR_SENSITIVITY, -0.3f).toDouble(),
            extra = runCatching {
                val json = JSONObject(store.getString(KEY_ASR_EXTRA, "{}").orEmpty())
                buildMap { for (key in json.keys()) put(key, json.optString(key)) }
            }.getOrDefault(emptyMap()),
        )
    }

    fun saveAsr(context: Context, presetId: String, config: AsrConfig) {
        val profiles = asrProfiles(context)
        // The preset id is a storage slot; the provider id is what the client dispatches on.
        val providerId = config.providerId.ifBlank { presetId }
        val safeExtra = config.extra.filterKeys { it !in SECRET_EXTRA_KEYS }
        SECRET_EXTRA_KEYS.forEach { key ->
            config.extra[key]?.let { value ->
                SecureStore.put(context, extraKey(presetId, key), value)
            }
        }
        profiles.put(
            presetId,
            JSONObject()
                .put("kind", config.kind.name)
                .put("providerId", providerId)
                .put("baseUrl", config.baseUrl.trim())
                .put("model", config.model.trim())
                .put("appKey", config.appKey.trim())
                .put("resourceId", config.resourceId)
                .put("sensitivity", config.endpointSensitivity)
                .put(
                    "extra",
                    JSONObject().apply {
                        safeExtra.forEach { (key, value) -> put(key, value) }
                    },
                ),
        )
        prefs(context).edit()
            .putString(KEY_ASR_PRESET, presetId)
            .putString(KEY_ASR_PROFILES, profiles.toString())
            .putString(KEY_ASR_KIND, config.kind.name)
            .putString(KEY_ASR_BASE_URL, config.baseUrl.trim())
            .putString(KEY_ASR_MODEL, config.model.trim())
            .putString(KEY_ASR_APP_KEY, config.appKey.trim())
            .putString(KEY_ASR_RESOURCE_ID, config.resourceId)
            .putFloat(KEY_ASR_SENSITIVITY, config.endpointSensitivity.toFloat())
            .putString(
                KEY_ASR_EXTRA,
                JSONObject().apply {
                    safeExtra.forEach { (key, value) -> put(key, value) }
                }.toString(),
            )
            .putBoolean(KEY_ASR_HAS_API_KEY, config.apiKey.isNotBlank())
            .putBoolean(KEY_ASR_HAS_ACCESS_KEY, config.accessKey.isNotBlank())
            .putBoolean(KEY_ASR_SAVED, true)
            .apply()
        SecureStore.put(context, "$KEY_ASR_API_KEY.$presetId", config.apiKey.trim())
        SecureStore.put(context, "$KEY_ASR_ACCESS_KEY.$presetId", config.accessKey.trim())
        cachedAsr = config.copy(
            providerId = providerId,
            baseUrl = config.baseUrl.trim(),
            model = config.model.trim(),
            apiKey = config.apiKey.trim(),
            appKey = config.appKey.trim(),
            accessKey = config.accessKey.trim(),
        )
    }

    private fun asrProfiles(context: Context): JSONObject =
        runCatching { JSONObject(prefs(context).getString(KEY_ASR_PROFILES, "{}").orEmpty()) }
            .getOrDefault(JSONObject())

    fun asrPresetId(context: Context): String =
        prefs(context).getString(KEY_ASR_PRESET, Presets.asr.first().id).orEmpty()

    fun setAsrPreset(context: Context, presetId: String) {
        prefs(context).edit().putString(KEY_ASR_PRESET, presetId).apply()
        cachedAsr = null
    }

    fun hasAsrConfig(context: Context): Boolean =
        asrProfile(context, asrPresetId(context))?.isValid == true

    fun llm(context: Context): LlmConfig? {
        if (llmLoaded) return cachedLlm
        val config = llmProfile(context, llmPresetId(context))
        cachedLlm = config
        llmLoaded = true
        return config
    }

    /** A saved model for one preset, with its own encrypted key. */
    fun llmProfile(context: Context, presetId: String): LlmConfig? {
        val profiles = profiles(context)
        val profile = profiles.optJSONObject(presetId)
        if (profile == null) {
            // Migrate the single configured model from before profiles existed.
            if (presetId != llmPresetId(context)) return null
            val store = prefs(context)
            val legacy = LlmConfig(
                baseUrl = store.getString(KEY_LLM_BASE_URL, "").orEmpty(),
                model = store.getString(KEY_LLM_MODEL, "").orEmpty(),
                apiKey = SecureStore.get(context, KEY_LLM_API_KEY),
                providerId = presetId,
                disableThinking = ThinkingPolicy.defaultDisabled(presetId),
            )
            return legacy.takeIf { it.isValid }
        }
        return LlmConfig(
            baseUrl = profile.optString("baseUrl"),
            model = profile.optString("model"),
            apiKey = SecureStore.get(context, keyFor(presetId)),
            providerId = presetId,
            reasoningEffort = profile.optString("reasoningEffort").takeIf { it.isNotBlank() },
            thinkingOff = profile.optString("thinkingOff").takeIf { it.isNotBlank() },
            reasoningSplit = profile.optBoolean("reasoningSplit", false),
            disableThinking = profile.optBoolean(
                "disableThinking",
                ThinkingPolicy.defaultDisabled(presetId),
            ),
        ).takeIf { it.isValid }
    }

    fun saveLlm(context: Context, presetId: String, config: LlmConfig) {
        val profiles = profiles(context)
        profiles.put(
            presetId,
            JSONObject()
                .put("baseUrl", config.baseUrl.trim())
                .put("model", config.model.trim())
                .put("reasoningEffort", config.reasoningEffort ?: "")
                .put("thinkingOff", config.thinkingOff ?: "")
                .put("reasoningSplit", config.reasoningSplit)
                .put("disableThinking", config.disableThinking),
        )
        prefs(context).edit()
            .putString(KEY_LLM_PRESET, presetId)
            .putString(KEY_LLM_PROFILES, profiles.toString())
            .putString(KEY_LLM_BASE_URL, config.baseUrl.trim())
            .putString(KEY_LLM_MODEL, config.model.trim())
            .apply()
        SecureStore.put(context, keyFor(presetId), config.apiKey.trim())
        cachedLlm = config.copy(
            baseUrl = config.baseUrl.trim(),
            model = config.model.trim(),
            apiKey = config.apiKey.trim(),
            providerId = presetId,
        )
        llmLoaded = true
    }

    fun clearLlm(context: Context) {
        deleteLlmProfile(context, llmPresetId(context))
        prefs(context).edit()
            .remove(KEY_LLM_BASE_URL)
            .remove(KEY_LLM_MODEL)
            .apply()
        SecureStore.put(context, KEY_LLM_API_KEY, "")
        cachedLlm = null
        llmLoaded = false
    }

    /** Removes one saved text model and the key stored for it. */
    fun deleteLlmProfile(context: Context, presetId: String): Boolean {
        val profiles = profiles(context)
        val existed = profiles.has(presetId)
        profiles.remove(presetId)
        SecureStore.put(context, keyFor(presetId), "")
        val active = llmPresetId(context) == presetId
        if (!existed && !active) return false
        val editor = prefs(context).edit().putString(KEY_LLM_PROFILES, profiles.toString())
        if (active) {
            editor.remove(KEY_LLM_PRESET)
            cachedLlm = null
            llmLoaded = false
        }
        // The legacy fields mirror the active model, so they leave with it.
        if (active || profiles.length() == 0) {
            editor.remove(KEY_LLM_BASE_URL)
            editor.remove(KEY_LLM_MODEL)
        }
        editor.apply()
        return true
    }

    fun llmPresetId(context: Context): String =
        prefs(context).getString(KEY_LLM_PRESET, Presets.llm.first().id).orEmpty()

    fun setLlmPreset(context: Context, presetId: String) {
        prefs(context).edit().putString(KEY_LLM_PRESET, presetId).apply()
        cachedLlm = null
        llmLoaded = false
    }

    private fun profiles(context: Context): JSONObject =
        runCatching {
            JSONObject(prefs(context).getString(KEY_LLM_PROFILES, "{}").orEmpty())
        }.getOrDefault(JSONObject())

    private fun keyFor(presetId: String): String = "$KEY_LLM_API_KEY.$presetId"

    private fun extraKey(presetId: String, key: String): String =
        "asr.extra.$presetId.$key"

    fun mode(context: Context): ModeDefinition = ModeLibrary.current(context)

    fun setMode(context: Context, mode: ModeDefinition) {
        ModeLibrary.setCurrent(context, mode)
        prefs(context).edit().putString(KEY_MODE, mode.id).apply()
    }

    fun enabledModes(context: Context): List<ModeDefinition> =
        ModeLibrary.keyboard(context)

    fun clearAsr(context: Context) {
        deleteAsrProfile(context, asrPresetId(context))
        clearLegacyAsr(prefs(context).edit()).apply()
        SecureStore.put(context, KEY_ASR_API_KEY, "")
        SecureStore.put(context, KEY_ASR_ACCESS_KEY, "")
        cachedAsr = null
    }

    /** Removes one saved speech service and every key stored for it. */
    fun deleteAsrProfile(context: Context, presetId: String): Boolean {
        val profiles = asrProfiles(context)
        val existed = profiles.has(presetId)
        profiles.remove(presetId)
        SecureStore.put(context, "$KEY_ASR_API_KEY.$presetId", "")
        SecureStore.put(context, "$KEY_ASR_ACCESS_KEY.$presetId", "")
        SECRET_EXTRA_KEYS.forEach { key -> SecureStore.put(context, extraKey(presetId, key), "") }
        val active = asrPresetId(context) == presetId
        if (!existed && !active) return false
        val editor = prefs(context).edit().putString(KEY_ASR_PROFILES, profiles.toString())
        if (active) {
            editor.remove(KEY_ASR_PRESET)
            cachedAsr = null
        }
        // The legacy fields mirror the active service, so they leave with it.
        if (active || profiles.length() == 0) clearLegacyAsr(editor)
        editor.apply()
        return true
    }

    private fun clearLegacyAsr(
        editor: android.content.SharedPreferences.Editor,
    ): android.content.SharedPreferences.Editor =
        editor.remove(KEY_ASR_KIND)
            .remove(KEY_ASR_BASE_URL)
            .remove(KEY_ASR_MODEL)
            .remove(KEY_ASR_APP_KEY)
            .remove(KEY_ASR_RESOURCE_ID)
            .remove(KEY_ASR_SENSITIVITY)
            .remove(KEY_ASR_EXTRA)
            .remove(KEY_ASR_HAS_API_KEY)
            .remove(KEY_ASR_HAS_ACCESS_KEY)
            .remove(KEY_ASR_SAVED)

    /** Removes every saved service, every key, and puts the keyboard back to its shipped modes. */
    fun clearAll(context: Context) {
        // Cover profiles that are no longer listed but may still own old keys.
        Presets.asr.forEach { deleteAsrProfile(context, it.id) }
        Presets.llm.forEach { deleteLlmProfile(context, it.id) }
        asrProfiles(context).keys().asSequence().toList().forEach {
            deleteAsrProfile(context, it)
        }
        profiles(context).keys().asSequence().toList().forEach {
            deleteLlmProfile(context, it)
        }
        // The active entries may still hold values that predate profiles.
        deleteAsrProfile(context, asrPresetId(context))
        deleteLlmProfile(context, llmPresetId(context))
        SecureStore.put(context, KEY_ASR_API_KEY, "")
        SecureStore.put(context, KEY_ASR_ACCESS_KEY, "")
        SecureStore.put(context, KEY_LLM_API_KEY, "")
        cachedAsr = null
        cachedLlm = null
        llmLoaded = false
        ModeLibrary.reset(context)
        prefs(context).edit()
            .remove(KEY_ASR_PROFILES)
            .remove(KEY_ASR_PRESET)
            .remove(KEY_LLM_PROFILES)
            .remove(KEY_LLM_PRESET)
            .remove(KEY_MODE)
            .remove(KEY_ENABLED_MODES)
            .remove(KEY_TRANSLATE_TARGET)
            .apply()
    }
}
