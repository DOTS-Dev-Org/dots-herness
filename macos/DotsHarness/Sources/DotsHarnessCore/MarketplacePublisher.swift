// Copyright (c) 2026 DOTS
// Authenticated native plugin publishing to the Cloudflare Marketplace API.

import Foundation
import HarnessPluginKit
import PluginRuntime

public struct MarketplacePublishDraft: Sendable {
    public var folder: URL
    public var license: String
    public var version: String
    public var sourceVisibility: String
    public var targets: [MarketplaceTarget]

    public init(
        folder: URL,
        license: String,
        version: String,
        sourceVisibility: String = "public",
        targets: [MarketplaceTarget] = MarketplaceTarget.defaultTargets
    ) {
        self.folder = folder
        self.license = license
        self.version = version
        self.sourceVisibility = sourceVisibility
        self.targets = targets
    }
}

public enum MarketplacePublishError: LocalizedError, Sendable {
    case invalidPlugin(String)
    case response(Int, String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPlugin(message): return message
        case let .response(status, message): return "Marketplace yayınlama başarısız (HTTP \(status)): \(message)"
        }
    }
}

@MainActor
public final class MarketplacePublisher: ObservableObject {
    public let session: MarketplaceSession
    @Published public private(set) var isPublishing = false
    @Published public private(set) var status: String?

    public init(session: MarketplaceSession) {
        self.session = session
    }

    public func publish(_ draft: MarketplacePublishDraft) async throws {
        guard session.isSignedIn else { throw MarketplaceSessionError.notSignedIn }
        guard !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }
        guard draft.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw MarketplacePublishError.invalidPlugin("Plugin yayınlamak için lisans seçmelisiniz.")
        }
        guard let manifestData = try? Data(contentsOf: draft.folder.appendingPathComponent("plugin.yml")) else {
            throw MarketplacePublishError.invalidPlugin("Seçilen klasörde plugin.yml bulunamadı.")
        }
        let manifest = try MiniYAML.decode(PluginManifest.self, from: String(decoding: manifestData, as: UTF8.self))
        let library = manifest.library?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard manifest.runtime == "native", manifest.main == nil,
              !library.isEmpty, !library.hasPrefix("/"), !library.contains("..") else {
            throw MarketplacePublishError.invalidPlugin("Yalnızca native pluginler yayınlanabilir.")
        }
        guard Self.isReleaseSemVer(draft.version) else {
            throw MarketplacePublishError.invalidPlugin("Geçerli bir SemVer sürümü girin.")
        }
        guard ["public", "private"].contains(draft.sourceVisibility), !draft.targets.isEmpty else {
            throw MarketplacePublishError.invalidPlugin("En az bir platform hedefi ve geçerli kaynak görünürlüğü seçmelisiniz.")
        }

        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("dots-marketplace-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let sourceFolder = temporary.appendingPathComponent(manifest.id, isDirectory: true)
        try fm.copyItem(at: draft.folder, to: sourceFolder)

        // The source archive must carry the same immutable version sent to the
        // Worker. Update only the temporary copy; the user's working folder is
        // never modified by publishing.
        var releaseManifest = manifest
        releaseManifest.version = draft.version
        try Self.rewriteVersion(in: sourceFolder.appendingPathComponent("plugin.yml"), to: draft.version)

        let irURL = sourceFolder.appendingPathComponent("plugin.ir.json")
        guard fm.fileExists(atPath: irURL.path),
              let licenseData = try? Data(contentsOf: sourceFolder.appendingPathComponent("license")),
              !licenseData.isEmpty else {
            throw MarketplacePublishError.invalidPlugin("Paket plugin.ir.json ve license dosyalarını içermeli.")
        }
        let irData = try Data(contentsOf: irURL)
        let ir = try JSONSerialization.jsonObject(with: irData) as? [String: Any]
        guard let ir, (ir["version"] as? Int) == 1 else {
            throw MarketplacePublishError.invalidPlugin("plugin.ir.json yalnızca version 1 olmalıdır.")
        }

        status = "Marketplace kaydı oluşturuluyor…"
        let manifestJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(releaseManifest))
        let metadata: [String: Any] = [
            "id": manifest.id,
            "name": manifest.name,
            "description": manifest.description,
            "author": "",
            "license": draft.license,
            "source_visibility": draft.sourceVisibility,
            "targets": draft.targets.map { ["platform": $0.platform, "architecture": $0.architecture] },
            "version": draft.version,
            "ir": ir,
            "manifest": manifestJSON,
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        let create = try await session.authorizedData(
            path: "api/marketplace/plugins",
            method: "POST",
            body: metadataData,
            contentType: "application/json"
        )

        let releaseID: String
        if (200..<300).contains(create.1.statusCode) {
            releaseID = try Self.releaseID(from: create.0)
        } else if create.1.statusCode == 409 {
            let releaseBody: [String: Any] = [
                "version": draft.version,
                "license": draft.license,
                "ir": ir,
                "manifest": manifestJSON,
                "targets": draft.targets.map { ["platform": $0.platform, "architecture": $0.architecture] },
            ]
            let releaseData = try JSONSerialization.data(withJSONObject: releaseBody, options: [.sortedKeys])
            let release = try await session.authorizedData(
                path: "api/marketplace/plugins/\(manifest.id)/releases",
                method: "POST",
                body: releaseData,
                contentType: "application/json"
            )
            guard (200..<300).contains(release.1.statusCode) else {
                throw MarketplacePublishError.response(release.1.statusCode, String(decoding: release.0, as: UTF8.self))
            }
            releaseID = try Self.releaseID(from: release.0)
        } else {
            throw MarketplacePublishError.response(create.1.statusCode, String(decoding: create.0, as: UTF8.self))
        }

        status = "Native kaynak paketi yükleniyor…"
        let sourceArchive = temporary.appendingPathComponent("source.dotsplugin")
        try PluginPackage.pack(folder: sourceFolder, to: sourceArchive)
        let sourceData = try Data(contentsOf: sourceArchive, options: .mappedIfSafe)
        let source = try await session.authorizedData(
            path: "api/marketplace/releases/\(releaseID)/source",
            method: "PUT",
            body: sourceData,
            contentType: "application/zip"
        )
        guard (200..<300).contains(source.1.statusCode) else {
            throw MarketplacePublishError.response(source.1.statusCode, String(decoding: source.0, as: UTF8.self))
        }
        status = "Native platform buildleri kuyruğa alınıyor…"
        let build = try await session.authorizedData(
            path: "api/marketplace/releases/\(releaseID)/build",
            method: "POST",
            body: nil,
            contentType: nil
        )
        guard (200..<300).contains(build.1.statusCode) else {
            throw MarketplacePublishError.response(build.1.statusCode, String(decoding: build.0, as: UTF8.self))
        }
        status = "Kaynak paketi yüklendi; native CI doğrulaması bekleniyor."
    }

    private static func releaseID(from data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["release_id"] as? String, !id.isEmpty else {
            throw MarketplacePublishError.invalidPlugin("Marketplace release kimliği alınamadı.")
        }
        return id
    }

    private static func isReleaseSemVer(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isNumber } && (part.count == 1 || part.first != "0")
        }
    }

    private static func rewriteVersion(in url: URL, to version: String) throws {
        var lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("version:") }) else {
            throw MarketplacePublishError.invalidPlugin("plugin.yml version alanı eksik.")
        }
        let indentation = String(lines[index].prefix { $0 == " " || $0 == "\t" })
        lines[index] = "\(indentation)version: \(version)"
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
