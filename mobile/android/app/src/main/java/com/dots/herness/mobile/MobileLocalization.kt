package com.dots.herness.mobile

import android.content.Context
import android.content.SharedPreferences
import android.content.res.Configuration
import android.os.LocaleList
import java.util.Locale

data class MobileLanguage(
    val code: String,
    val localeTag: String,
    val nativeName: String,
    val flag: String,
    val isRtl: Boolean,
) {
    val shortCode: String get() = if (code == "system") "AUTO" else if (code == "zh-Hans") "ZH" else code.uppercase(Locale.ROOT)
}

object MobileLanguages {
    val system = MobileLanguage("system", "system", "System language", "🌐", false)

    // Keep this order identical to macOS AppLanguage and the shared JSON manifest.
    val supported = listOf(
        MobileLanguage("tr", "tr-TR", "Türkçe", "🇹🇷", false),
        MobileLanguage("en", "en-US", "English", "🇺🇸", false),
        MobileLanguage("de", "de-DE", "Deutsch", "🇩🇪", false),
        MobileLanguage("es", "es-ES", "Español", "🇪🇸", false),
        MobileLanguage("fr", "fr-FR", "Français", "🇫🇷", false),
        MobileLanguage("it", "it-IT", "Italiano", "🇮🇹", false),
        MobileLanguage("ja", "ja-JP", "日本語", "🇯🇵", false),
        MobileLanguage("ko", "ko-KR", "한국어", "🇰🇷", false),
        MobileLanguage("nl", "nl-NL", "Nederlands", "🇳🇱", false),
        MobileLanguage("pt", "pt-PT", "Português", "🇵🇹", false),
        MobileLanguage("ru", "ru-RU", "Русский", "🇷🇺", false),
        MobileLanguage("zh-Hans", "zh-CN", "简体中文", "🇨🇳", false),
        MobileLanguage("ar", "ar-SA", "العربية", "🇸🇦", true),
        MobileLanguage("bn", "bn-BD", "বাংলা", "🇧🇩", false),
        MobileLanguage("hi", "hi-IN", "हिन्दी", "🇮🇳", false),
        MobileLanguage("id", "id-ID", "Bahasa Indonesia", "🇮🇩", false),
        MobileLanguage("vi", "vi-VN", "Tiếng Việt", "🇻🇳", false),
        MobileLanguage("ur", "ur-PK", "اردو", "🇵🇰", true),
        MobileLanguage("mr", "mr-IN", "मराठी", "🇮🇳", false),
        MobileLanguage("te", "te-IN", "తెలుగు", "🇮🇳", false),
        MobileLanguage("ta", "ta-IN", "தமிழ்", "🇮🇳", false),
        MobileLanguage("fa", "fa-IR", "فارسی", "🇮🇷", true),
        MobileLanguage("pl", "pl-PL", "Polski", "🇵🇱", false),
        MobileLanguage("uk", "uk-UA", "Українська", "🇺🇦", false),
        MobileLanguage("th", "th-TH", "ไทย", "🇹🇭", false),
        MobileLanguage("ms", "ms-MY", "Bahasa Melayu", "🇲🇾", false),
        MobileLanguage("ro", "ro-RO", "Română", "🇷🇴", false),
        MobileLanguage("el", "el-GR", "Ελληνικά", "🇬🇷", false),
        MobileLanguage("cs", "cs-CZ", "Čeština", "🇨🇿", false),
        MobileLanguage("hu", "hu-HU", "Magyar", "🇭🇺", false),
    )

    val all: List<MobileLanguage> = listOf(system) + supported

    fun fromCode(code: String?): MobileLanguage = all.firstOrNull { it.code == code } ?: system

    fun fromDevice(locales: LocaleList = LocaleList.getDefault()): MobileLanguage {
        return fromDevice((0 until locales.size()).map { locales[it] })
    }

    fun fromDevice(locales: List<Locale>): MobileLanguage {
        for (locale in locales) {
            val language = locale.toLanguageTag().replace('_', '-').lowercase(Locale.ROOT)
            if (language == "zh" || language.startsWith("zh-")) return fromCode("zh-Hans")
            supported.firstOrNull { code -> language == code.code.lowercase(Locale.ROOT) || language.startsWith(code.code.lowercase(Locale.ROOT) + "-") }
                ?.let { return it }
        }
        return fromCode("en")
    }

    fun effective(selected: MobileLanguage, locales: LocaleList = LocaleList.getDefault()): MobileLanguage =
        if (selected.code == system.code) fromDevice(locales) else selected
}

object MobileIntroNavigation {
    fun canSkip(page: Int, pageCount: Int): Boolean = page < pageCount - 1
    fun showsBack(page: Int): Boolean = page > 0
    fun primaryKey(page: Int, pageCount: Int): String = if (page == pageCount - 1) "intro_start" else "intro_continue"
}

fun SharedPreferences.mobileLanguage(): MobileLanguage = MobileLanguages.fromCode(getString(MOBILE_LANGUAGE_KEY, "system"))

fun SharedPreferences.setMobileLanguage(language: MobileLanguage) {
    edit().putString(MOBILE_LANGUAGE_KEY, language.code).apply()
}

/**
 * Android resource lookup is tied to a Context.  A copied Configuration keeps
 * the app's current resources intact while Compose renders through the
 * selected locale context.
 */
fun Context.createMobileLocaleContext(language: MobileLanguage): Context {
    if (language.code == "system") return this
    val configuration = Configuration(resources.configuration)
    configuration.setLocale(Locale.forLanguageTag(language.localeTag))
    configuration.setLayoutDirection(Locale.forLanguageTag(language.localeTag))
    return createConfigurationContext(configuration)
}
