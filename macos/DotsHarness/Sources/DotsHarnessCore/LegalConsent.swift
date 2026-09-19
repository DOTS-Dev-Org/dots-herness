// Copyright (c) 2026 DOTS
// Legal document fetch + acceptance/consent state for the macOS client.
//
// The privacy policy and user agreement live in the DOTS web database
// (apps table, slug 'dots-herness') and are fetched live so an updated text
// reaches users without an app release. See docs/legal/README.md.

import CryptoKit
import Foundation
import HarnessPluginKit

public struct LegalDocuments: Sendable, Equatable {
    public let termsMarkdown: String
    public let privacyMarkdown: String
    /// Changes whenever either document changes; drives re-acceptance.
    public let hash: String

    public var isEmpty: Bool { termsMarkdown.isEmpty && privacyMarkdown.isEmpty }
    public var isComplete: Bool { !termsMarkdown.isEmpty && !privacyMarkdown.isEmpty }
}

public enum LegalConsentKey: String, CaseIterable, Sendable {
    case aiTransfer, github, voice, marketing
}

@MainActor
public final class LegalService {
    public static let restURL = URL(string:
        "https://dots-web-api.pettakip.workers.dev/rest/v1/apps?select=privacy_policy_tr,privacy_policy_en,terms_of_service_tr,terms_of_service_en"
        + "&slug.eq=dots-herness&single=true"
    )!

    private static let acceptedHashKey = "legal.acceptedHash"
    private static let acceptedAtKey = "legal.acceptedAt"
    private static let consentPrefix = "legal.consent."

    private let settings: SettingsRegistry
    private let cacheURL: URL?

    public init(settings: SettingsRegistry, cacheDirectory: URL?) {
        self.settings = settings
        self.cacheURL = cacheDirectory?.appendingPathComponent("legal-cache-v2.json")
    }

    public static func webURL(lang: String, terms: Bool) -> URL {
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

    /// Fetch from the web; on failure fall back to the on-disk cache. A cache
    /// with incomplete content is not accepted as a legal document.
    public func fetch(lang: String) async -> LegalDocuments? {
        do {
            var request = URLRequest(url: Self.restURL)
            request.timeoutInterval = 20
            request.setValue("DotsHarness", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            guard ok else { throw URLError(.badServerResponse) }
            if let docs = Self.parse(data, lang: lang), docs.isComplete {
                writeCache(data)
                return docs
            }
        } catch {
            // fall through to cache
        }
        if let cached = readCache(), let docs = Self.parse(cached, lang: lang), docs.isComplete {
            return docs
        }
        return nil
    }

    static func parse(_ data: Data, lang: String) -> LegalDocuments? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let row: [String: Any]?
        if let obj = root as? [String: Any] {
            if let array = obj["data"] as? [[String: Any]] { row = array.first }
            else if let single = obj["data"] as? [String: Any] { row = single }
            else { row = obj }
        } else if let array = root as? [[String: Any]] {
            row = array.first
        } else {
            row = nil
        }
        guard let row else { return nil }

        func pick(_ field: String) -> String {
            let requested = lang.split(separator: "-", omittingEmptySubsequences: true).first.map(String.init)?.lowercased() ?? "en"
            let suffixes = requested == "tr" ? ["tr", "en"] : [requested, "en"]
            for suffix in suffixes {
                if let value = row["\(field)_\(suffix)"] as? String, !value.isEmpty { return value }
            }
            return ""
        }

        let terms = pick("terms_of_service")
        let privacy = pick("privacy_policy")
        return LegalDocuments(termsMarkdown: terms, privacyMarkdown: privacy, hash: Self.hash(terms, privacy))
    }

    static func hash(_ terms: String, _ privacy: String) -> String {
        let digest = SHA256.hash(data: Data((terms + " " + privacy).utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    // MARK: - acceptance

    public var hasAnyAcceptance: Bool {
        !(settings.get(Self.acceptedHashKey)?.string ?? "").isEmpty
    }

    public func needsAcceptance(_ docs: LegalDocuments) -> Bool {
        settings.get(Self.acceptedHashKey)?.string != docs.hash
    }

    public func accept(_ docs: LegalDocuments) {
        settings.set(Self.acceptedHashKey, .string(docs.hash))
        settings.set(Self.acceptedAtKey, .string(ISO8601DateFormatter().string(from: Date())))
    }

    // MARK: - consent

    /// These are not opt-in toggles: using the app means these are already
    /// in effect, so consent is always granted and cannot be revoked here.
    public func consent(_ key: LegalConsentKey) -> Bool { true }

    /// AI features are always allowed; see `consent(_:)`.
    public var aiTransferAllowed: Bool { true }

    // MARK: - cache

    private func writeCache(_ data: Data) {
        guard let cacheURL else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func readCache() -> Data? {
        guard let cacheURL else { return nil }
        return try? Data(contentsOf: cacheURL)
    }
}
