package com.type4me.android.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The UI-level paths need an InputConnection, so only the pure math is testable here. */
class ClearEditTest {
    @Test
    fun emptyFieldHasNothingToUndo() {
        assertNull(ClearEdit.action(before = "", after = "", restore = ""))
    }

    @Test
    fun originalFieldIsCapturedOnceWithoutTheRestoreDuplicated() {
        val action = ClearEdit.action(before = "ab", after = "cd", restore = "")
        assertEquals("abcd", action?.text)
        assertEquals(2, action?.cursor)
        assertEquals(2, action?.beforeCount)
        assertEquals(2, action?.afterCount)
    }

    @Test
    fun restoredDeletionIsPutBackAtTheOriginalCursor() {
        // "b" was deleted from "abcd"; the queued character belongs after "a".
        val action = ClearEdit.action(before = "a", after = "cd", restore = "b")
        assertEquals("abcd", action?.text)
        assertEquals(2, action?.cursor)
        assertEquals(2, action?.beforeCount)
        assertEquals(2, action?.afterCount)
    }

    @Test
    fun restoredDeletionIsCountedExactlyOnceOnUndoAndRedo() {
        val action = ClearEdit.action(before = "a", after = "d", restore = "bc")
        assertEquals("abcd", action?.text)
        assertEquals(3, action?.cursor)
        assertEquals(3, action?.beforeCount)
        assertEquals(1, action?.afterCount)
    }

    @Test
    fun undoRestoresTheOriginalCursorWithSupplementalCodePoints() {
        val emoji = "\uD83D\uDE00"
        val action = ClearEdit.action(
            before = "hi$emoji",
            after = " there",
            restore = "",
        )
        assertEquals("hi$emoji there", action?.text)
        assertEquals("hi$emoji".length, action?.cursor)
        assertEquals(3, action?.beforeCount)
        assertEquals(6, action?.afterCount)
        assertEquals(6, action?.let { ClearEdit.stepsBack(it.text, it.cursor) })
    }

    @Test
    fun outOfRangeCursorIsClampedToTheFieldEdges() {
        assertEquals(0, ClearEdit.stepsBack("abc", 3))
        assertEquals(3, ClearEdit.stepsBack("abc", 0))
        assertEquals(0, ClearEdit.stepsBack("abc", 99))
        assertEquals(3, ClearEdit.stepsBack("abc", -1))
    }

    @Test
    fun emptyFieldIsTheOnlyCaseWithNoAction() {
        assertNull(ClearEdit.action(before = "", after = "", restore = ""))
        assertEquals("x", ClearEdit.action(before = "", after = "", restore = "x")?.text)
        assertEquals(0, ClearEdit.stepsBack("", 0))
    }
}
