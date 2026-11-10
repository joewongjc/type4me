package com.type4me.android.data

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

data class Snippet(val trigger: String, val replacement: String)

/**
 * Hotwords bias recognition; snippets rewrite the transcript before any mode
 * processes it, the same order the Mac uses.
 */
object VocabularyStore {
    private const val PREFS = "type4me_vocabulary"
    private const val KEY = "vocabulary.v1"

    fun hotwords(context: Context): List<String> = read(context).hotwords
    fun snippets(context: Context): List<Snippet> = read(context).snippets

    fun save(context: Context, hotwords: List<String>, snippets: List<Snippet>) {
        val objectJson = JSONObject()
        objectJson.put("hotwords", JSONArray(hotwords.filter { it.isNotBlank() }.map { it.trim() }))
        objectJson.put(
            "snippets",
            JSONArray().apply {
                snippets.filter { it.trigger.isNotBlank() }.forEach {
                    put(JSONObject().put("trigger", it.trigger.trim()).put("replacement", it.replacement))
                }
            },
        )
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY, objectJson.toString())
            .apply()
    }

    /** A comma-separated prompt hint for batch services that support one. */
    fun hotwordPrompt(context: Context): String? =
        hotwords(context).take(50).takeIf { it.isNotEmpty() }?.joinToString(", ")

    private fun read(context: Context): Saved {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, null) ?: return Saved(emptyList(), emptyList())
        return runCatching {
            val json = JSONObject(raw)
            val hotwords = json.optJSONArray("hotwords").toStringList()
            val snippets = buildList {
                val array = json.optJSONArray("snippets") ?: JSONArray()
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    val trigger = item.optString("trigger").trim()
                    if (trigger.isEmpty()) continue
                    add(Snippet(trigger, item.optString("replacement")))
                }
            }
            Saved(hotwords, snippets)
        }.getOrDefault(Saved(emptyList(), emptyList()))
    }

    private fun JSONArray?.toStringList(): List<String> {
        if (this == null) return emptyList()
        return buildList {
            for (index in 0 until length()) {
                val value = optString(index).trim()
                if (value.isNotEmpty()) add(value)
            }
        }
    }

    private data class Saved(val hotwords: List<String>, val snippets: List<Snippet>)
}
