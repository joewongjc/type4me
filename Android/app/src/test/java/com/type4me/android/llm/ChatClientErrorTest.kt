package com.type4me.android.llm

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class ChatClientErrorTest {
    private val client = ChatClient()

    @Test
    fun keepsOnlyTheStatusAndRedactedProviderMessage() {
        val body = """{"error":{"message":"Invalid Bearer sk-secret-token-12345"},"choices":[]}"""
        val message = client.errorMessage(401, body)
        assertEquals("HTTP 401: Invalid Bearer [REDACTED]", message)
        assertFalse(message.contains("sk-secret-token-12345"))
        assertFalse(message.contains("choices"))
    }

    @Test
    fun dropsRawBodiesAndRedactsNamedCredentials() {
        val message = client.errorMessage(
            403,
            """{"error":{"message":"api_key=sk-abcdefghijklmnop denied"}}""",
        )
        assertEquals("HTTP 403: api_key=[REDACTED] denied", message)
        assertEquals("HTTP 500", client.errorMessage(500, "<html>raw body</html>"))
    }
}
