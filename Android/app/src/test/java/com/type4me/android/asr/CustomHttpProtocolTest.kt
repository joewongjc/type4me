package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class CustomHttpProtocolTest {
    @Test
    fun headersSubstituteTheApiKeyAndDefaultToBearer() {
        val headers = CustomHttpProtocol.parseHeaders(
            "Authorization: Bearer {{api_key}}\nX-Trace: 1",
            "secret",
        )
        assertEquals(listOf("Authorization" to "Bearer secret", "X-Trace" to "1"), headers)

        assertEquals(
            listOf("Authorization" to "Bearer secret"),
            CustomHttpProtocol.parseHeaders("", "secret"),
        )
        assertEquals(emptyList<Pair<String, String>>(), CustomHttpProtocol.parseHeaders("", ""))
    }

    @Test
    fun malformedHeaderLinesAreRejected() {
        assertThrows(AsrException::class.java) {
            CustomHttpProtocol.parseHeaders("NoColonHere", "key")
        }
        assertThrows(AsrException::class.java) {
            CustomHttpProtocol.parseHeaders("Bad Name: value", "key")
        }
    }

    @Test
    fun templatePlaceholdersAreSubstitutedRecursively() {
        val template = CustomHttpProtocol.parseTemplate(
            """{"model":"m","audio":"{{audio_base64}}","meta":{"key":"{{api_key}}"}}""",
        )!!
        val substituted = CustomHttpProtocol.substitute(
            template,
            mapOf(
                CustomHttpProtocol.API_KEY_PLACEHOLDER to "k",
                CustomHttpProtocol.AUDIO_BASE64_PLACEHOLDER to "AAA",
            ),
        ) as JSONObject
        assertEquals("AAA", substituted.getString("audio"))
        assertEquals("k", substituted.getJSONObject("meta").getString("key"))
    }

    @Test
    fun curlyQuotesAreAcceptedInTemplates() {
        val template = CustomHttpProtocol.parseTemplate("{\u201Caudio\u201D: \u201C{{audio_base64}}\u201D}")
        assertEquals("{{audio_base64}}", template!!.getString("audio"))
        assertNull(CustomHttpProtocol.parseTemplate("not json"))
    }

    @Test
    fun audioPlaceholdersAreDetected() {
        val jsonTemplate = CustomHttpProtocol.parseTemplate("""{"audio":"{{audio_base64}}"}""")!!
        assertTrue(CustomHttpProtocol.contains(jsonTemplate, CustomHttpProtocol.AUDIO_BASE64_PLACEHOLDER))
        assertNull(CustomHttpProtocol.audioFieldKey(jsonTemplate))

        val multipartTemplate = CustomHttpProtocol.parseTemplate(
            """{"file":"{{audio_file}}","model":"{{api_key}}"}""",
        )!!
        assertEquals("file", CustomHttpProtocol.audioFieldKey(multipartTemplate))
        assertTrue(CustomHttpProtocol.contains(multipartTemplate, CustomHttpProtocol.AUDIO_FILE_PLACEHOLDER))
    }

    @Test
    fun resultPathsResolveDottedNamesAndIndexes() {
        val root = JSONObject(
            """{"text":"hi","results":[{"alternatives":[{"transcript":"dotted"}]}],"nested":{"a":{"text":"deep"}}}""",
        )
        assertEquals("hi", CustomHttpProtocol.valueAt("text", root))
        assertEquals("dotted", CustomHttpProtocol.valueAt("results[0].alternatives[0].transcript", root))
        assertEquals("deep", CustomHttpProtocol.valueAt("nested.a.text", root))
        assertNull(CustomHttpProtocol.valueAt("results[9].alternatives[0].transcript", root))
        assertNull(CustomHttpProtocol.valueAt("missing.path", root))
    }

    @Test
    fun transcriptIsReadFromTheConfiguredField() {
        val body = """{"results":[{"alternatives":[{"transcript":" 你好 "}]}]}"""
        assertEquals("你好", CustomHttpProtocol.parseTranscript(body, "results[0].alternatives[0].transcript"))
        val failure = assertThrows(AsrException::class.java) {
            CustomHttpProtocol.parseTranscript(body, "text")
        }
        assertTrue(failure.message!!.contains("text"))
    }

    @Test
    fun multipartBodyPutsTheWavInTheFilePart() {
        val fields = CustomHttpProtocol.parseTemplate(
            """{"file":"{{audio_file}}","model":"m","api_key":"{{api_key}}"}""",
        )!!
        val wav = byteArrayOf(1, 2, 3, 4)
        val body = CustomHttpProtocol.multipartBody(fields, "secret", wav, "BOUNDARY")
        val text = body.toString(Charsets.UTF_8)

        assertTrue(text.contains("--BOUNDARY\r\n"))
        assertTrue(text.contains("name=\"file\"; filename=\"audio.wav\""))
        assertTrue(text.contains("Content-Type: audio/wav"))
        assertTrue(text.contains("name=\"model\"\r\n\r\nm"))
        assertTrue(text.contains("name=\"api_key\"\r\n\r\nsecret"))
        assertTrue(text.endsWith("--BOUNDARY--\r\n"))
        assertTrue(text.contains("\u0001\u0002\u0003\u0004"))
    }

    @Test
    fun settingsRequireAHttpEndpointAndATemplate() {
        assertThrows(AsrException::class.java) {
            CustomHttpProtocol.settings(AsrConfig(providerId = "custom", baseUrl = "ftp://example.com"))
        }
        assertThrows(AsrException::class.java) {
            CustomHttpProtocol.settings(
                AsrConfig(
                    providerId = "custom",
                    baseUrl = "https://example.com/asr",
                    extra = mapOf("bodyTemplate" to "   "),
                ),
            )
        }
        val settings = CustomHttpProtocol.settings(
            AsrConfig(
                providerId = "custom",
                baseUrl = "https://example.com/asr",
                apiKey = "k",
                extra = mapOf(
                    "bodyTemplate" to """{"audio":"{{audio_base64}}"}""",
                    "uploadFormat" to "multipart",
                    "resultPath" to "result.text",
                ),
            ),
        )
        assertEquals(CustomHttpProtocol.UPLOAD_MULTIPART, settings.uploadFormat)
        assertEquals("result.text", settings.resultPath)
        assertEquals(listOf("Authorization" to "Bearer k"), settings.headers)
    }

    @Test
    fun noSpeechMarkersAreRecognized() {
        assertTrue(CustomHttpProtocol.isNoSpeechBody("""{"code":"20000003"}"""))
        assertTrue(CustomHttpProtocol.isNoSpeechBody("ASR_RESPONSE_HAVE_NO_WORDS"))
        assertEquals(false, CustomHttpProtocol.isNoSpeechBody("""{"text":"hello"}"""))
    }
}
