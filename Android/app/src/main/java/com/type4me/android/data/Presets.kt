package com.type4me.android.data

enum class AsrKind {
    OPENAI,
    VOLCANO,
    SONIOX,
    /** Another live WebSocket provider, chosen by providerId. */
    STREAMING,
    /** Another whole-recording upload provider, chosen by providerId. */
    BATCH,
}

/**
 * Starting points for the speech service form. OpenAI-compatible endpoints
 * accept a WAV upload; Volcano and Soniox open a live WebSocket instead.
 */
data class AsrPreset(
    val id: String,
    val displayName: String,
    val kind: AsrKind,
    val baseUrl: String = "",
    val model: String = "",
    val resourceId: String = "",
    val sensitivity: Double = -0.3,
    val extra: Map<String, String> = emptyMap(),
    val batchKind: AsrKind? = null,
    val batchModel: String = "",
    /** HTTP endpoint used when the same service runs in batch mode. */
    val batchBaseUrl: String = "",
) {
    val supportsBatch: Boolean get() = batchKind != null
}

data class LlmPreset(
    val id: String,
    val displayName: String,
    val baseUrl: String,
    val model: String,
    val models: List<String> = emptyList(),
    val thinkingOff: String? = null,
    val reasoningSplit: Boolean = false,
)

object Presets {
    const val VOLC_RESOURCE_SEED = "volc.seedasr.sauc.duration"
    const val VOLC_RESOURCE_BIG = "volc.bigasr.sauc.duration"

    val asr: List<AsrPreset> = listOf(
        AsrPreset(
            id = "volcano",
            displayName = "Volcengine",
            kind = AsrKind.VOLCANO,
            resourceId = VOLC_RESOURCE_SEED,
        ),
        AsrPreset(
            id = "soniox",
            displayName = "Soniox",
            kind = AsrKind.SONIOX,
            model = "stt-rt-v5",
        ),
        AsrPreset(
            id = "openai",
            displayName = "OpenAI",
            kind = AsrKind.OPENAI,
            baseUrl = "https://api.openai.com/v1",
            model = "gpt-4o-mini-transcribe",
        ),
        AsrPreset(
            id = "groq",
            displayName = "Groq",
            kind = AsrKind.OPENAI,
            baseUrl = "https://api.groq.com/openai/v1",
            model = "whisper-large-v3-turbo",
        ),
        AsrPreset(
            id = "mistral",
            displayName = "Mistral AI",
            kind = AsrKind.OPENAI,
            baseUrl = "https://api.mistral.ai/v1",
            model = "voxtral-mini-latest",
        ),
        AsrPreset(
            id = "stepfun",
            displayName = "StepFun",
            kind = AsrKind.STREAMING,
            baseUrl = "wss://api.stepfun.com/v1/realtime/asr/stream",
            model = "stepaudio-2.5-asr-stream",
            extra = mapOf("region" to "china"),
        ),
        AsrPreset(
            id = "deepgram",
            displayName = "Deepgram",
            kind = AsrKind.STREAMING,
            baseUrl = "wss://api.deepgram.com/v1/listen",
            model = "nova-3",
            extra = mapOf("language" to "zh"),
        ),
        AsrPreset(
            id = "cartesia",
            displayName = "Cartesia",
            kind = AsrKind.STREAMING,
            baseUrl = "wss://api.cartesia.ai/stt/websocket",
            model = "ink-2",
        ),
        AsrPreset(
            id = "assemblyai",
            displayName = "AssemblyAI",
            kind = AsrKind.STREAMING,
            baseUrl = "wss://streaming.assemblyai.com/v3/ws",
            model = "universal-3-6-pro",
        ),
        AsrPreset(
            id = "elevenlabs",
            displayName = "ElevenLabs",
            kind = AsrKind.STREAMING,
            baseUrl = "wss://api.elevenlabs.io/v1/speech-to-text/realtime",
            model = "scribe_v2_realtime",
            batchKind = AsrKind.BATCH,
            batchModel = "scribe_v2",
            batchBaseUrl = "https://api.elevenlabs.io/v1/speech-to-text",
        ),
        AsrPreset(
            id = "gemini",
            displayName = "Gemini",
            kind = AsrKind.STREAMING,
            baseUrl = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
            model = "gemini-3.5-transcribe-live",
            extra = mapOf("language" to "auto"),
            batchKind = AsrKind.BATCH,
            batchModel = "gemini-2.5-flash",
            batchBaseUrl = "https://generativelanguage.googleapis.com/v1beta/",
        ),
        AsrPreset(
            id = "grok",
            displayName = "Grok",
            kind = AsrKind.STREAMING,
            baseUrl = "wss://api.x.ai/v1/stt",
            model = "grok-voice-transcribe-2.0",
            batchKind = AsrKind.BATCH,
            batchModel = "grok-voice-transcribe-2.0",
            batchBaseUrl = "https://api.x.ai/v1/stt",
        ),
        AsrPreset(
            id = "metaMuse",
            displayName = "Meta Muse",
            kind = AsrKind.STREAMING,
            baseUrl = "wss://api.meta.ai/v1/asr/realtime",
            model = "muse-voice-transcribe-1.0",
        ),
        AsrPreset(
            id = "bailian",
            displayName = "Bailian",
            kind = AsrKind.STREAMING,
            baseUrl = "wss://dashscope.aliyuncs.com/api-ws/v1/inference",
            model = "qwen-audio-3.1-asr-flash-streaming",
            extra = mapOf("region" to "china"),
            batchKind = AsrKind.BATCH,
            batchModel = "qwen-audio-3.1-asr-flash",
        ),
        AsrPreset(
            id = "azure",
            displayName = "Microsoft Azure",
            kind = AsrKind.STREAMING,
            model = "MAI-Transcribe-2-Streaming",
            extra = mapOf("deployment" to "MAI-Transcribe-2-Streaming"),
            batchKind = AsrKind.BATCH,
            batchModel = "MAI-Transcribe-2",
        ),
        AsrPreset(
            id = "tencent",
            displayName = "Tencent Cloud",
            kind = AsrKind.STREAMING,
            model = "16k_zh_en_2.0",
            batchKind = AsrKind.BATCH,
            batchModel = "16k_zh_en_2.0",
        ),
        AsrPreset(
            id = "mimo",
            displayName = "Xiaomi MiMo",
            kind = AsrKind.BATCH,
            baseUrl = "https://api.xiaomimimo.com/v1/chat/completions",
            model = "mimo-v2.5-asr",
        ),
        AsrPreset(
            id = "customhttp",
            displayName = "Custom HTTP",
            kind = AsrKind.BATCH,
        ),
        AsrPreset(
            id = "siliconflow",
            displayName = "SiliconFlow",
            kind = AsrKind.OPENAI,
            baseUrl = "https://api.siliconflow.cn/v1",
            model = "FunAudioLLM/SenseVoiceSmall",
        ),
        AsrPreset(id = "custom", displayName = "Custom", kind = AsrKind.OPENAI),
    )

