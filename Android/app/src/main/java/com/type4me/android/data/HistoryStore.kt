package com.type4me.android.data

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

data class HistoryEntry(
    val id: Long,
    val createdAt: Long,
    val mode: String,
    val rawText: String,
    val finalText: String,
    val delivered: Boolean,
    val note: String? = null,
)

/** The last 200 dictations, kept on this phone only. */
object HistoryStore {
    private const val PREFS = "type4me_history"
    private const val KEY = "history.v1"
    private const val LIMIT = 200

    fun all(context: Context): List<HistoryEntry> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    add(
                        HistoryEntry(
                            id = item.optLong("id"),
                            createdAt = item.optLong("createdAt"),
                            mode = item.optString("mode"),
                            rawText = item.optString("rawText"),
                            finalText = item.optString("finalText"),
                            delivered = item.optBoolean("delivered", true),
                            note = item.optString("note").takeIf { it.isNotBlank() },
                        ),
                    )
                }
            }
        }.getOrDefault(emptyList())
    }

    fun add(context: Context, entry: HistoryEntry) {
        val entries = (listOf(entry) + all(context)).take(LIMIT)
        write(context, entries)
    }

    /**
     * Records a dictation with the next id, reading and rewriting the list once.
     * Returns the assigned id.
     */
    fun add(
        context: Context,
        createdAt: Long,
        mode: String,
        rawText: String,
        finalText: String,
        delivered: Boolean,
        note: String? = null,
    ): Long {
        val current = all(context)
        val entry = HistoryEntry(
            id = (current.maxOfOrNull { it.id } ?: 0L) + 1L,
            createdAt = createdAt,
            mode = mode,
            rawText = rawText,
            finalText = finalText,
            delivered = delivered,
            note = note,
        )
        write(context, (listOf(entry) + current).take(LIMIT))
        return entry.id
    }

    fun delete(context: Context, id: Long) {
        write(context, all(context).filterNot { it.id == id })
    }

    fun clear(context: Context) {
        write(context, emptyList())
    }

    private fun write(context: Context, entries: List<HistoryEntry>) {
        val array = JSONArray()
        entries.forEach { entry ->
            array.put(
                JSONObject()
                    .put("id", entry.id)
                    .put("createdAt", entry.createdAt)
                    .put("mode", entry.mode)
                    .put("rawText", entry.rawText)
                    .put("finalText", entry.finalText)
                    .put("delivered", entry.delivered)
                    .put("note", entry.note ?: ""),
            )
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY, array.toString())
            .apply()
    }
}
