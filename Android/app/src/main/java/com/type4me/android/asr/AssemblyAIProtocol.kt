package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONArray
import org.json.JSONObject

/**
 * AssemblyAI v3 streaming protocol. Keyterms are sent with an
 * `UpdateConfiguration` message after the server's `Begin` to avoid URL length
 * limits, and turns are accumulated in [AssemblyAITranscriptAccumulator].
 */
object AssemblyAIProtocol {
    const val DEFAULT_ENDPOINT = "wss://streaming.assemblyai.com/v3/ws"
    const val DEFAULT_MODEL = "universal-3-6-pro"

    private const val MAX_KEYTERMS = 100
    private const val MAX_KEYTERM_LENGTH = 50

    sealed interface Event {
        data object Begin : Event
        data class Turn(val update: TurnUpdate) : Event
        data object Termination : Event
        data object SpeechStarted : Event
    }

    data class TurnUpdate(
        val turnOrder: Int,
        val finalizedText: String,
        val displayText: String,
        val authoritativeText: String,
        val isFinal: Boolean,
        val isFormatted: Boolean,
    )

    fun buildUrl(config: AsrConfig, enablePunc: Boolean = true): String {
        val model = config.resolvedModel(DEFAULT_MODEL)
        return websocketUrl(config.baseUrl, DEFAULT_ENDPOINT, "Invalid AssemblyAI WebSocket URL") { builder ->
            builder.addQueryParameter("sample_rate", "16000")
            builder.addQueryParameter("encoding", "pcm_s16le")
            builder.addQueryParameter("speech_model", model)
            if (usesFormatTurns(model)) {
                builder.addQueryParameter("format_turns", if (enablePunc) "true" else "false")
            }
        }
    }

    fun terminateMessage(): String = """{"type":"Terminate"}"""

    fun updateConfigurationMessage(hotwords: List<String>): String? {
        val keyterms = sanitizedKeyterms(hotwords)
        if (keyterms.isEmpty()) return null
        return JSONObject()
            .put("type", "UpdateConfiguration")
            .put("keyterms_prompt", JSONArray(keyterms))
            .toString()
    }

    /** Returns null for message types this client does not consume. */
    fun parse(text: String): Event? {
        val json = runCatching { JSONObject(text) }.getOrElse {
            throw AsrException("AssemblyAI returned an unreadable streaming message")
        }
        return when (json.optString("type")) {
            "Begin" -> Event.Begin
            "Turn" -> turnUpdate(json)?.let { Event.Turn(it) }
            "Termination" -> Event.Termination
            "SpeechStarted" -> Event.SpeechStarted
            else -> null
        }
    }

    fun closeErrorMessage(code: Int, reason: String?): String {
        val clean = reason?.trim().orEmpty()
        val suffix = if (clean.isEmpty()) "" else ": $clean"
        return when (code) {
            1008 -> "AssemblyAI unauthorized connection$suffix"
            3005 -> "AssemblyAI session cancelled$suffix"
            else -> "AssemblyAI session closed ($code)$suffix"
        }
    }

    private fun usesFormatTurns(model: String): Boolean =
        model.startsWith("universal-streaming-")

    private fun sanitizedKeyterms(hotwords: List<String>): List<String> = hotwords
        .map { it.trim() }
        .filter { it.isNotEmpty() }
        .map { it.take(MAX_KEYTERM_LENGTH) }
        .take(MAX_KEYTERMS)

    private fun turnUpdate(json: JSONObject): TurnUpdate? {
        val endOfTurn = json.optBoolean("end_of_turn", false)
        val transcript = json.optString("transcript").trim()
        val words = json.optJSONArray("words")
        val displayText = transcriptText(endOfTurn, transcript, words)
        val finalizedText = if (endOfTurn) displayText else finalizedPrefix(words)
        if (displayText.isEmpty() && finalizedText.isEmpty() && !endOfTurn) return null

        return TurnUpdate(
            turnOrder = json.optInt("turn_order", 0),
            finalizedText = finalizedText,
            displayText = displayText,
            authoritativeText = if (endOfTurn) displayText else finalizedText,
            isFinal = endOfTurn,
            isFormatted = json.optBoolean("turn_is_formatted", false),
        )
    }