    val llm: List<LlmPreset> = listOf(
        LlmPreset(
            "volcengine",
            "Volcengine Ark",
            "https://ark.cn-beijing.volces.com/api/v3",
            "",
            thinkingOff = "thinking",
        ),
        LlmPreset(
            "deepseek",
            "DeepSeek",
            "https://api.deepseek.com/v1",
            "deepseek-chat",
            listOf("deepseek-chat", "deepseek-reasoner"),
            thinkingOff = "thinking",
        ),
        LlmPreset(
            "bailian",
            "Bailian",
            "https://dashscope.aliyuncs.com/compatible-mode/v1",
            "qwen-plus",
            listOf("qwen-plus", "qwen-max", "qwen-turbo"),
            thinkingOff = "enableThinking",
        ),
        LlmPreset(
            "moonshot",
            "Moonshot",
            "https://api.moonshot.cn/v1",
            "moonshot-v1-8k",
            listOf("moonshot-v1-8k", "moonshot-v1-32k", "kimi-k2.5"),
            thinkingOff = "thinking",
        ),
        LlmPreset(
            "zhipu",
            "Zhipu (GLM)",
            "https://open.bigmodel.cn/api/paas/v4",
            "glm-4-plus",
            listOf("glm-4-plus", "glm-4-flash"),
            thinkingOff = "thinking",
        ),
        LlmPreset(
            "mimo",
            "Xiaomi MiMo",
            "https://api.xiaomimimo.com/v1",
            "mimo-v2-flash",
            listOf("mimo-v2-flash"),
            thinkingOff = "thinking",
        ),
        LlmPreset(
            "minimaxCN",
            "MiniMax China",
            "https://api.minimaxi.com/v1",
            "MiniMax-M2.7",
            listOf("MiniMax-M2.7", "MiniMax-Text-01"),
            reasoningSplit = true,
        ),
        LlmPreset(
            "minimaxIntl",
            "MiniMax Global",
            "https://api.minimax.io/v1",
            "MiniMax-M2.7",
            listOf("MiniMax-M2.7", "MiniMax-Text-01"),
            reasoningSplit = true,
        ),
        LlmPreset(
            "openrouter",
            "OpenRouter",
            "https://openrouter.ai/api/v1",
            "openai/gpt-4o-mini",
            listOf("openai/gpt-4o-mini", "anthropic/claude-sonnet-4", "google/gemini-2.5-flash"),
            thinkingOff = "reasoning",
        ),
        LlmPreset(
            "openai",
            "OpenAI",
            "https://api.openai.com/v1",
            "gpt-4o-mini",
            listOf("gpt-4o-mini", "gpt-4.1-mini", "gpt-5-mini"),
            thinkingOff = "reasoningEffort",
        ),
        LlmPreset(
            "gemini",
            "Gemini (Google)",
            "https://generativelanguage.googleapis.com/v1beta/openai",
            "gemini-2.5-flash",
            listOf("gemini-2.5-flash", "gemini-2.5-pro"),
        ),
        LlmPreset(
            "claude",
            "Claude (Anthropic)",
            "https://api.anthropic.com/v1",
            "claude-sonnet-4-5",
            listOf("claude-sonnet-4-5", "claude-haiku-4-5", "claude-opus-4-1"),
            thinkingOff = "thinking",
        ),
        LlmPreset("custom", "Custom", "", ""),
    )

    fun asrById(id: String): AsrPreset = asr.firstOrNull { it.id == id } ?: asr.last()
    fun llmById(id: String): LlmPreset = llm.firstOrNull { it.id == id } ?: llm.last()
}
