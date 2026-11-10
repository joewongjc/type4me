package com.type4me.android.data

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.Base64
import java.util.zip.Deflater

class TransferCodecTest {

    private val json = """
        {"v":2,
         "a":{"p":"volcano","f":{"apiKey":"asr-key","resourceId":"volc.seedasr.sauc.duration"}},
         "l":{"p":"deepseek","f":{"apiKey":"llm-key","model":"deepseek-chat","baseURL":"https://api.deepseek.com/v1"}},
         "m":[{"i":"m1","k":"formalWriting"},{"i":"m2","k":"translateEnglish","g":"ja"}],
         "h":["Type4Me","火山"],
         "s":[{"t":"我的邮箱","r":"me@example.com"}],
         "d":"Shane-Mac",
         "t":1700000000}
    """.trimIndent()

    private fun token(body: String = json, rawDeflate: Boolean = true, version: String = "T4M2."): String {
        val deflater = Deflater(Deflater.DEFAULT_COMPRESSION, rawDeflate)
        deflater.setInput(body.toByteArray(Charsets.UTF_8))
        deflater.finish()
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(1024)
        while (!deflater.finished()) {
            val read = deflater.deflate(buffer)
            output.write(buffer, 0, read)
        }
        deflater.end()
        val encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(output.toByteArray())
        return version + encoded
    }

    private fun compressedToken(data: ByteArray): String {
        val deflater = Deflater(Deflater.DEFAULT_COMPRESSION, true)
        deflater.setInput(data)
        deflater.finish()
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8 * 1024)
        while (!deflater.finished()) {
            val read = deflater.deflate(buffer)
            output.write(buffer, 0, read)
        }
        deflater.end()
        val encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(output.toByteArray())
        return TransferCodec.COMPRESSED_PREFIX + encoded
    }

    @Test
    fun `decodes compressed payload in a url`() {
        val payload = TransferCodec.decode("type4me://import?c=${token()}")

        assertEquals(2, payload.version)
        assertEquals("volcano", payload.asr?.provider)
        assertEquals("asr-key", payload.asr?.fields?.get("apiKey"))
        assertEquals("deepseek-chat", payload.llm?.fields?.get("model"))
        assertEquals(listOf("formalWriting", "translateEnglish"), payload.modes.map { it.kind })
        assertEquals("ja", payload.modes[1].targetLanguage)
        assertEquals(listOf("Type4Me", "火山"), payload.hotwords)
        assertEquals("me@example.com", payload.snippets?.single()?.replacement)
        assertEquals("Shane-Mac", payload.sourceName)
    }

    @Test
    fun `accepts a zlib wrapped stream`() {
        val payload = TransferCodec.decode(token(rawDeflate = false))
        assertEquals("volcano", payload.asr?.provider)
    }

    @Test
    fun `accepts plain version one json`() {
        val plain = Base64.getUrlEncoder().withoutPadding()
            .encodeToString(json.toByteArray(Charsets.UTF_8))
        val payload = TransferCodec.decode("T4M1.$plain")
        assertEquals("deepseek", payload.llm?.provider)
    }

    @Test
    fun `rejects a newer version`() {
        val newer = JSONObject(json).put("v", 3).toString()
        val error = runCatching { TransferCodec.decode(token(newer)) }.exceptionOrNull()
        assertTrue(error is TransferException)
        assertEquals(
            TransferException.Kind.UNSUPPORTED_VERSION,
            (error as TransferException).kind,
        )
    }

    @Test
    fun `rejects a decompression bomb quickly`() {
        // 4 MiB of zeros deflates to a few kilobytes and fits one deep link.
        val bomb = compressedToken(ByteArray(4 * 1024 * 1024))
        assertTrue(bomb.length < 64 * 1024)

        val started = System.nanoTime()
        val error = runCatching { TransferCodec.decode(bomb) }.exceptionOrNull()
        val elapsedMs = (System.nanoTime() - started) / 1_000_000

        assertTrue(error is TransferException)
        assertEquals(TransferException.Kind.CORRUPTED, (error as TransferException).kind)
        assertTrue("decode took ${elapsedMs}ms", elapsedMs < 2_000)
    }

    @Test
    fun `rejects an oversized token before decoding`() {
        val token = TransferCodec.COMPRESSED_PREFIX + "A".repeat(1 shl 20) + "AAAA"
        val error = runCatching { TransferCodec.decode(token) }.exceptionOrNull()
        assertTrue(error is TransferException)
        assertEquals(TransferException.Kind.CORRUPTED, (error as TransferException).kind)
    }

    @Test
    fun `ignores text without a token`() {
        assertNull(TransferCodec.extractToken("https://example.com"))
        val status = TransferAssembler().add("https://example.com")
        assertTrue(status is TransferAssembler.Status.Ignored)
    }

    @Test
    fun `assembles parts scanned out of order`() {
        val body = token().removePrefix(TransferCodec.COMPRESSED_PREFIX)
        val half = body.length / 2
        val first = "type4me://import?c=${TransferCodec.PART_PREFIX}group1.1.2.${body.substring(0, half)}"
        val second = "type4me://import?c=${TransferCodec.PART_PREFIX}group1.2.2.${body.substring(half)}"

        val assembler = TransferAssembler()
        val progress = assembler.add(second)
        assertTrue(progress is TransferAssembler.Status.Progress)
        assertEquals(1, (progress as TransferAssembler.Status.Progress).received.size)
        assertTrue(assembler.add(second) is TransferAssembler.Status.Progress)

        val complete = assembler.add(first)
        assertTrue(complete is TransferAssembler.Status.Complete)
        assertEquals(
            "volcano",
            (complete as TransferAssembler.Status.Complete).payload.asr?.provider,
        )
    }

    @Test
    fun `a part alone is not a complete payload`() {
        val error = runCatching {
            TransferCodec.decode("T4MP.group1.1.2.abcdef")
        }.exceptionOrNull()
        assertEquals(TransferException.Kind.PARTIAL, (error as TransferException).kind)
    }

    @Test
    fun `decodes a token produced by the mac encoder`() {
        // Generated with NSData.compressed(using: .zlib), the Mac's encoder.
        val token = "T4M2.dU-9TsMwEH6Xm5OUVohKmVgYEHThRwyI4XCujYljB9upqKIMIAZWVl4BqVIfCiLegnObVCx4OPn7O33XAELawDwMrOQZrSAFT87H6GxcMIzAkjO1FXSasbY0SiSOKGM9cViLJKstemk0tBFUvQO1CTAELnPUFM9Q8KYc0lu4WlV0OCOG3fPn12YDdxGof0ooVfYl7tHR9cU5C7n3lUtHI3YmGVHFZYpEmHK0HLOvNBnxNhiUWOToh2oDGXDJXRqQzIZI_FhLUXC-YGL3b6M_8tzYElWv78CNlV7qxda3YPYBWd4HvEXtFHrqM3t8ohdKuhxaPtttO9iQoWN6wrJSFE7hjGfy--29-3j9eVl3683Wz-R4ejSZHoQXwRLSSfsL"
        val payload = TransferCodec.decode("type4me://import?c=$token")
        assertEquals("volcano", payload.asr?.provider)
        assertEquals("deepseek", payload.llm?.provider)
        assertEquals("ja", payload.modes.first { it.kind == "translateEnglish" }.targetLanguage)
        assertEquals(2, payload.hotwords?.size)
        assertEquals("Shane-Mac", payload.sourceName)
    }
}
