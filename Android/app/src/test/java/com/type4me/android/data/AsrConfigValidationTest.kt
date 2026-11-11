package com.type4me.android.data

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AsrConfigValidationTest {
    @Test
    fun bailianInternationalKeyCountsAsACredential() {
        val config = AsrConfig(
            kind = AsrKind.STREAMING,
            providerId = "bailian",
            extra = mapOf("region" to "international", "intlApiKey" to "sk-intl"),
        )
        assertTrue(config.isValid)
    }

    @Test
    fun bailianWithoutAnyCredentialIsIncomplete() {
        val config = AsrConfig(
            kind = AsrKind.STREAMING,
            providerId = "bailian",
            extra = mapOf("region" to "international"),
        )
        assertFalse(config.isValid)
    }
}
