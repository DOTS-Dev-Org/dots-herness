import Foundation
import SwiftUI

/// The mobile language list mirrors macOS AppLanguage. 30 concrete resource locales.
enum MobileLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case tr, en, de, es, fr, it, ja, ko, nl, pt, ru
    case zhHans = "zh-Hans"
    case ar, bn, hi, id, vi, ur, mr, te, ta, fa, pl, uk, th, ms, ro, el, cs, hu

    var id: String { rawValue }

    static var supported: [MobileLanguage] {
        allCases
    }

    var localeIdentifier: String {
        switch self {
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
        default: return false
        }
    }

    var shortCode: String {
        switch self {
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
        guard let rawValue, let value = MobileLanguage(rawValue: rawValue) else {
            return from(preferredIdentifier: Locale.preferredLanguages.first ?? "en")
        }
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
        selected
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

@MainActor
final class MobileTheme: ObservableObject {
    static let storageKey = "mobile.theme.dark"

    @Published var isDark: Bool {
        didSet { defaults.set(isDark, forKey: Self.storageKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.storageKey) != nil {
            self.isDark = defaults.bool(forKey: Self.storageKey)
        } else {
            self.isDark = true
        }
    }

    func toggle() {
        withAnimation(.easeInOut(duration: 0.25)) {
            isDark.toggle()
        }
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
    var isDropdownOpen: Binding<Bool>?
    var darkAppearance: Bool = false

    @State private var internalOpen = false

    private var openBinding: Binding<Bool> {
        isDropdownOpen ?? $internalOpen
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                openBinding.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Text(localization.selected.flagEmoji)
                    .font(.system(size: 15))
                Text(localization.selected.shortCode)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Image(systemName: openBinding.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle((darkAppearance ? Color.white : Color(red: 0.12, green: 0.12, blue: 0.14)).opacity(0.75))
            }
            .foregroundStyle(darkAppearance ? Color.white : Color(red: 0.12, green: 0.12, blue: 0.14))
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localization.text("intro.languageAccessibility"))
    }
}

struct CustomLanguageDropdown: View {
    @EnvironmentObject private var localization: MobileLocalization
    @Binding var isPresented: Bool
    var darkAppearance: Bool = false

    var body: some View {
        if isPresented {
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            isPresented = false
                        }
                    }

                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(MobileLanguage.supported) { language in
                                Button {
                                    localization.set(language)
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                        isPresented = false
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(language.flagEmoji)
                                            .font(.system(size: 16))
                                        Text(language.nativeName)
                                            .font(.system(size: 13, weight: localization.selected == language ? .bold : .medium, design: .rounded))
                                            .foregroundStyle(darkAppearance ? Color.white : Color.primary)
                                        Spacer()
                                        if localization.selected == language {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(Color.blue)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(
                                        localization.selected == language
                                            ? (darkAppearance ? Color.white.opacity(0.12) : Color.black.opacity(0.06))
                                            : Color.clear
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                    }
                    .frame(maxHeight: 220)
                }
                .frame(width: 188)
                .background(
                    darkAppearance
                        ? Color(red: 0.13, green: 0.13, blue: 0.15).opacity(0.96)
                        : Color.white.opacity(0.98)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(darkAppearance ? Color.white.opacity(0.14) : Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(darkAppearance ? 0.45 : 0.18), radius: 18, x: 0, y: 8)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)),
                    removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading))
                ))
            }
        }
    }
}

struct SettingsLanguageMenu: View {
    @EnvironmentObject private var localization: MobileLocalization
    @State private var isPresented = false
    var darkAppearance: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.system(size: 14, weight: .semibold))
                Text(localization.selected.shortCode)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(darkAppearance ? Color.white : Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localization.text("intro.languageAccessibility"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(MobileLanguage.supported) { language in
                        let selected = localization.selected == language
                        Button {
                            localization.set(language)
                            isPresented = false
                        } label: {
                            HStack(spacing: 8) {
                                Text(language.flagEmoji)
                                    .font(.system(size: 16))
                                Text(language.nativeName)
                                    .font(.system(size: 13, weight: selected ? .bold : .medium, design: .rounded))
                                    .foregroundStyle(darkAppearance ? Color.white : Color.primary)
                                Spacer(minLength: 0)
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Color.blue)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selected ? (darkAppearance ? Color.white.opacity(0.12) : Color.black.opacity(0.06)) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
            .frame(width: 188, height: 220)
            .presentationCompactAdaptation(.popover)
        }
    }
}
