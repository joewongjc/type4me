package com.type4me.android.pipeline

import com.type4me.android.data.CjkSpacing
import com.type4me.android.data.TrailingPunctuation
import org.junit.Assert.assertEquals
import org.junit.Test

class TextPipelineTest {

    @Test
    fun panguAddsSpaceAtBothScriptBoundaries() {
        assertEquals(
            "用 Type4Me 说话",
            TextPipeline.format("用Type4Me说话", CjkSpacing.PANGU, TrailingPunctuation.KEEP),
        )
    }

    @Test
    fun panguDoesNotDoubleAnExistingSpace() {
        assertEquals(
            "用 Type4Me 说话",
            TextPipeline.format("用 Type4Me 说话", CjkSpacing.PANGU, TrailingPunctuation.KEEP),
        )
    }

    @Test
    fun panguLeavesPunctuationAdjacent() {
        assertEquals(
            "中文，English",
            TextPipeline.format("中文，English", CjkSpacing.PANGU, TrailingPunctuation.KEEP),
        )
    }

    @Test
    fun removeDeletesSpacesBetweenScripts() {
        assertEquals(
            "用Type4Me说话",
            TextPipeline.format("用  Type4Me 说话", CjkSpacing.REMOVE, TrailingPunctuation.KEEP),
        )
    }

    @Test
    fun keepSpacingLeavesTheTextAlone() {
        assertEquals(
            "用Type4Me 说话",
            TextPipeline.format("用Type4Me 说话", CjkSpacing.KEEP, TrailingPunctuation.KEEP),
        )
    }

    @Test
    fun periodModeStripsOnlyTrailingPeriods() {
        assertEquals(
            "你好",
            TextPipeline.format("你好。", CjkSpacing.KEEP, TrailingPunctuation.PERIOD),
        )
        assertEquals(
            "真的吗！",
            TextPipeline.format("真的吗！", CjkSpacing.KEEP, TrailingPunctuation.PERIOD),
        )
    }

    @Test
    fun allModeStripsAnyTrailingPunctuation() {
        assertEquals(
            "真的吗",
            TextPipeline.format("真的吗！？", CjkSpacing.KEEP, TrailingPunctuation.ALL),
        )
        assertEquals(
            "好",
            TextPipeline.format("好,", CjkSpacing.KEEP, TrailingPunctuation.ALL),
        )
    }

    @Test
    fun cornerQuotesReplaceCurlySingleQuotes() {
        assertEquals(
            "他说『好』",
            TextPipeline.format(
                "他说‘好’",
                CjkSpacing.KEEP,
                TrailingPunctuation.KEEP,
                cornerQuotes = true,
                modePunctuation = ModePunctuation.INHERIT,
            ),
        )
    }

    @Test
    fun modePunctuationOverridesTheGlobalSetting() {
        assertEquals(
            "真的吗？",
            TextPipeline.format(
                "真的吗？",
                CjkSpacing.KEEP,
                TrailingPunctuation.ALL,
                cornerQuotes = false,
                modePunctuation = ModePunctuation.QUESTIONS_AND_EXCLAMATIONS,
            ),
        )
        assertEquals(
            "你好",
            TextPipeline.format(
                "你好，",
                CjkSpacing.KEEP,
                TrailingPunctuation.KEEP,
                cornerQuotes = false,
                modePunctuation = ModePunctuation.REMOVE_ALL,
            ),
        )
    }

    @Test
    fun trailingSpacesAreRemoved() {
        assertEquals(
            "你好",
            TextPipeline.format("  你好  ", CjkSpacing.KEEP, TrailingPunctuation.KEEP),
        )
    }
}
