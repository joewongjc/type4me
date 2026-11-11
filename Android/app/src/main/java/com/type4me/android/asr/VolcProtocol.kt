package com.type4me.android.asr

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.util.zip.GZIPInputStream

/** The binary framing used by Volcengine's streaming speech endpoint. */
object VolcProtocol {
    const val ENDPOINT = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"

    private const val TYPE_FULL_CLIENT_REQUEST = 1
    private const val TYPE_AUDIO_ONLY_REQUEST = 2
    private const val TYPE_SERVER_RESPONSE = 9
    private const val TYPE_SERVER_ERROR = 15

    private const val FLAGS_NO_SEQUENCE = 0
    private const val FLAGS_LAST_NO_SEQUENCE = 2
    private const val FLAGS_NEGATIVE_SEQUENCE_LAST = 3
    private const val FLAGS_ASYNC_FINAL = 4

    private const val SERIALIZATION_NONE = 0
    private const val SERIALIZATION_JSON = 1
    private const val COMPRESSION_NONE = 0
    private const val COMPRESSION_GZIP = 1

    data class Header(
        val messageType: Int,
        val flags: Int,
        val serialization: Int,
        val compression: Int,
        val headerSize: Int = 1,
    ) {
        val isFinal: Boolean
            get() = flags == FLAGS_ASYNC_FINAL || flags == FLAGS_NEGATIVE_SEQUENCE_LAST
    }

    data class Response(val text: String, val final: Boolean)

    fun buildHeaders(
        apiKey: String?,
        appKey: String?,
        accessKey: String?,
        resourceId: String,
        connectId: String,
    ): Map<String, String> = buildMap {
        put("X-Api-Resource-Id", resourceId)
        put("X-Api-Connect-Id", connectId)
        if (!apiKey.isNullOrBlank()) {
            put("X-Api-Key", apiKey)
        } else if (!appKey.isNullOrBlank() && !accessKey.isNullOrBlank()) {
            put("X-Api-App-Key", appKey)
            put("X-Api-Access-Key", accessKey)
        }
    }

    fun fullClientRequest(uid: String, hotwords: List<String>): ByteArray {
        val request = JSONObject()
            .put("model_name", "bigmodel")
            .put("show_utterances", true)
            .put("result_type", "full")
            .put("enable_nonstream", true)
            .put("end_window_size", 3000)
            .put("force_to_speech_time", 0)
            .put("enable_punc", true)
            .put("enable_itn", true)
            .put("enable_ddc", true)
            .put("context_history_length", 20)

        val terms = hotwords.map { it.trim() }.filter { it.isNotEmpty() }.take(100)
        if (terms.isNotEmpty()) {
            val context = JSONObject().put(
                "hotwords",
                JSONArray().apply {
                    terms.forEach { put(JSONObject().put("word", it)) }
                },
            )
            request.put("corpus", JSONObject().put("context", context.toString()))
        }

        val payload = JSONObject()
            .put("user", JSONObject().put("uid", uid))
            .put(
                "audio",
                JSONObject()
                    .put("format", "pcm")
                    .put("codec", "raw")
                    .put("rate", 16000)
                    .put("bits", 16)
                    .put("channel", 1),
            )
            .put("request", request)

        return encodeMessage(
            Header(TYPE_FULL_CLIENT_REQUEST, FLAGS_NO_SEQUENCE, SERIALIZATION_JSON, COMPRESSION_NONE),
            payload.toString().toByteArray(Charsets.UTF_8),
        )
    }

    fun audioPacket(pcm: ByteArray, last: Boolean): ByteArray = encodeMessage(
        Header(
            messageType = TYPE_AUDIO_ONLY_REQUEST,
            flags = if (last) FLAGS_LAST_NO_SEQUENCE else FLAGS_NO_SEQUENCE,
            serialization = SERIALIZATION_NONE,
            compression = COMPRESSION_NONE,
        ),
        pcm,
    )

    fun decode(data: ByteArray): Response {
        val header = decodeHeader(data)
        var offset = header.headerSize * 4
        if (header.flags == 1 || header.flags == FLAGS_NEGATIVE_SEQUENCE_LAST) offset += 4
        if (data.size < offset + 4) throw AsrException("Volcengine response is truncated")
        val size = intAt(data, offset)
        offset += 4
        if (size < 0 || offset + size > data.size) throw AsrException("Volcengine response is malformed")
        var payload = data.copyOfRange(offset, offset + size)
        if (header.compression == COMPRESSION_GZIP) payload = gunzip(payload)
        if (header.serialization != SERIALIZATION_JSON) {
            throw AsrException("Volcengine response is not JSON")
        }

        val json = JSONObject(payload.toString(Charsets.UTF_8))
        val result = json.optJSONObject("result")
        val resultText = if (result == null || result.isNull("text")) {
            ""
        } else {
            result.optString("text")
        }
        val text = resultText.ifBlank { joinUtterances(result?.optJSONArray("utterances")) }
        return Response(text = text.trim(), final = header.isFinal)
    }

