// Copyright (c) 2026 DOTS
// Application-wide localized copy shared by the native core and SwiftUI shell.

import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case tr, en, de, es, fr, it, ja, ko, nl, pt, ru
    case zhHans = "zh-Hans"
    case ar, bn, hi, id, vi, ur, mr, te, ta, fa, pl, uk, th, ms, ro, el, cs, hu

    public var id: String { rawValue }

    public static var supported: [AppLanguage] {
        allCases.filter { $0 != .system }
    }

    public var localeIdentifier: String {
        switch self {
        case .system: return AppLocalization.effectiveLanguage.localeIdentifier
        case .tr: return "tr-TR"
        case .en: return "en-US"
        case .de: return "de-DE"
        case .es: return "es-ES"
        case .fr: return "fr-FR"
        case .it: return "it-IT"
        case .ja: return "ja-JP"
        case .ko: return "ko-KR"
        case .nl: return "nl-NL"
        case .pt: return "pt-PT"
        case .ru: return "ru-RU"
        case .zhHans: return "zh-CN"
        case .ar: return "ar-SA"
        case .bn: return "bn-BD"
        case .hi: return "hi-IN"
        case .id: return "id-ID"
        case .vi: return "vi-VN"
        case .ur: return "ur-PK"
        case .mr: return "mr-IN"
        case .te: return "te-IN"
        case .ta: return "ta-IN"
        case .fa: return "fa-IR"
        case .pl: return "pl-PL"
        case .uk: return "uk-UA"
        case .th: return "th-TH"
        case .ms: return "ms-MY"
        case .ro: return "ro-RO"
        case .el: return "el-GR"
        case .cs: return "cs-CZ"
        case .hu: return "hu-HU"
        }
    }

    public var nativeName: String {
        switch self {
        case .system: return "System language"
        case .tr: return "Türkçe"
        case .en: return "English"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .fr: return "Français"
        case .it: return "Italiano"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .nl: return "Nederlands"
        case .pt: return "Português"
        case .ru: return "Русский"
        case .zhHans: return "简体中文"
        case .ar: return "العربية"
        case .bn: return "বাংলা"
        case .hi: return "हिन्दी"
        case .id: return "Bahasa Indonesia"
        case .vi: return "Tiếng Việt"
        case .ur: return "اردو"
        case .mr: return "मराठी"
        case .te: return "తెలుగు"
        case .ta: return "தமிழ்"
        case .fa: return "فارسی"
        case .pl: return "Polski"
        case .uk: return "Українська"
        case .th: return "ไทย"
        case .ms: return "Bahasa Melayu"
        case .ro: return "Română"
        case .el: return "Ελληνικά"
        case .cs: return "Čeština"
        case .hu: return "Magyar"
        }
    }

    public var isRTL: Bool {
        switch self {
        case .ar, .ur, .fa: return true
        case .system: return AppLocalization.effectiveLanguage.isRTL
        default: return false
        }
    }

    public var flagEmoji: String {
        switch self {
        case .system: return AppLocalization.effectiveLanguage.flagEmoji
        case .tr: return "🇹🇷"
        case .en: return "🇺🇸"
        case .de: return "🇩🇪"
        case .es: return "🇪🇸"
        case .fr: return "🇫🇷"
        case .it: return "🇮🇹"
        case .ja: return "🇯🇵"
        case .ko: return "🇰🇷"
        case .nl: return "🇳🇱"
        case .pt: return "🇵🇹"
        case .ru: return "🇷🇺"
        case .zhHans: return "🇨🇳"
        case .ar: return "🇸🇦"
        case .bn: return "🇧🇩"
        case .hi, .mr, .te, .ta: return "🇮🇳"
        case .id: return "🇮🇩"
        case .vi: return "🇻🇳"
        case .ur: return "🇵🇰"
        case .fa: return "🇮🇷"
        case .pl: return "🇵🇱"
        case .uk: return "🇺🇦"
        case .th: return "🇹🇭"
        case .ms: return "🇲🇾"
        case .ro: return "🇷🇴"
        case .el: return "🇬🇷"
        case .cs: return "🇨🇿"
        case .hu: return "🇭🇺"
        }
    }

    public var shortCode: String {
        switch self {
        case .system: return AppLocalization.effectiveLanguage.shortCode
        case .zhHans: return "ZH"
        default: return rawValue.uppercased()
        }
    }
}

public enum AppLocalization {
    private static let lock = NSLock()
    // The lock protects this intentionally process-wide setting.
    nonisolated(unsafe) private static var selected: AppLanguage = .system

    public static var language: AppLanguage {
        lock.lock(); defer { lock.unlock() }
        return selected
    }

    public static var effectiveLanguage: AppLanguage {
        let current = language
        guard current == .system else { return current }
        for preferred in Locale.preferredLanguages {
            let identifier = preferred.replacingOccurrences(of: "_", with: "-").lowercased()
            if let match = AppLanguage.supported.first(where: { identifier == $0.rawValue.lowercased() || identifier.hasPrefix($0.rawValue.lowercased() + "-") }) {
                return match
            }
            if identifier.hasPrefix("zh-") { return .zhHans }
        }
        return .en
    }

    public static var locale: Locale { Locale(identifier: effectiveLanguage.localeIdentifier) }

    public static func setLanguage(_ value: AppLanguage) {
        lock.lock()
        selected = value
        lock.unlock()
    }

    fileprivate static func bundle(for language: AppLanguage) -> Bundle {
        let effective = language == .system ? effectiveLanguage : language
        let path = Bundle.module.path(forResource: effective.rawValue, ofType: "lproj")
            ?? Bundle.module.path(forResource: effective.rawValue.lowercased(), ofType: "lproj")
        guard let path,
              let bundle = Bundle(path: path) else {
            return Bundle.module
        }
        return bundle
    }
}

public enum AppCopy {
    public static var language: AppLanguage { AppLocalization.language }
    public static var effectiveLanguage: AppLanguage { AppLocalization.effectiveLanguage }
    public static var locale: Locale { AppLocalization.locale }

    public static func setLanguage(_ language: AppLanguage) {
        AppLocalization.setLanguage(language)
    }

    public static func text(_ key: String) -> String {
        let localized = AppLocalization.bundle(for: language).localizedString(forKey: key, value: nil, table: nil)
        if localized != key { return localized }
        let fallback = Bundle.module.localizedString(forKey: key, value: nil, table: nil)
        return fallback == key ? key : fallback
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}
