package com.type4me.android.data

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.zip.Inflater

/**
 * The configuration the Mac app shows as a QR code for the mobile apps.
 *
 * The wire format is shared with the iPhone app: `T4M2.` plus base64url of a
 * raw-deflate JSON document, or a `T4MP.<group>.<index>.<total>.<chunk>`
 * series when the document is too large for one code. The Mac cycles those
 * codes; the scanner collects them until the set is complete.
 */
data class TransferEndpoint(
    val provider: String,
    val fields: Map<String, String>,
)

data class TransferMode(
    val id: String,
    val kind: String,
    val name: String?,
    val prompt: String?,
    val targetLanguage: String?,
    val punctuation: String? = null,
    val shortTextExemption: Int? = null,
)

data class TransferTextOutput(
    val cjkSpacing: String?,
    val trailingPunctuation: String?,
    val cornerQuotes: Boolean?,
)

data class TransferPayload(
    val version: Int,
    val asr: TransferEndpoint?,
    val llm: TransferEndpoint?,
    val modes: List<TransferMode>,
    val hotwords: List<String>?,
    val snippets: List<Snippet>?,
    val sourceName: String?,
    val asrProfiles: List<TransferEndpoint> = emptyList(),
    val llmProfiles: List<TransferEndpoint> = emptyList(),
    val textOutput: TransferTextOutput? = null,
) {
    /** Every service, the active one first, one per provider. */
    val allAsrs: List<TransferEndpoint>
        get() = (listOfNotNull(asr) + asrProfiles).distinctBy { it.provider }

    val allLlms: List<TransferEndpoint>
        get() = (listOfNotNull(llm) + llmProfiles).distinctBy { it.provider }
}

class TransferException(
    val kind: Kind,
    val version: Int = 0,
) : Exception(kind.name) {
    enum class Kind {
        NOT_FOUND,
        CORRUPTED,
        UNSUPPORTED_VERSION,
        EMPTY,
        PARTIAL,
    }
}

object TransferCodec {
    const val TEXT_PREFIX = "T4M1."
    const val COMPRESSED_PREFIX = "T4M2."
    const val PART_PREFIX = "T4MP."
    private const val CURRENT_VERSION = 2

    /** Longest token accepted from a scan or deep link; deep links are untrusted. */
    private const val MAX_TOKEN_CHARS = 1 shl 20
    private const val MAX_INPUT_CHARS = MAX_TOKEN_CHARS + 4096

    /** Longest inflated document; a real setup payload is far smaller. */
    private const val MAX_INFLATED_BYTES = 2 shl 20

    /** Longest single part chunk; a scannable QR code cannot carry more. */
    private const val MAX_CHUNK_CHARS = 8 * 1024

    data class Part(val group: String, val index: Int, val total: Int, val chunk: String)

    /** One part of a payload split across several codes, or null for a whole code. */
    fun part(input: String): Part? {
        if (input.length > MAX_INPUT_CHARS) return null
        val text = compact(input)
        val at = text.indexOf(PART_PREFIX)
        if (at < 0) return null
        val fields = text.substring(at + PART_PREFIX.length).split('.', limit = 4)
        if (fields.size != 4) return null
        val index = fields[1].toIntOrNull() ?: return null
        val total = fields[2].toIntOrNull() ?: return null
        if (total !in 1..99 || index !in 1..total) return null
        val chunk = fields[3].takeWhile(::isBase64Url)
        if (fields[0].isEmpty() || chunk.isEmpty() || chunk.length > MAX_CHUNK_CHARS) return null
        return Part(fields[0], index, total, chunk)
    }

    fun decode(input: String): TransferPayload {
        if (input.length > MAX_INPUT_CHARS) {
            throw TransferException(TransferException.Kind.CORRUPTED)
        }
        if (part(input) != null) throw TransferException(TransferException.Kind.PARTIAL)
        val token = extractToken(input) ?: throw TransferException(TransferException.Kind.NOT_FOUND)
        return decodeToken(token)
    }

