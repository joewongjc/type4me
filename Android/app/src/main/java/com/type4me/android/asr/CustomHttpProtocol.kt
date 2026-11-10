package com.type4me.android.asr

import com.type4me.android.data.AsrConfig
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * User-described HTTP batch endpoint: headers, a JSON or multipart body template, and the
 * dotted path where the transcript sits in the response.
 */
object CustomHttpProtocol {
    const val API_KEY_PLACEHOLDER = "{{api_key}}"
    const val AUDIO_BASE64_PLACEHOLDER = "{{audio_base64}}"
    const val AUDIO_FILE_PLACEHOLDER = "{{audio_file}}"
    const val DEFAULT_RESULT_PATH = "text"
    /** Upstream codes that only mean "no speech", e.g. Volcano 20000003 relayed by a gateway. */
    val NO_SPEECH_MARKERS = listOf("20000003", "ASR_RESPONSE_HAVE_NO_WORDS")

    const val UPLOAD_JSON = "json"
    const val UPLOAD_MULTIPART = "multipart"

    data class Settings(
        val endpoint: String,
        val apiKey: String,
        val uploadFormat: String,
        val headers: List<Pair<String, String>>,
        val template: JSONObject,
        val resultPath: String,
    )

    fun settings(config: AsrConfig): Settings {
        val endpoint = config.baseUrl.trim()
        if (!endpoint.startsWith("http://") && !endpoint.startsWith("https://")) {
            throw AsrException("Invalid endpoint URL; it must start with http:// or https://")
        }
        val templateText = config.extra["bodyTemplate"].orEmpty().trim()
        if (templateText.isEmpty()) {
            throw AsrException("The custom ASR body template is empty")
        }
        val apiKey = config.apiKey.trim()
        return Settings(
            endpoint = endpoint,
            apiKey = apiKey,
            uploadFormat = config.extra["uploadFormat"].orEmpty().trim()
                .ifBlank { UPLOAD_JSON }
                .let { if (it == UPLOAD_MULTIPART) UPLOAD_MULTIPART else UPLOAD_JSON },
            headers = parseHeaders(config.extra["headers"].orEmpty(), apiKey),
            template = parseTemplate(templateText)
                ?: throw AsrException("""The body template must be a JSON object, e.g. {"audio": "{{audio_base64}}"}"""),
            resultPath = config.extra["resultPath"].orEmpty().trim().ifBlank { DEFAULT_RESULT_PATH },
        )
    }

    /** One `Name: value` per line; with no header lines and an API key, sends Bearer auth. */
    fun parseHeaders(text: String, apiKey: String): List<Pair<String, String>> {
        val headers = mutableListOf<Pair<String, String>>()
        text.split('\n').forEachIndexed { index, rawLine ->
            val line = rawLine.trim()
            if (line.isEmpty()) return@forEachIndexed
            val colon = line.indexOf(':')
            if (colon <= 0) {
                throw AsrException("Header line ${index + 1} must look like \"Name: value\"")
            }
            val name = line.substring(0, colon).trim()
            if (name.isEmpty() || name.any { it.isWhitespace() }) {
                throw AsrException("Header line ${index + 1} must look like \"Name: value\"")
            }
            val value = line.substring(colon + 1).trim().replace(API_KEY_PLACEHOLDER, apiKey)
            headers.add(name to value)
        }
        if (headers.isEmpty() && apiKey.isNotEmpty()) {
            headers.add("Authorization" to "Bearer $apiKey")
        }
        return headers
    }

    /** Accepts curly quotes from rich-text sources when the template is otherwise invalid JSON. */
    fun parseTemplate(text: String): JSONObject? {
        val normalized = text.replace('\u201C', '"').replace('\u201D', '"')
        for (candidate in listOf(text, normalized)) {
            val parsed = runCatching { JSONObject(candidate) }.getOrNull()
            if (parsed != null) return parsed
        }
        return null
    }

    fun resultPath(config: AsrConfig): String =
        config.extra["resultPath"].orEmpty().trim().ifBlank { DEFAULT_RESULT_PATH }

