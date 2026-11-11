package com.type4me.android.pipeline

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CorrectionTest {
    @Test
    fun readsTheJsonReply() {
        assertEquals(
            "张伟",
            Correction.resolve("""{"replacement": "张伟"}""", selected = "张为")?.replacement,
        )
    }

    @Test
    fun ignoresAReplyThatRepeatsTheSelection() {
        assertNull(Correction.resolve("""{"replacement": "张为"}""", selected = "张为"))
    }

    @Test
    fun ignoresAnAlreadyRejectedSpelling() {
        assertNull(
            Correction.resolve(
                """{"replacement": "张伟"}""",
                selected = "张为",
                attempts = listOf("张伟"),
            ),
        )
    }

    @Test
    fun findsOtherOccurrencesAroundTheSelection() {
        val occurrences = Correction.occurrences(
            before = "Queen 三 ASR and Queen 三 ASR ",
            selected = "Queen 三 ASR",
            after = " again",
        )
        assertEquals(2, occurrences.size)
        assertEquals(-28, occurrences[0].offset)
        assertEquals(-12, occurrences[1].offset)
    }

    @Test
    fun readsTheAlsoNumbers() {
        val result = Correction.resolve(
            """{"replacement": "张伟", "also": [2]}""",
            selected = "张为",
            occurrenceCount = 2,
        )
        assertEquals(listOf(2), result?.also)
    }

    @Test
    fun acceptsJsonInsideProse() {
        assertEquals(
            "Qwen3-ASR",
            Correction.resolve(
                "结果：{\"replacement\": \"Qwen3-ASR\"} 以上。",
                selected = "Queen 三 ASR",
            )?.replacement,
        )
    }
}
