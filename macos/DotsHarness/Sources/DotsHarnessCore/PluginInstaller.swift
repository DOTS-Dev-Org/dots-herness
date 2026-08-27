// Copyright (c) 2026 DOTS
// Installs `.dotsplugin` packages (local file or remote URL) into the catalog.

import Foundation
import HarnessPluginKit
import PluginRuntime

// ponytail: install() runs ditto + file IO synchronously on the main actor.
// Fine for a rare, user-initiated action; move to a detached task if it janks.
@MainActor
public struct PluginInstaller {
    public let catalog: PluginCatalog

    public init(catalog: PluginCatalog) {
        self.catalog = catalog
    }

    /// DOTS' own publisher key ships with the app; user-pinned keys are merged
    /// from `publishers.json` in the support directory.
    public static let officialPublishers: [String: String] = [
        // Replace with the real Ed25519 public key (base64 raw) before release.
        "dots": ""
    ]

    public func trustedPublishers() -> [String: String] {
        var merged = Self.officialPublishers.filter { !$0.value.isEmpty }
        if let data = try? Data(contentsOf: catalog.paths.publishers),
           let extra = try? JSONDecoder().decode([String: String].self, from: data) {
            merged.merge(extra) { _, new in new }
        }
        return merged
    }

    public func pinPublisher(id: String, publicKey: String) throws {
        var current = (try? JSONDecoder().decode(
            [String: String].self,
            from: Data(contentsOf: catalog.paths.publishers)
        )) ?? [:]
        current[id] = publicKey
        let data = try JSONEncoder().encode(current)
        try data.write(to: catalog.paths.publishers, options: .atomic)
    }

    // MARK: Install

    /// `signature == nil` installs unsigned (used for local dev). A signature is
    /// always verified against pinned publishers when present.
    @discardableResult
    public func install(
        package: URL,
        signature: PluginSignature?,
        trust: PluginTrust = .untrusted
    ) throws -> PluginManifest {
        if let signature {
            try PluginPackage.verify(
                package: package,
                signature: signature,
                publishers: trustedPublishers()
            )
        }
        catalog.paths.ensure()
        let manifest = try PluginPackage.unpack(package: package, into: catalog.paths.plugins)
        catalog.refresh()
        if signature != nil, trust != .untrusted {
            catalog.setTrust(manifest.id, trust)
        }
        return manifest
    }

    @discardableResult
    public func installRemote(
        url: URL,
        sha256: String? = nil,
        signature: PluginSignature? = nil,
        trust: PluginTrust = .untrusted
    ) async throws -> PluginManifest {
        let scratch = catalog.paths.runtime.appendingPathComponent("downloads", isDirectory: true)
        let name = url.lastPathComponent.isEmpty ? "package.dotsplugin" : url.lastPathComponent
        let destination = scratch.appendingPathComponent(name)
        try await FileDownloader.download(from: url, to: destination, sha256: sha256 ?? signature?.sha256)
        defer { try? FileManager.default.removeItem(at: destination) }
        return try install(package: destination, signature: signature, trust: trust)
    }

    public func remove(id: String) throws {
        let folder = catalog.paths.plugins.appendingPathComponent(id, isDirectory: true)
        guard folder.standardizedFileURL.path.hasPrefix(catalog.paths.plugins.standardizedFileURL.path),
              folder.pathComponents.count > catalog.paths.plugins.pathComponents.count else {
            throw PluginError.package("refusing to remove \(id)")
        }
        try FileManager.default.removeItem(at: folder)
        catalog.refresh()
    }
}
