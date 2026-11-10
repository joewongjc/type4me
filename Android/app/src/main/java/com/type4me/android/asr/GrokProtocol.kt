package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONObject

/**
 * xAI streaming STT. Results arrive as interim partials, ~3s chunk finals and
 * `speech_final` utterances; the state machine below stitches them so a pause
 * revision replaces the earlier utterance instead of duplicating it.
 */
internal object GrokProtocol {
    const val ENDPOINT = "wss://api.x.ai/v1/stt"
    const val DEFAULT_MODEL = "grok-voice-transcribe-2.0"
    const val SAMPLE_RATE = 16_000

    data class State(
        val utterances: List<String> = emptyList(),
        val chunks: List<String> = emptyList(),
    ) {
        val confirmedSegments: List<String>
            get() {
                if (chunks.isEmpty()) return utterances
                if (utterances.isEmpty()) return chunks
                val stitched = chunks.toMutableList()
                stitched[0] = AsrTextTools.normalizeSegment(stitched[0], utterances.joinToString(""))
                return utterances + stitched
            }

        val joinedConfirmed: String
            get() = confirmedSegments
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .fold("") { joined, segment ->
                    joined + AsrTextTools.normalizeSegment(segment, joined)
                }
    }

    data class Update(
        val state: State,
        val partial: String,
        val isFinal: Boolean,
        val serverReady: Boolean = false,
    )

    fun buildWebSocketUrl(config: AsrConfig, hotwords: List<String>): String =
        websocketUrl(config.baseUrl, ENDPOINT, "Invalid Grok WebSocket URL") { builder ->
            builder.addQueryParameter("model", config.resolvedModel(DEFAULT_MODEL))
                .addQueryParameter("sample_rate", SAMPLE_RATE.toString())
                .addQueryParameter("encoding", "pcm")
                .addQueryParameter("interim_results", "true")
                .addQueryParameter("filler_words", "false")
                // Push-to-talk: raise the smart-turn threshold so brief pauses do
                // not end the utterance early.
                .addQueryParameter("smart_turn", "0.7")
                .addQueryParameter("smart_turn_timeout", "3000")
            val language = config.extraValue("language")
            if (language.isNotEmpty()) builder.addQueryParameter("language", language)
            keyterms(hotwords).forEach { builder.addQueryParameter("keyterm", it) }
        }

    /** At most 100 keyterms, each no longer than 50 characters. */
    fun keyterms(hotwords: List<String>): List<String> = hotwords
        .map { it.trim() }
        .filter { it.isNotEmpty() && it.length <= 50 }
        .take(100)

    fun finalizeMessage(): String = JSONObject().put("type", "finalize").toString()

    fun audioDoneMessage(): String = JSONObject().put("type", "audio.done").toString()

    fun parse(message: String, state: State, isFinalCommit: Boolean): Update? {
        if (message.trimStart().firstOrNull() != '{') return null
        val json = runCatching { JSONObject(message) }.getOrElse {
            throw AsrException("Could not parse the Grok response")
        }
        val text = if (json.isNull("text")) "" else json.optString("text").trim()

        return when (val type = json.optString("type")) {
            "transcript.created" -> Update(state, "", isFinal = false, serverReady = true)

            "transcript.partial" -> {
                val isFinal = json.optBoolean("is_final", false)
                val speechFinal = json.optBoolean("speech_final", false)
                when {
                    !isFinal -> if (text.isEmpty()) null else interimUpdate(text, state)
                    speechFinal -> transcriptUpdate(applySpeechFinal(text, state), isFinalCommit)
                    else -> transcriptUpdate(applyChunkFinal(text, state), isFinalCommit = false)
                }
            }

            "transcript.done" -> transcriptUpdate(
                applyTranscriptDone(if (text.isEmpty()) null else text, state),
                isFinalCommit,
            )

            "error" -> {
                val detail = json.optString("message")
                throw AsrException(if (detail.isBlank()) "Grok STT error" else "Grok STT error: $detail")
            }

            else -> null
        }
    }

    // MARK: - Event handlers

    private fun interimUpdate(text: String, state: State): Update? {
        val confirmed = state.joinedConfirmed
        val partialOnly = AsrTextTools.stripConfirmedPrefix(text, confirmed)
        if (partialOnly.isEmpty()) return null
        return Update(state, AsrTextTools.normalizeSegment(partialOnly, confirmed), isFinal = false)
    }