    fun decodeToken(token: String): TransferPayload {
        if (token.length > MAX_TOKEN_CHARS) {
            throw TransferException(TransferException.Kind.CORRUPTED)
        }
        val compressed = token.startsWith(COMPRESSED_PREFIX)
        val prefix = if (compressed) COMPRESSED_PREFIX else TEXT_PREFIX
        var data = base64UrlDecode(token.substring(prefix.length))
            ?: throw TransferException(TransferException.Kind.CORRUPTED)
        if (compressed) data = inflate(data)
        val json = runCatching { JSONObject(String(data, Charsets.UTF_8)) }
            .getOrElse { throw TransferException(TransferException.Kind.CORRUPTED) }
        val version = json.optInt("v", 1)
        if (version > CURRENT_VERSION) {
            throw TransferException(TransferException.Kind.UNSUPPORTED_VERSION, version)
        }
        return parse(json, version)
    }

    fun extractToken(input: String): String? {
        if (input.length > MAX_INPUT_CHARS) return null
        val text = compact(input)
        for (prefix in listOf(COMPRESSED_PREFIX, TEXT_PREFIX)) {
            val at = text.indexOf(prefix)
            if (at < 0) continue
            val body = text.substring(at + prefix.length).takeWhile(::isBase64Url)
            if (body.isNotEmpty()) return prefix + body
        }
        return null
    }

    private fun compact(input: String): String = input.filterNot { it.isWhitespace() }

    private fun parse(json: JSONObject, version: Int): TransferPayload {
        val asr = json.optJSONObject("a")?.let(::endpoint)
        val llm = json.optJSONObject("l")?.let(::endpoint)
        val asrProfiles = json.optJSONArray("as").toEndpoints()
        val llmProfiles = json.optJSONArray("ls").toEndpoints()
        val modes = json.optJSONArray("m").toModes()
        val hotwords = json.optJSONArray("h").toStrings()
        val snippets = json.optJSONArray("s").toSnippets()
        val textOutput = json.optJSONObject("o")?.let { output ->
            TransferTextOutput(
                cjkSpacing = output.optStringOrNull("s"),
                trailingPunctuation = output.optStringOrNull("p"),
                cornerQuotes = if (output.has("q")) output.optBoolean("q") else null,
            )
        }
        val source = json.optString("d").takeIf { it.isNotBlank() && it != "null" }
        if (asr == null && llm == null && asrProfiles.isEmpty() && llmProfiles.isEmpty() &&
            modes.isEmpty() && hotwords.isNullOrEmpty() && snippets.isNullOrEmpty()
        ) {
            throw TransferException(TransferException.Kind.EMPTY)
        }
        return TransferPayload(
            version = version,
            asr = asr,
            llm = llm,
            modes = modes,
            hotwords = hotwords,
            snippets = snippets,
            sourceName = source,
            asrProfiles = asrProfiles,
            llmProfiles = llmProfiles,
            textOutput = textOutput,
        )
    }

    private fun endpoint(json: JSONObject): TransferEndpoint {
        val fields = mutableMapOf<String, String>()
        val values = json.optJSONObject("f") ?: JSONObject()
        for (key in values.keys()) {
            if (values.isNull(key)) continue
            val value = values.optString(key)
            if (value.isNotEmpty()) fields[key] = value
        }
        return TransferEndpoint(json.optString("p"), fields)
    }

    private fun JSONArray?.toEndpoints(): List<TransferEndpoint> {
        if (this == null) return emptyList()
        return buildList {
            for (index in 0 until length()) {
                optJSONObject(index)?.let { add(endpoint(it)) }
            }
        }
    }

    private fun JSONArray?.toModes(): List<TransferMode> {
        if (this == null) return emptyList()
        return buildList {
            for (index in 0 until length()) {
                val item = optJSONObject(index) ?: continue
                val kind = item.optString("k")
                if (kind.isEmpty()) continue
                add(
                    TransferMode(
                        id = item.optString("i"),
                        kind = kind,
                        name = item.optStringOrNull("n"),
                        prompt = item.optStringOrNull("p"),
                        targetLanguage = item.optStringOrNull("g"),
                        punctuation = item.optStringOrNull("u"),
                        shortTextExemption = item.optInt("x", 0).takeIf { it > 0 },
                    ),
                )
            }
        }
    }

