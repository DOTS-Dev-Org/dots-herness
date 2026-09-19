package com.dots.herness.mobile

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileLocalizationTest {
    @Test
    fun `contains the thirty concrete macOS locales`() {
        assertEquals(30, MobileLanguages.supported.size)
        assertEquals("zh-Hans", MobileLanguages.fromDevice(listOf(Locale.forLanguageTag("zh-TW"))).code)
        assertEquals("ar", MobileLanguages.fromDevice(listOf(Locale.forLanguageTag("ar-EG"))).code)
        assertEquals("en", MobileLanguages.fromDevice(listOf(Locale.forLanguageTag("xx"))).code)
    }

    @Test
    fun `system and rtl behavior are explicit`() {
        // `effective()` reads Android's process LocaleList and is covered by the
        // UI/runtime path; keep this JVM unit test on the pure locale mapping.
        assertEquals("fa", MobileLanguages.fromCode("fa").code)
        assertTrue(MobileLanguages.fromCode("ur").isRtl)
        assertFalse(MobileLanguages.fromCode("tr").isRtl)
        assertTrue(MobileIntroNavigation.canSkip(0, 3))
        assertTrue(MobileIntroNavigation.canSkip(1, 3))
        assertFalse(MobileIntroNavigation.canSkip(2, 3))
        assertFalse(MobileIntroNavigation.showsBack(0))
        assertTrue(MobileIntroNavigation.showsBack(1))
        assertEquals("intro_start", MobileIntroNavigation.primaryKey(2, 3))
    }
}
