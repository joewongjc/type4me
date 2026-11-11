package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AsrTextToolsTest {
    @Test
    fun normalizeSegmentSpacesLatinWordsOnly() {
        assertEquals(" world", AsrTextTools.normalizeSegment("world", "hello"))
        assertEquals(".", AsrTextTools.normalizeSegment(".", "hello"))
        assertEquals("世界", AsrTextTools.normalizeSegment("世界", "你好"))
        assertEquals(" world", AsrTextTools.normalizeSegment("world", "hello."))
        assertEquals("world", AsrTextTools.normalizeSegment("world", "hello "))
    }

    @Test
    fun stripConfirmedPrefixRemovesOnlyTheLeadingText() {
        assertEquals("world", AsrTextTools.stripConfirmedPrefix("hello world", "hello"))
        assertEquals("hello world", AsrTextTools.stripConfirmedPrefix("hello world", "goodbye"))
        assertEquals("hello", AsrTextTools.stripConfirmedPrefix("hello", ""))
    }

    @Test
    fun punctuationIsConvertedForNonCjkLanguages() {
        assertEquals("hello, world. how are you?", AsrTextTools.normalizePunctuation("en", "hello，world。how are you？"))
        assertEquals("你好，世界。", AsrTextTools.normalizePunctuation("zh", "你好，世界。"))
    }

    @Test
    fun labeledHotwordEchoIsDropped() {
        val hotwords = listOf("Type4Me", "Intelli Sense")
        assertEquals(
            "let us begin",
            AsrTextTools.sanitizeHotwordLeak("Hotwords: Type4Me, Intelli Sense. let us begin", hotwords),
        )
        assertEquals("Type4Me", AsrTextTools.sanitizeHotwordLeak("Type4Me", listOf("Type4Me")))
        assertFalse(
            AsrTextTools.sanitizeHotwordLeak("real speech here", hotwords).isEmpty(),
        )
    }

    @Test
    fun portableStreamingMapsProviderIds() {
        val onPartial: (String) -> Unit = {}
        val onError: (Throwable) -> Unit = {}
        assertTrue(PortableStreamingB.create("elevenlabs", onPartial, onError) is ElevenLabsSession)
        assertTrue(PortableStreamingB.create("gemini", onPartial, onError) is GeminiSession)
        assertTrue(PortableStreamingB.create("grok", onPartial, onError) is GrokSession)
        assertTrue(PortableStreamingB.create("metaMuse", onPartial, onError) is MetaMuseSession)
        assertNull(PortableStreamingB.create("volcano", onPartial, onError))
    }

    @Test
    fun portableBatchLeavesUnsupportedProvidersToOthers() = kotlinx.coroutines.runBlocking {
        assertNull(PortableBatchB.transcribe("soniox", AsrConfig(), ByteArray(2), emptyList()))
    }
}
