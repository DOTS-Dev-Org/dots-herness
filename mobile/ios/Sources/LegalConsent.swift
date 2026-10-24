// Copyright (c) 2026 DOTS
// Live-fetched legal documents for the optional Settings viewer.
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
    var isEmpty: Bool { termsMarkdown.isEmpty && privacyMarkdown.isEmpty }
    var isComplete: Bool { !termsMarkdown.isEmpty && !privacyMarkdown.isEmpty }
}

enum LegalConsentKey: String, CaseIterable {
    case aiTransfer, github, voice, marketing
}

@MainActor
final class LegalModel: ObservableObject {
    static let apiURL = URL(string: "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev/api/legal/documents")!

    @Published private(set) var documents: LegalDocuments?
    @Published private(set) var loadFailed = false
    @Published private(set) var languageCode = "en"

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
            loadFailed = false
        } else {
            loadFailed = true
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
        return LegalDocuments(
            version: version,
            locale: locale,
            termsMarkdown: termsMarkdown,
            privacyMarkdown: privacyMarkdown,
            termsHash: termsHash,
            privacyHash: privacyHash,
            termsURL: (terms["r2_url"] as? String).flatMap(URL.init(string:)),
            privacyURL: (privacy["r2_url"] as? String).flatMap(URL.init(string:))
        )
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