    private fun JSONArray?.toStrings(): List<String>? {
        if (this == null) return null
        return buildList {
            for (index in 0 until length()) {
                val value = optString(index).trim()
                if (value.isNotEmpty()) add(value)
            }
        }
    }

    private fun JSONArray?.toSnippets(): List<Snippet>? {
        if (this == null) return null
        return buildList {
            for (index in 0 until length()) {
                val item = optJSONObject(index) ?: continue
                val trigger = item.optString("t").trim()
                if (trigger.isEmpty()) continue
                add(Snippet(trigger, item.optString("r")))
            }
        }
    }

    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return optString(key).takeIf { it.isNotEmpty() && it != "null" }
    }

    private fun inflate(data: ByteArray): ByteArray {
        // Apple writes a raw DEFLATE stream; accept a zlib wrapper too so a
        // payload produced by another tool still decodes.
        return inflateWith(data, nowrap = true)
            ?: inflateWith(data, nowrap = false)
            ?: throw TransferException(TransferException.Kind.CORRUPTED)
    }

    private fun inflateWith(data: ByteArray, nowrap: Boolean): ByteArray? {
        val inflater = Inflater(nowrap)
        try {
            inflater.setInput(data)
            val capacity = minOf(data.size.toLong() * 3, MAX_INFLATED_BYTES.toLong()).toInt()
            val output = ByteArrayOutputStream(capacity)
            val buffer = ByteArray(8 * 1024)
            while (!inflater.finished()) {
                val read = runCatching { inflater.inflate(buffer) }.getOrElse { return null }
                if (read == 0) break
                // Stop as soon as the payload would pass the cap; a hostile
                // stream can otherwise inflate until the process runs out of memory.
                if (output.size() + read > MAX_INFLATED_BYTES) return null
                output.write(buffer, 0, read)
            }
            return output.toByteArray().takeIf { inflater.finished() }
        } finally {
            inflater.end()
        }
    }

    private fun base64UrlDecode(value: String): ByteArray? {
        if (value.isEmpty() || value.length > MAX_TOKEN_CHARS) return null
        var text = value.replace('-', '+').replace('_', '/')
        when (text.length % 4) {
            1 -> return null
            2 -> text += "=="
            3 -> text += "="
        }
        return runCatching { java.util.Base64.getDecoder().decode(text) }.getOrNull()
    }

    private fun isBase64Url(character: Char): Boolean =
        character in 'A'..'Z' || character in 'a'..'z' ||
            character in '0'..'9' || character == '-' || character == '_'
}

/** Collects the codes of one payload in any order and ignores repeats. */
class TransferAssembler {
    sealed interface Status {
        data object Ignored : Status
        data class Progress(val received: Set<Int>, val total: Int) : Status
        data class Complete(val payload: TransferPayload) : Status
        data class Failed(val error: TransferException) : Status
    }

    private var group: String? = null
    private var total = 0
    private val chunks = mutableMapOf<Int, String>()

    var received: Set<Int> = emptySet()
        private set

    fun reset() {
        group = null
        total = 0
        chunks.clear()
        received = emptySet()
    }

    fun add(scanned: String): Status {
        val part = TransferCodec.part(scanned)
        if (part == null) {
            if (TransferCodec.extractToken(scanned) == null) return Status.Ignored
            return runCatching { TransferCodec.decode(scanned) }.fold(
                onSuccess = { Status.Complete(it) },
                onFailure = { Status.Failed(it as? TransferException ?: TransferException(TransferException.Kind.CORRUPTED)) },
            )
        }
        if (part.group != group || part.total != total) {
            reset()
            group = part.group
            total = part.total
        }
        chunks[part.index] = part.chunk
        received = chunks.keys.toSet()
        if (chunks.size < total) return Status.Progress(received, total)
        val body = (1..total).mapNotNull { chunks[it] }.joinToString("")
        return runCatching { TransferCodec.decodeToken(TransferCodec.COMPRESSED_PREFIX + body) }.fold(
            onSuccess = { Status.Complete(it) },
            onFailure = {
                reset()
                Status.Failed(it as? TransferException ?: TransferException(TransferException.Kind.CORRUPTED))
            },
        )
    }
}
