package com.type4me.android.asr

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TencentProtocolTest {
    @Test
    fun decodesTheResultSliceShape() {
        val message = TencentProtocol.decode(
            """{"code":0,"message":"success","voice_id":"v1","final":0,""" +
                """"result":{"slice_type":2,"index":3,"voice_text_str":"你好"}}""",
        )!!
        assertEquals(0, message.code)
        assertEquals("success", message.message)
        assertEquals("v1", message.voiceId)
        assertFalse(message.final)
        assertEquals(1, message.updates.size)
        assertEquals(TencentProtocol.SentenceUpdate(3, "你好", true), message.updates[0])
    }

    @Test
    fun decodesSentenceArraysAndTheFinalFlag() {
        val message = TencentProtocol.decode(
            """{"code":0,"final":1,"sentences":[{"sentence_id":0,"sentence":"你好","sentence_type":1},""" +
                """{"sentence_id":1,"sentence":"世界","sentence_type":0}]}""",
        )!!
        assertTrue(message.final)
        assertEquals(2, message.updates.size)
        assertTrue(message.updates[0].final)
        assertFalse(message.updates[1].final)

        val single = TencentProtocol.decode(
            """{"code":0,"sentences":{"sentence_id":2,"sentence":"好","sentence_type":1}}""",
        )!!
        assertEquals(TencentProtocol.SentenceUpdate(2, "好", true), single.updates[0])
    }

    @Test
    fun rejectsPayloadsWithoutACode() {
        assertNull(TencentProtocol.decode("""{"result":{"slice_type":2}}"""))
        assertNull(TencentProtocol.decode("not json"))
    }

    @Test
    fun transcriptKeepsSentenceOrderAndReplacesPartials() {
        val state = TencentTranscriptState()
        state.apply(TencentProtocol.SentenceUpdate(0, "你好", true))
        state.apply(TencentProtocol.SentenceUpdate(1, "世", false))
        assertEquals("你好世", state.text)

        state.apply(TencentProtocol.SentenceUpdate(1, "世界", false))
        assertEquals("你好世界", state.text)

        // Finalized ids are frozen.
        state.apply(TencentProtocol.SentenceUpdate(1, "世界。", true))
        assertEquals("你好世界。", state.text)

        state.apply(TencentProtocol.SentenceUpdate(2, "再见", false))
        assertEquals("你好世界。再见", state.text)

        state.markFinal()
        assertTrue(state.isCompleted)
        assertEquals("你好世界。再见", state.text)
    }

    @Test
    fun hotwordListIsWeightedAndFiltered() {
        val list = TencentProtocol.formatHotwords(
            listOf("Type4Me", "Type4Me", "hello world", "a,b", "a|b", "腾讯云", "  "),
        )
        assertEquals("Type4Me|10,腾讯云|10", list)
        assertNull(TencentProtocol.formatHotwords(listOf("hello world")))
    }

    @Test
    fun liveParametersCarryTheEngineAndHotwords() {
        val parameters = TencentProtocol.liveParameters(listOf("Type4Me"))
        assertEquals("16k_zh_en_2.0", parameters["engine_model_type"])
        assertEquals("1", parameters["needvad"])
        assertEquals("Type4Me|10", parameters["hotword_list"])
        assertNull(TencentProtocol.liveParameters(emptyList())["hotword_list"])
    }

    @Test
    fun resultTextDropsTimingPrefixesAndJoinsSegments() {
        assertEquals(
            "你好，世界。",
            TencentProtocol.cleanResultText("[0:0.0]你好，\n[0:1.5]世界。"),
        )
        assertEquals(
            "Hello world",
            TencentProtocol.cleanResultText("[0:0.0]Hello\n[0:1.0]world"),
        )
        assertEquals("", TencentProtocol.cleanResultText("\n  \n"))
    }

    @Test
    fun errorCodesBecomeReadableText() {
        assertTrue(TencentProtocol.serverErrorText(4002, "invalid appid").contains("AppID"))
        assertTrue(TencentProtocol.serverErrorText(4004, "").contains("resource pack"))
        assertTrue(TencentProtocol.apiErrorText("AuthFailure.SignatureExpire", "").contains("signature expired"))
        assertTrue(TencentProtocol.apiErrorText("FailedOperation", "task failed").contains("task failed"))
    }
}
