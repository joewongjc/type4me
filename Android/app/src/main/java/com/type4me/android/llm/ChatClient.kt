package com.type4me.android.llm

import com.type4me.android.data.LlmConfig
import com.type4me.android.pipeline.Prompts
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

class ChatException(message: String) : Exception(message)

/**
 * OpenAI-compatible `/chat/completions`, plus Anthropic's `/messages` for
 * Claude. Thinking-off fields follow each provider's own API.
 */
class ChatClient(
    private val client: OkHttpClient = defaultClient,
) {
    suspend fun complete(
        config: LlmConfig,
        request: Prompts.Request,
        maxTokens: Int = 2_400,
    ): String = withContext(Dispatchers.IO) {
        if (config.providerId == "claude") {
            completeMessages(config, request, maxTokens)
        } else {
            completeChat(config, request, maxTokens)
        }
    }

    /** A tiny round trip for the Test button. */
    suspend fun test(config: LlmConfig): Long {
        val started = System.currentTimeMillis()
        complete(
            config = config,
            request = Prompts.Request(system = null, user = "Reply with OK."),
            maxTokens = 8,
        )
        return System.currentTimeMillis() - started
    }

    private fun completeChat(
        config: LlmConfig,
        request: Prompts.Request,
        maxTokens: Int,
    ): String {
        val messages = JSONArray()
        if (!request.system.isNullOrBlank()) {
            messages.put(JSONObject().put("role", "system").put("content", request.system))
        }
        messages.put(JSONObject().put("role", "user").put("content", request.user))

        val body = JSONObject()
            .put("model", config.model)
            .put("messages", messages)
            .put("stream", false)
            .put(maxTokensField(config.providerId, config.model), maxTokens)

        var effort = config.reasoningEffort?.takeIf { it.isNotBlank() }
        val thinkingField = if (config.disableThinking) {
            ThinkingPolicy.fieldFor(config.providerId, config.model)
        } else {
            null
        }
        when (thinkingField) {
            ThinkingField.THINKING -> body.put("thinking", JSONObject().put("type", "disabled"))
            ThinkingField.ENABLE_THINKING -> body.put("enable_thinking", false)
            ThinkingField.REASONING -> body.put("reasoning", JSONObject().put("effort", "none"))
            ThinkingField.REASONING_EFFORT -> effort = "none"
            ThinkingField.THINK -> body.put("think", false)
            null -> Unit
        }
        effort?.let { body.put("reasoning_effort", it) }
        if (config.reasoningSplit) body.put("reasoning_split", true)

        val httpRequest = Request.Builder()
            .url(endpoint(config.baseUrl, "/chat/completions"))
            .post(body.toString().toRequestBody(JSON))
            .apply {
                if (config.apiKey.isNotBlank()) {
                    header("Authorization", "Bearer ${config.apiKey}")
                }
            }
            .build()
        client.newCall(httpRequest).execute().use { response ->
            val text = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw ChatException(errorMessage(response.code, text))
            return ChatResponse.text(text)
        }
    }

    /** Anthropic Messages API, the same shape the Mac's Claude client sends. */
    private fun completeMessages(
        config: LlmConfig,
        request: Prompts.Request,
        maxTokens: Int,
    ): String {
        val body = JSONObject()
            .put("model", config.model)
            .put("max_tokens", maxTokens)
            .put("messages", JSONArray().put(JSONObject().put("role", "user").put("content", request.user)))
        if (!request.system.isNullOrBlank()) body.put("system", request.system)
        if (config.disableThinking) {
            ThinkingPolicy.claudeOffType(config.model)?.let { type ->
                body.put("thinking", JSONObject().put("type", type))
            }
        }
        val httpRequest = Request.Builder()
            .url(endpoint(config.baseUrl, "/messages"))
            .post(body.toString().toRequestBody(JSON))
            .header("x-api-key", config.apiKey)
            .header("anthropic-version", "2023-06-01")
            .build()
        client.newCall(httpRequest).execute().use { response ->
            val text = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw ChatException(errorMessage(response.code, text))
            val json = runCatching { JSONObject(text) }
                .getOrElse { throw ChatException("Could not parse the text model response") }
            val blocks = json.optJSONArray("content") ?: JSONArray()
            val content = buildString {
                for (index in 0 until blocks.length()) {
                    val block = blocks.optJSONObject(index) ?: continue
                    if (block.optString("type") == "text") append(block.optString("text"))
                }
            }
            val cleaned = ChatResponse.clean(content)
            if (cleaned.isBlank()) throw ChatException("The text model returned nothing")
            return cleaned
        }
    }

    private fun endpoint(baseUrl: String, path: String): String {
        val trimmed = baseUrl.trim().trimEnd('/')
        if (trimmed.isEmpty()) throw ChatException("Text model URL is empty")
        if (trimmed.endsWith(path)) return trimmed
        return trimmed + path
    }

    private fun errorMessage(code: Int, body: String): String {
        val json = runCatching { JSONObject(body) }.getOrNull()
        val detail = json?.optJSONObject("error")?.optString("message")?.takeIf { it.isNotBlank() }
            ?: json?.optString("message")?.takeIf { it.isNotBlank() }
            ?: body.take(160).takeIf { it.isNotBlank() }
        return "HTTP $code" + (detail?.let { ": $it" } ?: "")
    }

    companion object {
        private val JSON = "application/json; charset=utf-8".toMediaType()

        /** OpenAI's reasoning families reject `max_tokens`. */
        private val maxCompletionTokensModels = listOf("gpt-5", "gpt-6", "o1", "o3", "o4")

        internal fun maxTokensField(providerId: String, model: String): String {
            if (providerId.trim().lowercase() != "openai") return "max_tokens"
            val name = model.trim().lowercase()
            return if (maxCompletionTokensModels.any { name.startsWith(it) }) {
                "max_completion_tokens"
            } else {
                "max_tokens"
            }
        }

        private val defaultClient = OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(90, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .build()
    }
}

object ChatResponse {
    private val reasoningTags = listOf("think", "thinking", "reasoning")

    fun text(body: String): String {
        if (body.isBlank()) throw ChatException("The text model returned an empty response")
        val json = runCatching { JSONObject(body) }
            .getOrElse { throw ChatException("Could not parse the text model response") }
        val choice = json.optJSONArray("choices")?.optJSONObject(0)
        val message = choice?.optJSONObject("message")
        val messageText = if (message == null || message.isNull("content")) {
            ""
        } else {
            message.optString("content")
        }
        val completionText = if (choice == null || choice.isNull("text")) {
            ""
        } else {
            choice.optString("text")
        }
        val content = messageText.ifBlank { completionText }
        val cleaned = clean(content)
        if (cleaned.isBlank()) throw ChatException("The text model returned nothing")
        return cleaned
    }

    fun clean(text: String): String {
        var withoutBlocks = text
        for (tag in reasoningTags) {
            withoutBlocks = withoutBlocks.replace(Regex("(?s)<$tag>.*?</$tag>"), "")
        }
        // Some models emit an unclosed reasoning prefix before the answer.
        val closing = reasoningTags
            .map { tag -> "</$tag>" to withoutBlocks.indexOf("</$tag>") }
            .filter { it.second >= 0 }
            .minByOrNull { it.second }
        val answer = if (closing != null) {
            withoutBlocks.substring(closing.second + closing.first.length)
        } else {
            withoutBlocks
        }
        return stripOuterQuotes(answer.trim()).trim()
    }

    private fun stripOuterQuotes(text: String): String {
        if (text.length < 2) return text
        val pairs = listOf('"' to '"', '“' to '”', '「' to '」', '\'' to '\'')
        for ((open, close) in pairs) {
            if (text.first() == open && text.last() == close) {
                return text.substring(1, text.length - 1).trim()
            }
        }
        return text
    }
}
