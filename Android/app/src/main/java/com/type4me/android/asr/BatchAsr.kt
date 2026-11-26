package com.type4me.android.asr

import com.type4me.android.audio.WavEncoder
import com.type4me.android.data.AsrConfig
import com.type4me.android.data.AsrKind

/** Whole-recording recognition for every batch provider. */
object BatchAsr {
    suspend fun transcribe(
        config: AsrConfig,
        pcm: ByteArray,
        hotwords: List<String> = emptyList(),
    ): String {
        if (config.kind == AsrKind.OPENAI) {
            return OpenAITranscriptionClient().transcribe(
                config = config,
                wav = WavEncoder.encode(pcm),
                hotwords = hotwords,
            )
        }
        val portable = PortableBatchB.transcribe(config.providerId, config, pcm, hotwords)
            ?: PortableBatchC.transcribe(config.providerId, config, pcm, hotwords)
            ?: throw AsrException("This speech service does not support batch recognition")
        return portable.trim()
    }

    suspend fun test(config: AsrConfig): Long {
        val started = System.currentTimeMillis()
        transcribe(config, ByteArray(32_000))
        return System.currentTimeMillis() - started
    }
}
