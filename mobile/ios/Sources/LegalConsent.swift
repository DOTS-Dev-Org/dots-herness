// Copyright (c) 2026 DOTS
// Live-fetched legal documents + first-run acceptance gate for the iOS client.
// Canonical Markdown is versioned in the Herness Worker D1/R2 pipeline; see
// docs/legal/README.md.

import CryptoKit
import Foundation
import SwiftUI

struct LegalDocuments: Equatable {
    let version: String
    let locale: String
    let termsMarkdown: String
    let privacyMarkdown: String
    let termsHash: String
    let privacyHash: String
    let termsURL: URL?
    let privacyURL: URL?
    let hash: String
    var isEmpty: Bool { termsMarkdown.isEmpty && privacyMarkdown.isEmpty }
    var isComplete: Bool { !termsMarkdown.isEmpty && !privacyMarkdown.isEmpty }
}

enum LegalConsentKey: String, CaseIterable {
    case aiTransfer, github, voice, marketing
}

@MainActor
final class LegalModel: ObservableObject {
    static let apiURL = URL(string: "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev/api/legal/documents")!

    private let acceptedHashKey = "legal.acceptedHash"
    private let acceptedAtKey = "legal.acceptedAt"
    private let defaults = UserDefaults.standard

    @Published private(set) var documents: LegalDocuments?
    @Published private(set) var needsAcceptance: Bool
    @Published private(set) var loadFailed = false
    @Published private(set) var languageCode = "en"

    init() {
        needsAcceptance = (UserDefaults.standard.string(forKey: "legal.acceptedHash") ?? "").isEmpty
    }

    func setLanguage(_ language: MobileLanguage) {
        guard languageCode != language.rawValue else { return }
        languageCode = language.rawValue
        loadFailed = false
    }

    private var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("legal-cache-v3-\(languageCode.replacingOccurrences(of: "-", with: "_" )).json")
    }

    static func webURL(lang: String, terms: Bool) -> URL {
        let s: String
        if lang == "tr" {
            s = terms
                ? "https://dots.net.tr/uygulama/dots-herness/kullanim-sozlesmesi"
                : "https://dots.net.tr/uygulama/dots-herness/gizlilik"
        } else {
            s = terms
                ? "https://dots.net.tr/apps/dots-herness/terms-of-service"
                : "https://dots.net.tr/apps/dots-herness/privacy"
        }
        return URL(string: s)!
    }

    func load() async {
        if let docs = await fetch() {
            documents = docs
            needsAcceptance = defaults.string(forKey: acceptedHashKey) != docs.hash
            loadFailed = false
        } else {
            loadFailed = true
            needsAcceptance = (defaults.string(forKey: acceptedHashKey) ?? "").isEmpty
        }
    }

    private func fetch() async -> LegalDocuments? {
        do {
            var components = URLComponents(url: Self.apiURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "locale", value: languageCode)]
            guard let url = components?.url else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("HerNessMobile", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            guard ok else { throw URLError(.badServerResponse) }
            if let docs = Self.parse(data, expectedLocale: languageCode), docs.isComplete {
                if let cacheURL { try? data.write(to: cacheURL, options: .atomic) }
                return docs
            }
        } catch {
            // fall through to cache
        }
        if let cacheURL, let cached = try? Data(contentsOf: cacheURL),
           let docs = Self.parse(cached, expectedLocale: languageCode), docs.isComplete {
            return docs
        }
        return nil
    }

    static func parse(_ data: Data, expectedLocale: String) -> LegalDocuments? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let locale = root["locale"] as? String,
            locale == expectedLocale,
            let version = root["version"] as? String,
            let documents = root["documents"] as? [String: Any],
            let terms = documents["terms"] as? [String: Any],
            let privacy = documents["privacy_notice"] as? [String: Any],
            let termsMarkdown = terms["markdown"] as? String,
            let privacyMarkdown = privacy["markdown"] as? String,
            let termsHash = terms["sha256"] as? String,
            let privacyHash = privacy["sha256"] as? String
        else { return nil }

        func digest(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        guard digest(termsMarkdown) == termsHash, digest(privacyMarkdown) == privacyHash else { return nil }
        let acceptanceHash = digest("\(version)|\(locale)|\(termsHash)|\(privacyHash)")
        return LegalDocuments(
            version: version,
            locale: locale,
            termsMarkdown: termsMarkdown,
            privacyMarkdown: privacyMarkdown,
            termsHash: termsHash,
            privacyHash: privacyHash,
            termsURL: (terms["r2_url"] as? String).flatMap(URL.init(string:)),
            privacyURL: (privacy["r2_url"] as? String).flatMap(URL.init(string:)),
            hash: acceptanceHash,
        )
    }

    func accept() {
        guard let docs = documents else { return }
        defaults.set(docs.hash, forKey: acceptedHashKey)
        defaults.set(ISO8601DateFormatter().string(from: Date()), forKey: acceptedAtKey)
        needsAcceptance = false
    }

    /// These are not opt-in toggles: using the app means these are already
    /// in effect, so consent is always granted and cannot be revoked here.
    func consent(_ key: LegalConsentKey) -> Bool { true }

    var webLang: String { languageCode }
}

// MARK: - Views

private enum LegalDoc: String, CaseIterable, Identifiable {
    case terms, privacy
    var id: String { rawValue }
}

private struct LegalDocumentPanel: View {
    @EnvironmentObject private var localization: MobileLocalization
    let documents: LegalDocuments
    @State private var selection: LegalDoc

