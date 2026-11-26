package com.type4me.android.asr

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VolcProtocolTest {
    @Test
    fun audioPacketsUseTheAudioHeaderAndLastFlag() {
        val packet = VolcProtocol.audioPacket(ByteArray(4) { 1 }, last = false)
        val header = VolcProtocol.decodeHeader(packet)
        assertEquals(2, header.messageType)
        assertEquals(0, header.flags)
        assertFalse(header.isFinal)

        val last = VolcProtocol.decodeHeader(VolcProtocol.audioPacket(ByteArray(0), last = true))
        assertEquals(2, last.flags)
        // Last-packet is a client flag, not the server's final-response flag.
        assertFalse(last.isFinal)
    }

    @Test
    fun fullClientRequestCarriesTheModelAndHotwords() {
        val message = VolcProtocol.fullClientRequest("user-1", listOf("Type4Me", "Qwen3-ASR"))
        val header = VolcProtocol.decodeHeader(message)
        assertEquals(1, header.messageType)
        assertEquals(1, header.serialization)
        val size = ((message[4].toInt() and 0xFF) shl 24) or
            ((message[5].toInt() and 0xFF) shl 16) or
            ((message[6].toInt() and 0xFF) shl 8) or
            (message[7].toInt() and 0xFF)
        val json = JSONObject(message.copyOfRange(8, 8 + size).toString(Charsets.UTF_8))
        assertEquals("bigmodel", json.getJSONObject("request").getString("model_name"))
        val context = json.getJSONObject("request").getJSONObject("corpus").getString("context")
        assertTrue(context.contains("Type4Me"))
    }

    @Test
    fun decodesAFinalServerResponse() {
        // 0x94 encodes message type 9 (server response) and async-final flags.
        val response = VolcProtocol.decode(volcServerFrame("你好，世界。", final = true))
        assertEquals("你好，世界。", response.text)
        assertTrue(response.final)
    }
}