    fun contains(node: Any?, placeholder: String): Boolean = when (node) {
        is String -> node.contains(placeholder)
        is JSONObject -> node.keys().asSequence().any { contains(node.opt(it), placeholder) }
        is JSONArray -> (0 until node.length()).any { contains(node.opt(it), placeholder) }
        else -> false
    }

    /** Replaces placeholders in every string, leaving numbers and booleans untouched. */
    fun substitute(node: Any?, replacements: Map<String, String>): Any? = when (node) {
        is String -> replacements.entries.fold(node) { text, entry -> text.replace(entry.key, entry.value) }
        is JSONObject -> {
            val result = JSONObject()
            for (key in node.keys()) {
                result.put(key, substitute(node.opt(key), replacements) ?: JSONObject.NULL)
            }
            result
        }
        is JSONArray -> {
            val result = JSONArray()
            for (index in 0 until node.length()) {
                result.put(substitute(node.opt(index), replacements) ?: JSONObject.NULL)
            }
            result
        }
        null -> JSONObject.NULL
        else -> node
    }

    fun audioFieldKey(fields: JSONObject): String? =
        fields.keys().asSequence().firstOrNull { fields.opt(it) == AUDIO_FILE_PLACEHOLDER }

    fun multipartBody(fields: JSONObject, apiKey: String, wav: ByteArray, boundary: String): ByteArray {
        val out = ByteArrayOutputStream()
        for (key in fields.keys().asSequence().sorted().toList()) {
            out.write("--$boundary\r\n".toByteArray(Charsets.UTF_8))
            val value = fields.opt(key)
            if (value == AUDIO_FILE_PLACEHOLDER) {
                out.write("Content-Disposition: form-data; name=\"$key\"; filename=\"audio.wav\"\r\n".toByteArray(Charsets.UTF_8))
                out.write("Content-Type: audio/wav\r\n\r\n".toByteArray(Charsets.UTF_8))
                out.write(wav)
            } else {
                val text = formValue(substitute(value, mapOf(API_KEY_PLACEHOLDER to apiKey)))
                out.write("Content-Disposition: form-data; name=\"$key\"\r\n\r\n".toByteArray(Charsets.UTF_8))
                out.write(text.toByteArray(Charsets.UTF_8))
            }
            out.write("\r\n".toByteArray(Charsets.UTF_8))
        }
        out.write("--$boundary--\r\n".toByteArray(Charsets.UTF_8))
        return out.toByteArray()
    }

    fun formValue(node: Any?): String = when (node) {
        null, JSONObject.NULL -> ""
        is String -> node
        else -> node.toString()
    }

    /** Resolves dotted paths with array indexes, e.g. `results[0].alternatives[0].transcript`. */
    fun valueAt(path: String, root: Any?): Any? {
        var current: Any? = root
        for (component in path.split('.')) {
            var name = component
            val indexes = mutableListOf<Int>()
            while (name.endsWith("]")) {
                val open = name.lastIndexOf('[')
                if (open < 0) return null
                val index = name.substring(open + 1, name.length - 1).toIntOrNull() ?: return null
                indexes.add(0, index)
                name = name.substring(0, open)
            }
            if (name.isNotEmpty()) {
                val json = current as? JSONObject ?: return null
                current = json.opt(name)
            }
            for (index in indexes) {
                val array = current as? JSONArray ?: return null
                if (index < 0 || index >= array.length()) return null
                current = array.opt(index)
            }
        }
        return current
    }

    fun parseTranscript(body: String, resultPath: String): String {
        val root = runCatching { JSONObject(body) }.getOrElse {
            throw AsrException("Could not parse the custom ASR response")
        }
        val text = valueAt(resultPath, root) as? String
            ?: throw AsrException(
                "Result field $resultPath not found in the response: " + body.take(200),
            )
        return text.trim()
    }

    fun isNoSpeechBody(body: String): Boolean = NO_SPEECH_MARKERS.any { body.contains(it) }
}
