package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeepgramProtocolTest {
    @Test
    fun buildsNova3UrlWithInterimResultsAndKeyterms() {
        val url = DeepgramProtocol.buildUrl(
            AsrConfig(model = "nova-3", extra = mapOf("language" to "zh")),
            listOf("Type4Me", "  ", "阶跃"),
        )
        assertTrue(url.startsWith("wss://api.deepgram.com/v1/listen?"))
        assertTrue(url.contains("model=nova-3"))
        assertTrue(url.contains("encoding=linear16"))
        assertTrue(url.contains("sample_rate=16000"))
        assertTrue(url.contains("channels=1"))
        assertTrue(url.contains("interim_results=true"))
        assertTrue(url.contains("punctuate=true"))
        assertTrue(url.contains("smart_format=true"))
        assertTrue(url.contains("language=zh"))
        assertTrue(url.contains("keyterm=Type4Me"))
        assertTrue(url.contains("keyterm=%E9%98%B6%E8%B7%83"))
        assertFalse(url.contains("numerals"))
    }

    @Test
    fun nova2UsesKeywordIntensityAndNumerals() {
        val url = DeepgramProtocol.buildUrl(
            AsrConfig(model = "nova-2", extra = mapOf("numerals" to "true")),
            listOf("Type4Me"),
        )
        assertTrue(url.contains("keywords=Type4Me%3A2"))
        assertTrue(url.contains("numerals=true"))
        assertFalse(url.contains("keyterm="))
    }

    @Test
    fun fluxModelsSwitchToTheV2Endpoint() {
        val url = DeepgramProtocol.buildUrl(
            AsrConfig(model = "flux-general-multi", extra = mapOf("language" to "zh")),
            emptyList(),
        )
        assertTrue(url.startsWith("wss://api.deepgram.com/v2/listen?"))
        assertTrue(url.contains("eot_threshold=0.7"))
        assertTrue(url.contains("language_hint=zh"))
        assertFalse(url.contains("interim_results"))
    }

    @Test
    fun baseUrlOverrideKeepsItsExistingPathAndQuery() {
        val url = DeepgramProtocol.buildUrl(
            AsrConfig(baseUrl = "wss://proxy.test/asr?token=abc", model = "nova-3"),
            emptyList(),
        )
        assertTrue(url.startsWith("wss://proxy.test/asr?token=abc&"))
    }

    @Test
    fun onlyDeepgramHostsUseStandardAuthorization() {
        assertTrue(DeepgramProtocol.usesStandardAuthorization("wss://api.deepgram.com/v1/listen"))
        assertTrue(DeepgramProtocol.usesStandardAuthorization("wss://asr.autoloops.ai/v1/listen"))
        // An https endpoint upgrades to wss, so it stays a standard Deepgram host.
        assertTrue(DeepgramProtocol.usesStandardAuthorization("https://api.deepgram.com/v1/listen"))
        assertFalse(DeepgramProtocol.usesStandardAuthorization("wss://proxy.test/v1/listen"))
        assertFalse(DeepgramProtocol.usesStandardAuthorization("wss://api.deepgram.com.evil.test/listen"))
        assertFalse(DeepgramProtocol.usesStandardAuthorization("https://proxy.test/v1/listen"))
    }

    @Test
    fun httpEndpointsUpgradeToWebSockets() {
        val url = DeepgramProtocol.buildUrl(
            AsrConfig(baseUrl = "http://127.0.0.1:9000/v1/listen", model = "nova-3"),
            emptyList(),
        )
        assertTrue(url.startsWith("ws://127.0.0.1:9000/v1/listen?"))
    }

    @Test
    fun foldsInterimResultsIntoFinalSegments() {
        val interim = DeepgramProtocol.parse(
            """{"type":"Results","is_final":false,"channel":{"alternatives":[{"transcript":"hello"}]}}""",
            emptyList(),
        )!!
        assertEquals("hello", interim.text)
        assertFalse(interim.final)
        assertTrue(interim.confirmedSegments.isEmpty())

        val confirmed = DeepgramProtocol.parse(
            """{"type":"Results","is_final":true,"speech_final":true,"channel":{"alternatives":[{"transcript":"hello"}]}}""",
            interim.confirmedSegments,
        )!!
        assertEquals("hello", confirmed.text)
        assertTrue(confirmed.final)
        assertEquals(listOf("hello"), confirmed.confirmedSegments)

        val next = DeepgramProtocol.parse(
            """{"type":"Results","is_final":false,"channel":{"alternatives":[{"transcript":"world"}]}}""",
            confirmed.confirmedSegments,
        )!!
        assertEquals("hello world", next.text)
    }

    @Test
    fun ignoresNonTranscriptMessagesAndEmptyInterimResults() {
        assertNull(DeepgramProtocol.parse("""{"type":"Metadata"}""", emptyList()))
        assertNull(
            DeepgramProtocol.parse(
                """{"type":"Results","is_final":false,"channel":{"alternatives":[{"transcript":""}]}}""",
                emptyList(),
            ),
        )
        // An empty final with settled text keeps the existing transcript.
        val settled = DeepgramProtocol.parse(
            """{"type":"Results","is_final":true,"channel":{"alternatives":[{"transcript":""}]}}""",
            listOf("hello"),
        )!!
        assertEquals("hello", settled.text)
        assertTrue(settled.final)
    }

    @Test
    fun parsesFluxTurnInfoEndOfTurn() {
        val interim = DeepgramProtocol.parse(
            """{"type":"TurnInfo","event":"Update","transcript":"你好"}""",
            emptyList(),
        )!!
        assertEquals("你好", interim.text)
        assertFalse(interim.final)

        val end = DeepgramProtocol.parse(
            """{"type":"TurnInfo","event":"EndOfTurn","transcript":"你好。"}""",
            interim.confirmedSegments,
        )!!
        assertTrue(end.final)
        assertEquals("你好。", end.text)
    }
}
