package com.type4me.android.asr

import com.type4me.android.audio.WavEncoder
import com.type4me.android.data.AsrConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.Base64
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Batch transcription for the providers that upload the whole recording when the user
 * stops speaking. Returns `null` for a provider this file does not handle.
 */
object PortableBatchC {
    private val JSON = "application/json; charset=utf-8".toMediaType()
    private val AUDIO_WAV = "audio/wav".toMediaType()

    private val client = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(180, TimeUnit.SECONDS)
        .writeTimeout(180, TimeUnit.SECONDS)
        .build()

    suspend fun transcribe(
        providerId: String,
        config: AsrConfig,
        pcm: ByteArray,
        hotwords: List<String>,
    ): String? = when (providerId) {
        "mimo" -> mimo(config, pcm)
        "bailian" -> bailian(config, pcm)
        "azure" -> azure(config, pcm, hotwords)
        "tencent" -> tencent(config, pcm, hotwords)
        "custom" -> custom(config, pcm)
        else -> null
    }

    // MARK: - Xiaomi MiMo

    private suspend fun mimo(config: AsrConfig, pcm: ByteArray): String = withContext(Dispatchers.IO) {
        requireAudio(pcm)
        val request = Request.Builder()
            .url(MiMoProtocol.endpoint(config))
            .header("api-key", config.apiKey.trim())
            .header("Accept", "text/event-stream")
            .post(MiMoProtocol.buildBody(config, WavEncoder.encode(pcm)).toString().toRequestBody(JSON))
            .build()

        client.newCall(request).execute().use { response ->
            val source = response.body?.source()
                ?: throw AsrException("Xiaomi MiMo returned an empty response")
            if (!response.isSuccessful) {
                val detail = MiMoProtocol.extractErrorMessage(source.readUtf8().take(1_024))
                throw AsrException(
                    "Xiaomi MiMo API HTTP ${response.code}" + if (detail.isNullOrBlank()) "" else ": $detail",
                )
            }
            val text = StringBuilder()
            var done = false
            while (!done) {
                val line = source.readUtf8Line() ?: break
                when (val event = MiMoProtocol.parseSseLine(line)) {
                    null -> Unit
                    is MiMoProtocol.Event.Delta -> text.append(event.text)
                    MiMoProtocol.Event.Done -> done = true
                    is MiMoProtocol.Event.Failure -> throw AsrException(event.message)
                }
            }
            val transcript = text.toString().trim()
            if (!done || transcript.isEmpty()) {
                throw AsrException("Xiaomi MiMo returned no transcription")
            }
            transcript
        }
    }

    // MARK: - Alibaba Cloud Bailian

    private suspend fun bailian(config: AsrConfig, pcm: ByteArray): String = withContext(Dispatchers.IO) {
        requireAudio(pcm)
        val settings = BailianProtocol.settings(config)
        val request = Request.Builder()
            .url(BailianProtocol.batchEndpoint(settings))
            .header("Authorization", "Bearer ${settings.apiKey}")
            .post(BailianProtocol.buildBatchBody(config, WavEncoder.encode(pcm)).toString().toRequestBody(JSON))
            .build()

        val (code, body) = call(request)
        if (code !in 200..299) {
            if (BailianProtocol.isNoSpeechBody(body)) return@withContext ""
            throw AsrException("Alibaba Cloud Bailian API HTTP $code" + detail(BailianProtocol.errorDetail(body)))
        }
        BailianProtocol.parseBatchResponse(body)
    }

    // MARK: - Microsoft Azure