    init(documents: LegalDocuments, initialSelection: LegalDoc = .terms) {
        self.documents = documents
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $selection) {
                ForEach(LegalDoc.allCases) { document in
                    Text(localization.text(document == .terms ? "legal.termsTab" : "legal.privacyTab")).tag(document)
                }
            }
            .pickerStyle(.segmented)

            ScrollView {
                Text(selection == .terms ? documents.termsMarkdown : documents.privacyMarkdown)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200)

            Link(localization.text("legal.openWeb"),
                 destination: (selection == .terms ? documents.termsURL : documents.privacyURL)
                    ?? LegalModel.webURL(lang: documents.locale, terms: selection == .terms))
                .font(.footnote)
        }
    }
}

private struct ConsentStatements: View {
    @EnvironmentObject private var localization: MobileLocalization

    var body: some View {
        ForEach(LegalConsentKey.allCases, id: \.self) { key in
            Text(localization.text("legal.consent.\(key.rawValue)"))
                .font(.footnote)
        }
    }
}

struct LegalGateView: View {
    @EnvironmentObject private var localization: MobileLocalization
    @EnvironmentObject private var theme: MobileTheme
    @ObservedObject var legal: LegalModel
    @State private var termsAccepted = false
    @State private var privacyAccepted = false
    @State private var documentToShow: LegalDoc?
    @State private var isLanguageDropdownOpen = false

    private var currentDocuments: LegalDocuments? {
        guard let documents = legal.documents,
              documents.locale == localization.effective.rawValue else { return nil }
        return documents
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    (theme.isDark ? Color.black : Color.white)
                        .ignoresSafeArea()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                if localization.isRTL {
                                    themeToggleButton
                                    Spacer(minLength: 0)
                                    languagePicker
                                } else {
                                    languagePicker
                                    Spacer(minLength: 0)
                                    themeToggleButton
                                }
                            }

                            Text(localization.text("legal.title"))
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text(localization.text("legal.gateHeading"))
                                .font(.title3.weight(.semibold))
                            Text(localization.text("legal.gateIntro"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if currentDocuments != nil {
                                Text(localization.text("legal.acceptRequired"))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 2)

                                legalDocumentRow(
                                    .terms,
                                    title: localization.text("legal.termsTab"),
                                    accepted: $termsAccepted
                                )
                                legalDocumentRow(
                                    .privacy,
                                    title: localization.text("legal.privacyTab"),
                                    accepted: $privacyAccepted
                                )
                            } else if legal.loadFailed {
                                Text(localization.text("legal.loadError"))
                                    .foregroundStyle(.secondary)
                                Button(localization.text("legal.retry")) { Task { await legal.load() } }
                            } else {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }

                    if isLanguageDropdownOpen {
                        CustomLanguageDropdown(
                            isPresented: $isLanguageDropdownOpen,
                            darkAppearance: theme.isDark
                        )
                        .padding(.top, max(geometry.safeAreaInsets.top, 54) + 48)
                        .padding(.leading, localization.isRTL ? 0 : 20)
                        .padding(.trailing, localization.isRTL ? 20 : 0)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: localization.isRTL ? .topTrailing : .topLeading
                        )
                        .zIndex(999)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if currentDocuments != nil {
                    Button { legal.accept() } label: {
                        Text(localization.text("legal.accept"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!(termsAccepted && privacyAccepted))
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .background(theme.isDark ? Color.black : Color.white)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $documentToShow) { document in
                if let documents = currentDocuments {
                    NavigationStack {
                        LegalDocumentPanel(documents: documents, initialSelection: document)
                            .padding(.horizontal)
                            .navigationTitle(localization.text("legal.title"))
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
            .preferredColorScheme(theme.isDark ? .dark : .light)
        }
    }

    private var languagePicker: some View {
        MobileLanguagePicker(
            isDropdownOpen: $isLanguageDropdownOpen,
            darkAppearance: theme.isDark
        )
    }

    private var themeToggleButton: some View {
        Button { theme.toggle() } label: {
            Image(systemName: theme.isDark ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.isDark ? Color.white : Color(red: 0.12, green: 0.12, blue: 0.14))
                .frame(width: 34, height: 34)
                .background(theme.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.isDark ? "Switch to light theme" : "Switch to dark theme")
    }

    private func legalDocumentRow(
        _ document: LegalDoc,
        title: String,
        accepted: Binding<Bool>
    ) -> some View {
        HStack(spacing: 8) {
            Button { documentToShow = document } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle(isOn: accepted) { EmptyView() }
                .labelsHidden()
                .toggleStyle(CheckboxToggleStyle())
                .accessibilityLabel(title)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
    }
}

private struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                configuration.label.multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
    }
}

struct LegalSettingsView: View {
    @EnvironmentObject private var localization: MobileLocalization
    @ObservedObject var legal: LegalModel
    @State private var documentToShow: LegalDoc?
    var body: some View {
        Form {
            if legal.documents != nil {
                Section {
                    HStack {
                        Button(localization.text("legal.termsTab")) { documentToShow = .terms }
                        Button(localization.text("legal.privacyTab")) { documentToShow = .privacy }
                    }
                }
                Section(localization.text("legal.consentPrefs")) { ConsentStatements() }
            } else {
                Button(localization.text("legal.retry")) { Task { await legal.load() } }
            }
        }
        .navigationTitle(localization.text("legal.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $documentToShow) { document in
            if let documents = legal.documents {
                NavigationStack {
                    LegalDocumentPanel(documents: documents, initialSelection: document)
                        .padding(.horizontal)
                        .navigationTitle(localization.text("legal.title"))
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }
}