    fun decodeHeader(data: ByteArray): Header {
        if (data.size < 4) throw AsrException("Volcengine frame is too short")
        val byte0 = data[0].toInt() and 0xFF
        val byte1 = data[1].toInt() and 0xFF
        val byte2 = data[2].toInt() and 0xFF
        val headerSize = byte0 and 0x0F
        if (headerSize < 1) throw AsrException("Volcengine header size is invalid")
        return Header(
            messageType = (byte1 shr 4) and 0x0F,
            flags = byte1 and 0x0F,
            serialization = (byte2 shr 4) and 0x0F,
            compression = byte2 and 0x0F,
            headerSize = headerSize,
        )
    }

    fun isError(data: ByteArray): Boolean =
        runCatching { decodeHeader(data).messageType == TYPE_SERVER_ERROR }.getOrDefault(false)

    /** Best-effort text from a server error frame. */
    fun extractError(data: ByteArray): String? {
        val header = runCatching { decodeHeader(data) }.getOrNull() ?: return null
        var offset = header.headerSize * 4
        if (header.flags == 1 || header.flags == FLAGS_NEGATIVE_SEQUENCE_LAST) offset += 4
        val candidates = mutableListOf<ByteArray>()
        if (data.size >= offset + 4) {
            val size = intAt(data, offset)
            if (size in 1..(data.size - offset - 4)) {
                candidates += data.copyOfRange(offset + 4, offset + 4 + size)
            }
        }
        candidates += data.copyOfRange(minOf(offset, data.size), data.size)
        for (candidate in candidates) {
            val decoded = runCatching { jsonError(candidate) }.getOrNull()
            if (!decoded.isNullOrBlank()) return decoded
        }
        return null
    }

    private fun jsonError(data: ByteArray): String? {
        val text = data.toString(Charsets.UTF_8).trim()
        val objectText = text.substringAfter('{', "").substringBeforeLast('}', "")
        if (objectText.isNotBlank()) {
            val json = runCatching { JSONObject("{$objectText}") }.getOrNull()
            if (json != null) {
                val message = listOf("error", "message", "msg", "error_msg")
                    .firstNotNullOfOrNull { key -> json.optString(key).takeIf { it.isNotBlank() } }
                val code = json.optInt("code", 0)
                if (message != null) {
                    return if (code != 0) "$message ($code)" else message
                }
            }
        }
        return text.takeIf { it.isNotBlank() && it.none { char -> char.code < 0x20 } }
            ?.take(200)
    }

    private fun joinUtterances(utterances: JSONArray?): String {
        if (utterances == null) return ""
        val builder = StringBuilder()
        for (index in 0 until utterances.length()) {
            val text = utterances.optJSONObject(index)?.optString("text").orEmpty()
            if (text.isEmpty()) continue
            if (builder.isNotEmpty() && needsSpace(builder.last(), text.first())) builder.append(' ')
            builder.append(text)
        }
        return builder.toString()
    }

    private fun needsSpace(left: Char, right: Char): Boolean =
        !isCjk(left) && !isCjk(right) && !left.isWhitespace() && !right.isWhitespace()

    private fun isCjk(char: Char): Boolean =
        char.code in 0x3400..0x4DBF || char.code in 0x4E00..0x9FFF || char.code in 0x3040..0x30FF

    private fun encodeMessage(header: Header, payload: ByteArray): ByteArray {
        val out = ByteArray(4 + 4 + payload.size)
        out[0] = ((1 shl 4) or (header.headerSize and 0x0F)).toByte()
        out[1] = ((header.messageType shl 4) or (header.flags and 0x0F)).toByte()
        out[2] = ((header.serialization shl 4) or (header.compression and 0x0F)).toByte()
        out[3] = 0
        val size = payload.size
        out[4] = (size ushr 24).toByte()
        out[5] = (size ushr 16).toByte()
        out[6] = (size ushr 8).toByte()
        out[7] = size.toByte()
        payload.copyInto(out, 8)
        return out
    }

    private fun intAt(data: ByteArray, offset: Int): Int =
        ((data[offset].toInt() and 0xFF) shl 24) or
            ((data[offset + 1].toInt() and 0xFF) shl 16) or
            ((data[offset + 2].toInt() and 0xFF) shl 8) or
            (data[offset + 3].toInt() and 0xFF)

    private fun gunzip(data: ByteArray): ByteArray =
        GZIPInputStream(ByteArrayInputStream(data)).use { it.readBytes() }
}
