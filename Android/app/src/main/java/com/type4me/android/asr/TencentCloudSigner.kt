package com.type4me.android.asr

import java.time.Instant
import java.time.ZoneOffset
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Tencent Cloud request signing: HMAC-SHA1 query signing for the Realtime V2 WebSocket
 * and TC3-HMAC-SHA256 headers for the ASR API 3.0 actions (CreateRecTask, DescribeTaskStatus).
 */
object TencentCloudSigner {
    const val WS_SIGN_HOST = TencentProtocol.WS_HOST
    const val API_HOST = TencentProtocol.API_HOST
    const val API_VERSION = TencentProtocol.API_VERSION

    data class SignedRequest(val url: String, val headers: Map<String, String>, val body: ByteArray)

    fun signedWebSocketUrl(
        appId: String,
        secretId: String,
        secretKey: String,
        parameters: Map<String, String>,
        timestamp: Long,
        expiresIn: Int = 86_400,
        nonce: Long,
        voiceId: String,
    ): String {
        if (appId.isBlank() || secretId.isBlank() || secretKey.isBlank()) {
            throw AsrException("Tencent Cloud AppID, SecretId and SecretKey are required")
        }
        val query = LinkedHashMap(parameters)
        query["secretid"] = secretId
        query["timestamp"] = timestamp.toString()
        query["expired"] = (timestamp + expiresIn).toString()
        query["nonce"] = nonce.toString()
        query["voice_id"] = voiceId

        val keys = query.keys.sorted()
        val plainQuery = keys.joinToString("&") { "$it=${query.getValue(it)}" }
        val path = TencentProtocol.WS_PATH_PREFIX + appId
        val signature = base64(hmacSha1(secretKey.toByteArray(Charsets.UTF_8), "$WS_SIGN_HOST$path?$plainQuery".toByteArray(Charsets.UTF_8)))

        val encodedQuery = keys.joinToString("&") { "$it=${percentEncode(query.getValue(it))}" }
        return "wss://$WS_SIGN_HOST$path?$encodedQuery&signature=${percentEncode(signature)}"
    }

    fun signedApiRequest(
        action: String,
        payload: ByteArray,
        secretId: String,
        secretKey: String,
        timestamp: Long,
    ): SignedRequest {
        if (secretId.isBlank() || secretKey.isBlank()) {
            throw AsrException("Tencent Cloud SecretId and SecretKey are required")
        }
        val host = API_HOST
        val service = TencentProtocol.API_SERVICE
        val date = Instant.ofEpochSecond(timestamp).atZone(ZoneOffset.UTC).toLocalDate().toString()

        val canonicalHeaders = "content-type:application/json; charset=utf-8\nhost:$host\n"
        val signedHeaders = "content-type;host"
        val canonicalRequest = listOf(
            "POST",
            "/",
            "",
            canonicalHeaders,
            signedHeaders,
            sha256Hex(payload),
        ).joinToString("\n")

        val credentialScope = "$date/$service/tc3_request"
        val stringToSign = "TC3-HMAC-SHA256\n$timestamp\n$credentialScope\n" +
            sha256Hex(canonicalRequest.toByteArray(Charsets.UTF_8))

        val secretDate = hmacSha256(("TC3$secretKey").toByteArray(Charsets.UTF_8), date.toByteArray(Charsets.UTF_8))
        val secretService = hmacSha256(secretDate, service.toByteArray(Charsets.UTF_8))
        val secretSigning = hmacSha256(secretService, "tc3_request".toByteArray(Charsets.UTF_8))
        val signature = hex(hmacSha256(secretSigning, stringToSign.toByteArray(Charsets.UTF_8)))

        val authorization =
            "TC3-HMAC-SHA256 Credential=$secretId/$credentialScope, " +
                "SignedHeaders=$signedHeaders, Signature=$signature"

        return SignedRequest(
            url = "https://$host",
            headers = linkedMapOf(
                "Content-Type" to "application/json; charset=utf-8",
                "Host" to host,
                "X-TC-Action" to action,
                "X-TC-Version" to API_VERSION,
                "X-TC-Timestamp" to timestamp.toString(),
                "Authorization" to authorization,
            ),
            body = payload,
        )
    }

    /** Percent-encodes everything outside RFC 3986 unreserved characters. */
    fun percentEncode(value: String): String {
        val builder = StringBuilder()
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            val char = (byte.toInt() and 0xFF).toChar()
            if (char in 'A'..'Z' || char in 'a'..'z' || char in '0'..'9' ||
                char == '-' || char == '.' || char == '_' || char == '~'
            ) {
                builder.append(char)
            } else {
                builder.append('%')
                    .append(HEX_UPPER[(byte.toInt() shr 4) and 0x0F])
                    .append(HEX_UPPER[byte.toInt() and 0x0F])
            }
        }
        return builder.toString()
    }

    private fun base64(data: ByteArray): String = Base64.getEncoder().encodeToString(data)

    private fun hmacSha1(key: ByteArray, data: ByteArray): ByteArray = mac("HmacSHA1", key, data)

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray = mac("HmacSHA256", key, data)

    private fun mac(algorithm: String, key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance(algorithm)
        mac.init(SecretKeySpec(key, algorithm))
        return mac.doFinal(data)
    }

    private fun sha256Hex(data: ByteArray): String = hex(java.security.MessageDigest.getInstance("SHA-256").digest(data))

    private fun hex(data: ByteArray): String {
        val builder = StringBuilder(data.size * 2)
        for (byte in data) {
            val value = byte.toInt() and 0xFF
            builder.append(HEX[value shr 4]).append(HEX[value and 0x0F])
        }
        return builder.toString()
    }

    private const val HEX = "0123456789abcdef"
    private const val HEX_UPPER = "0123456789ABCDEF"
}