    private fun transcriptText(endOfTurn: Boolean, transcript: String, words: JSONArray?): String {
        if (endOfTurn) return transcript.ifEmpty { joinWords(words) }

        val joined = joinWords(words)
        if (joined.isEmpty()) return transcript
        if (transcript.isEmpty()) return joined
        return if (joined.length >= transcript.length) joined else transcript
    }

    private fun finalizedPrefix(words: JSONArray?): String {
        if (words == null) return ""
        val prefix = JSONArray()
        for (index in 0 until words.length()) {
            val word = words.optJSONObject(index) ?: break
            if (!word.optBoolean("word_is_final", false)) break
            prefix.put(word)
        }
        return joinWords(prefix)
    }

    private fun joinWords(words: JSONArray?): String {
        if (words == null) return ""
        var text = ""
        for (index in 0 until words.length()) {
            val token = words.optJSONObject(index)?.optString("text").orEmpty().trim()
            if (token.isEmpty()) continue
            text += AsrTextTools.normalizeSegment(token, text)
        }
        return text
    }
}

internal data class AssemblyAITranscript(
    val confirmedSegments: List<String>,
    val partial: String,
    val authoritativeText: String,
    val final: Boolean,
)

/**
 * Tracks per-turn revisions. A completed turn is frozen against late partial
 * revisions, and an unformatted revision never replaces formatted text.
 */
internal class AssemblyAITranscriptAccumulator {
    private data class TurnState(
        val order: Int,
        val finalizedText: String,
        val displayText: String,
        val completed: Boolean,
        val formatted: Boolean,
    )

    private val turns = mutableMapOf<Int, TurnState>()

    fun apply(update: AssemblyAIProtocol.TurnUpdate) {
        val existing = turns[update.turnOrder]
        if (existing != null && existing.completed && !update.isFinal) return

        if (update.isFinal) {
            if (existing != null && existing.formatted && !update.isFormatted) return
            turns[update.turnOrder] = TurnState(
                order = update.turnOrder,
                finalizedText = update.displayText,
                displayText = update.displayText,
                completed = true,
                formatted = update.isFormatted,
            )
        } else {
            turns[update.turnOrder] = TurnState(
                order = update.turnOrder,
                finalizedText = update.finalizedText,
                displayText = update.displayText,
                completed = false,
                formatted = update.isFormatted,
            )
        }
    }

    fun transcript(): AssemblyAITranscript {
        var confirmed = mutableListOf<String>()
        var existingText = ""
        var activeTurn: TurnState? = null

        for (turn in turns.values.sortedBy { it.order }) {
            if (turn.completed) {
                val normalized = AsrTextTools.normalizeSegment(turn.displayText, existingText)
                confirmed += normalized
                existingText += normalized
            } else {
                activeTurn = turn
            }
        }

        var partial = ""
        val active = activeTurn
        if (active != null) {
            if (active.finalizedText.isNotEmpty()) {
                val normalized = AsrTextTools.normalizeSegment(active.finalizedText, existingText)
                confirmed += normalized
                existingText += normalized
            }

            val rawPartial = when {
                active.finalizedText.isNotEmpty() && active.displayText.startsWith(active.finalizedText) ->
                    active.displayText.substring(active.finalizedText.length)

                active.displayText == active.finalizedText -> ""
                else -> active.displayText
            }
            partial = AsrTextTools.normalizeSegment(rawPartial, existingText)
        }

        return AssemblyAITranscript(
            confirmedSegments = confirmed,
            partial = partial,
            authoritativeText = confirmed.joinToString("") + partial,
            final = active == null,
        )
    }
}
