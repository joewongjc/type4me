package com.type4me.android.asr

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class TencentCloudSignerTest {
    @Test
    fun websocketUrlMatchesTheHmacSha1SignatureOverThePlainQuery() {
        // Expected value computed independently with Python's hmac/hashlib for these inputs.
        val expected = "wss://asr.cloud.tencent.com/asr/v2/1250000000" +
            "?convert_num_mode=1&engine_model_type=16k_zh_en_2.0&expired=1700086400" +
            "&filter_dirty=0&filter_empty_result=1&filter_modal=0" +
            "&hotword_list=Type4Me%7C10%2C%E8%85%BE%E8%AE%AF%E4%BA%91%7C10" +
            "&needvad=1&nonce=12345678&secretid=AKIDEXAMPLE1234567890&sentence_strategy=0" +
            "&timestamp=1700000000&voice_format=1&voice_id=voice-123" +
            "&signature=5wPW6ZtfmNQ4ufy9cRJrMGNdHTc%3D"

        val url = TencentCloudSigner.signedWebSocketUrl(
            appId = "1250000000",
            secretId = "AKIDEXAMPLE1234567890",
            secretKey = "SECRETKEYEXAMPLE1234567890",
            parameters = TencentProtocol.liveParameters(listOf("Type4Me", "腾讯云")),
            timestamp = 1_700_000_000L,
            nonce = 12_345_678L,
            voiceId = "voice-123",
        )
        assertEquals(expected, url)
    }

    @Test
    fun tc3AuthorizationMatchesTheDocumentedDerivation() {
        // Expected signature computed independently with Python's hmac/hashlib for these inputs.
        val signed = TencentCloudSigner.signedApiRequest(
            action = "DescribeTaskStatus",
            payload = """{"TaskId":123456}""".toByteArray(Charsets.UTF_8),
            secretId = "AKIDEXAMPLE1234567890",
            secretKey = "SECRETKEYEXAMPLE1234567890",
            timestamp = 1_700_000_000L,
        )
        assertEquals("https://asr.tencentcloudapi.com", signed.url)
        assertEquals("DescribeTaskStatus", signed.headers["X-TC-Action"])
        assertEquals("2019-06-14", signed.headers["X-TC-Version"])
        assertEquals("1700000000", signed.headers["X-TC-Timestamp"])
        assertEquals("application/json; charset=utf-8", signed.headers["Content-Type"])
        assertEquals("asr.tencentcloudapi.com", signed.headers["Host"])
        assertEquals(
            "TC3-HMAC-SHA256 Credential=AKIDEXAMPLE1234567890/2023-11-14/asr/tc3_request, " +
                "SignedHeaders=content-type;host, " +
                "Signature=c7b8e096e797f290deaf41f25af08dab06cc02245ba256e1e2ddca5bce1160bb",
            signed.headers["Authorization"],
        )
        assertEquals(17, signed.body.size)
    }

    @Test
    fun signatureIsStableForRepeatedCalls() {
        val first = TencentCloudSigner.signedApiRequest(
            "CreateRecTask",
            """{"EngineModelType":"16k_zh_en_2.0"}""".toByteArray(),
            "AKID",
            "secret",
            1_700_000_000L,
        )
        val second = TencentCloudSigner.signedApiRequest(
            "CreateRecTask",
            """{"EngineModelType":"16k_zh_en_2.0"}""".toByteArray(),
            "AKID",
            "secret",
            1_700_000_000L,
        )
        assertEquals(first.headers["Authorization"], second.headers["Authorization"])
        // A different clock date must derive a different signing key.
        val later = TencentCloudSigner.signedApiRequest(
            "CreateRecTask",
            """{"EngineModelType":"16k_zh_en_2.0"}""".toByteArray(),
            "AKID",
            "secret",
            1_700_000_000L + 86_400 * 2,
        )
        assertEquals(false, first.headers["Authorization"] == later.headers["Authorization"])
    }

    @Test
    fun percentEncodingEscapesReservedCharacters() {
        assertEquals("a%20b%2F%2B%3D%26", TencentCloudSigner.percentEncode("a b/+=&"))
        assertEquals("Type4Me-1._~", TencentCloudSigner.percentEncode("Type4Me-1._~"))
        assertEquals("%E4%BD%A0%E5%A5%BD", TencentCloudSigner.percentEncode("你好"))
    }

    @Test
    fun missingCredentialsAreRejected() {
        assertThrows(AsrException::class.java) {
            TencentCloudSigner.signedWebSocketUrl(
                appId = "",
                secretId = "AKID",
                secretKey = "secret",
                parameters = emptyMap(),
                timestamp = 1_700_000_000L,
                nonce = 1L,
                voiceId = "v",
            )
        }
        assertThrows(AsrException::class.java) {
            TencentCloudSigner.signedApiRequest("CreateRecTask", ByteArray(0), "AKID", "", 1_700_000_000L)
        }
    }
}