    /** Chunk final: an incremental ~3s segment; append unless it duplicates the tail. */
    private fun applyChunkFinal(text: String, state: State): State {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return state
        val chunks = state.chunks.toMutableList()
        val joined = chunks.joinToString("")
        when {
            joined.isEmpty() -> chunks += trimmed
            joined == trimmed || joined.endsWith(trimmed) -> Unit
            else -> chunks += AsrTextTools.normalizeSegment(
                trimmed,
                state.utterances.joinToString("") + joined,
            )
        }
        return state.copy(chunks = chunks)
    }

    /** Utterance final: the server sends the complete stitched utterance for the pause. */
    private fun applySpeechFinal(text: String, state: State): State {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return state.copy(chunks = emptyList())
        val utterance = stitchChunks(trimmed, state.chunks)
        return state.copy(utterances = commitUtterance(utterance, state.utterances), chunks = emptyList())
    }

    /** Session final after audio.done — prefer the server's full transcript. */
    private fun applyTranscriptDone(text: String?, state: State): State {
        val trimmed = text?.trim().orEmpty()
        if (trimmed.isEmpty()) return state
        val joined = state.joinedConfirmed.trim()
        if (joined.isEmpty()) return State(utterances = listOf(trimmed))
        return State(utterances = listOf(preferAuthoritativeText(trimmed, joined)))
    }

    private fun transcriptUpdate(state: State, isFinalCommit: Boolean): Update? {
        if (state.joinedConfirmed.isEmpty()) return null
        return Update(state, "", isFinal = isFinalCommit)
    }

    // MARK: - Stitching

    private fun stitchChunks(final: String, chunks: List<String>): String {
        val trimmed = final.trim()
        val chunkText = chunks.joinToString("").trim()
        if (chunkText.isEmpty()) return trimmed
        if (trimmed.startsWith(chunkText) || chunkText.startsWith(trimmed)) {
            return preferLonger(trimmed, chunkText)
        }
        // Tail-only speech_final: keep chunk finals the server omitted.
        if (wordOverlapRatio(normalizedWords(trimmed), normalizedWords(chunkText)) < 0.2) {
            return chunkText + AsrTextTools.normalizeSegment(trimmed, chunkText)
        }
        return trimmed
    }

    private fun commitUtterance(text: String, utterances: List<String>): List<String> {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return utterances
        val last = utterances.lastOrNull()
        if (last != null && revisesSamePause(trimmed, last)) {
            return utterances.dropLast(1) + trimmed
        }
        if (utterances.isEmpty()) return listOf(trimmed)
        return utterances + AsrTextTools.normalizeSegment(trimmed, utterances.joinToString(""))
    }

    /** Same pause revision: extension, shared long opening, or near-duplicate wording. */
    private fun revisesSamePause(candidate: String, previous: String): Boolean {
        val candidateWords = normalizedWords(candidate)
        val previousWords = normalizedWords(previous)
        if (candidateWords.isEmpty() || previousWords.isEmpty()) return false

        val candidateText = candidateWords.joinToString(" ")
        val previousText = previousWords.joinToString(" ")
        if (candidateText.startsWith(previousText) || previousText.startsWith(candidateText)) return true

        val opening = minOf(3, candidateWords.size, previousWords.size)
        if (opening >= 3) {
            val sameOpening = candidateWords.take(opening).zip(previousWords.take(opening))
                .all { (a, b) -> a == b }
            if (sameOpening) {
                if (minOf(candidateWords.size, previousWords.size) >= 10) return true
                if (wordOverlapRatio(candidateWords, previousWords) >= 0.72) return true
            }
        }
        return wordOverlapRatio(candidateWords, previousWords) >= 0.72
    }

    private fun wordOverlapRatio(a: List<String>, b: List<String>): Double {
        val union = (a.toSet() + b.toSet())
        if (union.isEmpty()) return 0.0
        return a.toSet().intersect(b.toSet()).size.toDouble() / union.size
    }

    private fun preferAuthoritativeText(server: String, accumulated: String): String {
        if (server == accumulated) return server
        if (revisesSamePause(server, accumulated) || revisesSamePause(accumulated, server)) {
            return preferLonger(server, accumulated)
        }
        if (server.contains(accumulated)) return server
        if (accumulated.contains(server)) return accumulated
        return preferLonger(server, accumulated)
    }

    private fun preferLonger(a: String, b: String): String =
        if (normalizedWords(a).size >= normalizedWords(b).size) a else b

    private fun normalizedWords(text: String): List<String> = text.lowercase()
        .replace("-", " ")
        .replace("n't", " not")
        .split(Regex("[^\\p{L}\\p{N}]+"))
        .filter { it.isNotEmpty() }
}