    private suspend fun azure(config: AsrConfig, pcm: ByteArray, hotwords: List<String>): String =
        withContext(Dispatchers.IO) {
            requireAudio(pcm)
            val settings = AzureProtocol.settings(config)
            val boundary = "Type4Me-" + UUID.randomUUID()
            val multipart = MultipartBody.Builder(boundary)
                .setType(MultipartBody.FORM)
                .addFormDataPart("definition", AzureProtocol.batchDefinition(settings, hotwords).toString())
                .addFormDataPart("audio", "audio.wav", WavEncoder.encode(pcm).toRequestBody(AUDIO_WAV))
                .build()
            val request = Request.Builder()
                .url(AzureProtocol.batchUrl(settings))
                .header("Ocp-Apim-Subscription-Key", settings.apiKey)
                .post(multipart)
                .build()

            val (code, body) = call(request)
            if (code !in 200..299) {
                throw AsrException("Microsoft Azure API HTTP $code" + detail(AzureProtocol.errorDetail(body)))
            }
            AzureProtocol.parseBatchResponse(body)
        }

    // MARK: - Tencent Cloud

    private suspend fun tencent(config: AsrConfig, pcm: ByteArray, hotwords: List<String>): String =
        withContext(Dispatchers.IO) {
            requireAudio(pcm)
            val secretId = config.extra["secretId"].orEmpty().trim().ifBlank { config.apiKey.trim() }
            val secretKey = config.extra["secretKey"].orEmpty().trim()
            if (secretId.isBlank() || secretKey.isBlank()) {
                throw AsrException("Tencent Cloud SecretId and SecretKey are required")
            }

            val wav = WavEncoder.encode(pcm)
            val body = JSONObject()
                .put("EngineModelType", TencentProtocol.ENGINE_MODEL_TYPE)
                .put("ChannelNum", 1)
                .put("ResTextFormat", 0)
                .put("SourceType", 1)
                .put("Data", Base64.getEncoder().encodeToString(wav))
                .put("DataLen", wav.size)
                .put("ConvertNumMode", 1)
                .put("FilterDirty", 0)
                .put("FilterModal", 0)
                .put("FilterPunc", 0)
            TencentProtocol.formatHotwords(hotwords)?.let { body.put("HotwordList", it) }

            val create = signedRequest("CreateRecTask", body.toString().toByteArray(Charsets.UTF_8), secretId, secretKey)
            val (createCode, createBody) = call(create)
            if (createCode != 200) {
                throw AsrException("Tencent Cloud API HTTP $createCode")
            }
            tencentApiError(createBody)?.let {
                throw AsrException(TencentProtocol.apiErrorText(it.first, it.second))
            }
            val taskId = runCatching {
                JSONObject(createBody).getJSONObject("Response").getJSONObject("Data").optInt("TaskId", -1)
            }.getOrDefault(-1)
            if (taskId <= 0) {
                throw AsrException("Tencent Cloud returned an invalid transcription response")
            }

            val deadline = System.currentTimeMillis() + 90_000
            var pollCount = 0
            while (System.currentTimeMillis() <= deadline) {
                delay(
                    when (pollCount) {
                        0 -> 300L
                        1 -> 500L
                        2 -> 800L
                        else -> 1_000L
                    },
                )
                pollCount += 1

                val describe = signedRequest(
                    "DescribeTaskStatus",
                    JSONObject().put("TaskId", taskId).toString().toByteArray(Charsets.UTF_8),
                    secretId,
                    secretKey,
                )
                val (describeCode, describeBody) = call(describe)
                if (describeCode != 200) continue
                tencentApiError(describeBody)?.let {
                    throw AsrException(TencentProtocol.apiErrorText(it.first, it.second))
                }
                val data = runCatching {
                    JSONObject(describeBody).getJSONObject("Response").getJSONObject("Data")
                }.getOrNull() ?: continue
                when (data.optInt("Status", -1)) {
                    0, 1 -> Unit
                    2 -> return@withContext TencentProtocol.cleanResultText(data.optString("Result"))
                    3 -> throw AsrException(
                        TencentProtocol.apiErrorText("FailedOperation", data.optString("ErrorMsg")),
                    )
                    else -> Unit
                }
            }
            throw AsrException("The Tencent Cloud task timed out. Retry or switch to real-time mode.")
        }

