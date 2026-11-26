package com.type4me.android.pipeline

import android.content.Context
import org.json.JSONArray

/**
 * The user's modes, in the order the keyboard shows them. Built-in modes are
 * seeded once; custom ones and prompt edits live here. The old fixed-mode
 * preferences are migrated on first read.
 */
object ModeLibrary {
    private const val PREFS = "type4me_modes"
    private const val KEY_MODES = "modes.v1"
    private const val KEY_CURRENT = "current.mode"

    private val builtIn = listOf(
        Mode.INTELLI_SENSE,
        Mode.QUICK,
        Mode.POLISH,
        Mode.TRANSLATE,
        Mode.AGENT,
    )

    fun defaults(): List<ModeDefinition> = listOf(
        ModeDefinition.builtIn(Mode.INTELLI_SENSE),
        ModeDefinition.builtIn(Mode.QUICK),
        ModeDefinition.builtIn(Mode.TRANSLATE),
        ModeDefinition.builtIn(Mode.AGENT),
        ModeDefinition.builtIn(Mode.POLISH, onKeyboard = false),
    )

    fun all(context: Context): List<ModeDefinition> {
        val stored = read(context)
        if (stored != null) return repair(stored)
        val migrated = migrate(context)
        save(context, migrated)
        return migrated
    }

    fun keyboard(context: Context): List<ModeDefinition> =
        all(context).filter { it.onKeyboard }.ifEmpty {
            listOf(ModeDefinition.builtIn(Mode.QUICK))
        }

    fun byId(context: Context, id: String): ModeDefinition? =
        all(context).firstOrNull { it.id == id }

    fun current(context: Context): ModeDefinition {
        val id = prefs(context).getString(KEY_CURRENT, null)
        val modes = all(context)
        return modes.firstOrNull { it.id == id }
            ?: modes.firstOrNull { it.id == Mode.QUICK.name }
            ?: modes.first()
    }

    fun setCurrent(context: Context, mode: ModeDefinition) {
        prefs(context).edit().putString(KEY_CURRENT, mode.id).apply()
    }

    fun save(context: Context, modes: List<ModeDefinition>) {
        val array = JSONArray()
        repair(modes).forEach { array.put(it.toJson()) }
        prefs(context).edit().putString(KEY_MODES, array.toString()).apply()
    }

    fun upsert(context: Context, mode: ModeDefinition) {
        val modes = all(context).toMutableList()
        val index = modes.indexOfFirst { it.id == mode.id }
        if (index >= 0) modes[index] = mode else modes.add(mode)
        save(context, modes)
    }

    fun delete(context: Context, id: String) {
        val modes = all(context).toMutableList()
        modes.removeAll { it.id == id && !it.isBuiltIn }
        if (modes.none { it.onKeyboard }) {
            val quick = modes.indexOfFirst { it.kind == Mode.QUICK }
            if (quick >= 0) modes[quick] = modes[quick].copy(onKeyboard = true)
        }
        save(context, modes)
    }

    fun move(context: Context, from: Int, to: Int) {
        val modes = all(context).toMutableList()
        if (from !in modes.indices || to !in modes.indices || from == to) return
        val item = modes.removeAt(from)
        modes.add(to, item)
        save(context, modes)
    }

    fun setOnKeyboard(context: Context, id: String, on: Boolean): Boolean {
        val modes = all(context).toMutableList()
        val index = modes.indexOfFirst { it.id == id }
        if (index < 0) return false
        if (!on && modes.count { it.onKeyboard } <= 1) return false
        modes[index] = modes[index].copy(onKeyboard = on)
        save(context, modes)
        return true
    }

    fun reset(context: Context) {
        save(context, defaults())
        prefs(context).edit().putString(KEY_CURRENT, Mode.QUICK.name).apply()
    }

    private fun repair(modes: List<ModeDefinition>): List<ModeDefinition> {
        val seen = mutableSetOf<String>()
        val result = modes.filter { seen.add(it.id) }.toMutableList()
        builtIn.forEach { kind ->
            if (result.none { it.kind == kind && it.isBuiltIn }) {
                result.add(ModeDefinition.builtIn(kind, onKeyboard = false))
            }
        }
        if (result.none { it.onKeyboard }) {
            val quick = result.indexOfFirst { it.kind == Mode.QUICK }
            if (quick >= 0) result[quick] = result[quick].copy(onKeyboard = true)
        }
        return result
    }

    private fun read(context: Context): List<ModeDefinition>? {
        val raw = prefs(context).getString(KEY_MODES, null) ?: return null
        return runCatching {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    array.optJSONObject(index)?.let { json ->
                        ModeDefinition.fromJson(json)?.let(::add)
                    }
                }
            }
        }.getOrNull()?.takeIf { it.isNotEmpty() }
    }

    /** The fixed five-mode app stored its choices in ConfigStore's prefs. */
    private fun migrate(context: Context): List<ModeDefinition> {
        val old = context.getSharedPreferences("type4me", Context.MODE_PRIVATE)
        val enabled = old.getStringSet("dictation.enabledModes", null)
            ?.mapNotNull { name -> runCatching { Mode.valueOf(name) }.getOrNull() }
            ?.toSet()
        val oldCurrent = old.getString("dictation.mode", null)
        val modes = defaults().map { mode ->
            val onKeyboard = enabled?.contains(mode.kind) ?: mode.onKeyboard
            mode.copy(onKeyboard = onKeyboard)
        }.toMutableList()
        val current = oldCurrent?.takeIf { id -> modes.any { it.id == id } } ?: Mode.QUICK.name
        prefs(context).edit().putString(KEY_CURRENT, current).apply()
        return repair(modes)
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
