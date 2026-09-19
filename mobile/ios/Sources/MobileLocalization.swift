import Foundation
import SwiftUI

/// The mobile language list mirrors macOS AppLanguage.  `system` is a
/// selection mode; the other 30 entries are concrete resource locales.
enum MobileLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case tr, en, de, es, fr, it, ja, ko, nl, pt, ru
    case zhHans = "zh-Hans"
    case ar, bn, hi, id, vi, ur, mr, te, ta, fa, pl, uk, th, ms, ro, el, cs, hu

    var id: String { rawValue }

    static var supported: [MobileLanguage] {
        allCases.filter { $0 != .system }
    }

    var localeIdentifier: String {
        switch self {
        case .system: return MobileLanguage.from(preferredIdentifier: Locale.preferredLanguages.first ?? "en").localeIdentifier
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

    var nativeName: String {
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

    var flagEmoji: String {
        switch self {
        case .system: return "🌐"
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

    var isRTL: Bool {
        switch self {
        case .ar, .ur, .fa: return true
        case .system: return MobileLanguage.from(preferredIdentifier: Locale.preferredLanguages.first ?? "en").isRTL
        default: return false
        }
    }

    var shortCode: String {
        switch self {
        case .system: return "AUTO"
        case .zhHans: return "ZH"
        default: return rawValue.uppercased()
        }
    }

    static func from(preferredIdentifier identifier: String) -> MobileLanguage {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized.hasPrefix("zh-") || normalized == "zh" { return .zhHans }
        return supported.first {
            let code = $0.rawValue.lowercased()
            return normalized == code || normalized.hasPrefix(code + "-")
        } ?? .en
    }

    static func stored(_ rawValue: String?) -> MobileLanguage {
        guard let rawValue, let value = MobileLanguage(rawValue: rawValue) else { return .system }
        return value
    }
}

@MainActor
final class MobileLocalization: ObservableObject {
    static let storageKey = "mobile.language"

    @Published private(set) var selected: MobileLanguage {
        didSet { defaults.set(selected.rawValue, forKey: Self.storageKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = MobileLanguage.stored(defaults.string(forKey: Self.storageKey))
    }

    var effective: MobileLanguage {
        selected == .system
            ? MobileLanguage.from(preferredIdentifier: Locale.preferredLanguages.first ?? "en")
            : selected
    }

    var locale: Locale { Locale(identifier: effective.localeIdentifier) }
    var isRTL: Bool { effective.isRTL }

    func set(_ language: MobileLanguage) {
        selected = language
    }

    func text(_ key: String) -> String {
        MobileCopy.text(key, language: effective)
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        MobileCopy.format(key, language: effective, locale: locale, arguments: arguments)
    }
}

enum MobileCopy {
    static func bundle(for language: MobileLanguage) -> Bundle {
        let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj")
            ?? Bundle.main.path(forResource: language.rawValue.lowercased(), ofType: "lproj")
        return path.flatMap(Bundle.init(path:)) ?? .main
    }

    static func text(_ key: String, language: MobileLanguage = .en) -> String {
        let localized = bundle(for: language).localizedString(forKey: key, value: nil, table: nil)
        if localized != key { return localized }
        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(
        _ key: String,
        language: MobileLanguage = .en,
        locale: Locale = .current,
        arguments: [CVarArg]
    ) -> String {
        String(format: text(key, language: language), locale: locale, arguments: arguments)
    }
}

enum MobileIntroNavigation {
    static func canSkip(page: Int, pageCount: Int) -> Bool { page < pageCount - 1 }
    static func showsBack(page: Int) -> Bool { page > 0 }
    static func primaryKey(page: Int, pageCount: Int) -> String {
        page == pageCount - 1 ? "intro.start" : "intro.continue"
    }
}

struct MobileLanguagePicker: View {
    @EnvironmentObject private var localization: MobileLocalization
    @State private var isPresented = false
    var darkAppearance = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label(localization.selected.shortCode, systemImage: "globe")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(darkAppearance ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background((darkAppearance ? Color.white.opacity(0.16) : Color.primary.opacity(0.08)))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localization.text("intro.languageAccessibility"))
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                List {
                    languageRow(.system)
                    ForEach(MobileLanguage.supported) { languageRow($0) }
                }
                .navigationTitle(localization.text("intro.language"))
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func languageRow(_ language: MobileLanguage) -> some View {
        Button {
            localization.set(language)
            isPresented = false
        } label: {
            HStack(spacing: 12) {
                Text(language.flagEmoji)
                Text(language == .system ? localization.text("intro.languageSystem") : language.nativeName)
                Spacer()
                if localization.selected == language {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
