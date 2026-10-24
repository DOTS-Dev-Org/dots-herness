package com.dots.herness.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileProviderTest {
    @Test
    fun `provider catalog scopes models and credentials`() {
        assertEquals(listOf("anthropic", "openai", "openai-responses", "gpt"), MobileHarnessRuntime.PROVIDER_DEFINITIONS.map { it.id })
        assertEquals(MobileProviderDefinition.AuthKind.OAUTH, MobileHarnessRuntime.definition("gpt")?.authKind)
        assertTrue(MobileHarnessRuntime.modelsFor("openai").contains("gpt-5.6-luna"))
        assertFalse(MobileHarnessRuntime.modelsFor("anthropic").contains("gpt-5.6-luna"))
        assertNull(MobileHarnessRuntime.definition("unknown"))
        assertEquals("phone.provider.openai", MobileHarnessRuntime.credentialKey("openai"))
        assertEquals("keystore:oauth.openai.accounts", MobileHarnessRuntime.credentialReference("gpt"))
    }
}