    private fun signedRequest(
        action: String,
        payload: ByteArray,
        secretId: String,
        secretKey: String,
    ): Request {
        val signed = TencentCloudSigner.signedApiRequest(
            action = action,
            payload = payload,
            secretId = secretId,
            secretKey = secretKey,
            timestamp = System.currentTimeMillis() / 1000,
        )
        val builder = Request.Builder().url(signed.url)
        for ((name, value) in signed.headers) builder.header(name, value)
        return builder.post(signed.body.toRequestBody(JSON)).build()
    }

    private fun tencentApiError(body: String): Pair<String, String>? {
        val response = runCatching { JSONObject(body).optJSONObject("Response") }.getOrNull() ?: return null
        val error = response.optJSONObject("Error") ?: return null
        val code = error.optString("Code").takeIf { it.isNotBlank() } ?: return null
        return code to error.optString("Message")
    }

    // MARK: - Custom endpoint

    private suspend fun custom(config: AsrConfig, pcm: ByteArray): String = withContext(Dispatchers.IO) {
        requireAudio(pcm)
        val settings = CustomHttpProtocol.settings(config)
        val wav = WavEncoder.encode(pcm)
        val builder = Request.Builder().url(settings.endpoint)
        var contentType: String? = null
        for ((name, value) in settings.headers) {
            if (name.equals("Content-Type", ignoreCase = true)) contentType = value
            builder.header(name, value)
        }

        val request: Request
        if (settings.uploadFormat == CustomHttpProtocol.UPLOAD_MULTIPART) {
            if (CustomHttpProtocol.audioFieldKey(settings.template) == null) {
                throw AsrException(
                    "The body template has no ${CustomHttpProtocol.AUDIO_FILE_PLACEHOLDER} field, " +
                        "so the recording has nowhere to go",
                )
            }
            val fields = CustomHttpProtocol.substitute(
                settings.template,
                mapOf(CustomHttpProtocol.API_KEY_PLACEHOLDER to settings.apiKey),
            ) as JSONObject
            val boundary = "Type4Me-" + UUID.randomUUID()
            val body = CustomHttpProtocol.multipartBody(fields, settings.apiKey, wav, boundary)
            request = builder
                .header("Content-Type", "multipart/form-data; boundary=$boundary")
                .post(body.toRequestBody("multipart/form-data; boundary=$boundary".toMediaType()))
                .build()
        } else {
            if (!CustomHttpProtocol.contains(settings.template, CustomHttpProtocol.AUDIO_BASE64_PLACEHOLDER)) {
                throw AsrException(
                    "The body template has no ${CustomHttpProtocol.AUDIO_BASE64_PLACEHOLDER}, " +
                        "so the recording has nowhere to go",
                )
            }
            val body = CustomHttpProtocol.substitute(
                settings.template,
                mapOf(
                    CustomHttpProtocol.API_KEY_PLACEHOLDER to settings.apiKey,
                    CustomHttpProtocol.AUDIO_BASE64_PLACEHOLDER to Base64.getEncoder().encodeToString(wav),
                ),
            ) as JSONObject
            request = builder
                .header("Content-Type", contentType ?: "application/json")
                .post(body.toString().toRequestBody(JSON))
                .build()
        }

        val (code, body) = call(request)
        if (code !in 200..299) {
            if (CustomHttpProtocol.isNoSpeechBody(body)) return@withContext ""
            throw AsrException("Custom ASR HTTP $code: " + body.trim().take(200))
        }
        CustomHttpProtocol.parseTranscript(body, settings.resultPath)
    }

    // MARK: - Helpers

    private fun requireAudio(pcm: ByteArray) {
        if (pcm.isEmpty()) throw AsrException("No audio recorded")
    }

    private fun call(request: Request): Pair<Int, String> = client.newCall(request).execute().use { response ->
        response.code to (response.body?.string().orEmpty())
    }

    private fun detail(value: String?): String = if (value.isNullOrBlank()) "" else ": $value"
}
