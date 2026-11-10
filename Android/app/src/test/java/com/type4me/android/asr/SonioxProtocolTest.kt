package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import com.type4me.android.data.AsrKind
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SonioxProtocolTest {
    @Test
    fun startMessageCarriesTheKeyAndHotwords() {
        val config = AsrConfig(
            kind = AsrKind.SONIOX,
            model = "stt-rt-v5",
            apiKey = "secret",
            endpointSensitivity = -0.3,
        )
        val json = JSONObject(SonioxProtocol.startMessage(config, listOf("Type4Me")))
        assertEquals("stt-rt-v5", json.getString("model"))
        assertEquals(16000, json.getInt("sample_rate"))
        assertEquals("secret", json.getString("api_key"))
        assertEquals("Type4Me", json.getJSONObject("context").getJSONArray("terms").getString(0))
    }

    @Test
    fun parsesFinalAndPartialTokens() {
        val body = """
            {
              "tokens": [
                {"text": "你好", "is_final": true},
                {"text": "，", "is_final": true},
                {"text": "世界", "is_final": false}
              ],
              "finished": false
            }
        """.trimIndent()
        val update = SonioxProtocol.parse(body)
        assertEquals("你好，", update.finalized)
        assertEquals("世界", update.partial)
        assertTrue(!update.finished)
    }

    @Test
    fun ignoresMarkerTokens() {
        val update = SonioxProtocol.parse(
            """{"tokens":[{"text":"<end>","is_final":true},{"text":"好","is_final":true}],"finished":true}""",
        )
        assertEquals("好", update.finalized)
        assertTrue(update.finished)
    }
}
