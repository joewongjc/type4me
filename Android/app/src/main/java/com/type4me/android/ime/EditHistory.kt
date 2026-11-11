package com.type4me.android.ime

/**
 * One edit the keyboard can take back. Kept deliberately small: the text
 * field is the source of truth, and every action checks the text around the
 * cursor before it touches anything.
 */
sealed interface EditAction {
    /** Dictated or pasted text, plus the selection it typed over. */
    data class Insert(val text: String, val replaced: String) : EditAction

    /** The whole field, captured before a swipe-up clear. */
    data class Clear(
        val text: String,
        val cursor: Int,
        val beforeCount: Int,
        val afterCount: Int,
    ) : EditAction

    /** A correction: the selected word and what it became. */
    data class Correct(val old: String, val new: String) : EditAction
}

/**
 * Undo/redo state for the input-method process. The keyboard is recreated by
 * the system more often than the service, so this lives with the service.
 */
class EditHistory {
    private var undoAction: EditAction? = null
    private var redoAction: EditAction? = null

    val canUndo: Boolean get() = undoAction != null
    val canRedo: Boolean get() = redoAction != null

    fun record(action: EditAction) {
        undoAction = action
        redoAction = null
    }

    fun takeUndo(): EditAction? {
        val action = undoAction ?: return null
        undoAction = null
        redoAction = action
        return action
    }

    fun takeRedo(): EditAction? {
        val action = redoAction ?: return null
        redoAction = null
        undoAction = action
        return action
    }

    /** Any edit that is not undoable makes the old stack stale. */
    fun invalidate() {
        undoAction = null
        redoAction = null
    }
}
