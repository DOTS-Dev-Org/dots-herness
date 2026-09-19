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
        // DOTS marketplace Ed25519 raw public key (base64). Rotate this key by
        // shipping a new app version; never accept a registry-provided root key.
        "dots": "5BjXLUajc3JkmWmNHiBg5kmJoTFx2OVSe7BetYJEtCI="
    ]

    public func trustedPublishers() -> [String: String] {
        var merged = Self.officialPublishers.filter { !$0.value.isEmpty }
        if let data = try? Data(contentsOf: catalog.paths.publishers),
           let extra = try? JSONDecoder().decode([String: String].self, from: data) {
            for (id, key) in extra where id != "dots" && !key.isEmpty {
                merged[id] = key
            }
        }
        return merged
    }

    public func pinPublisher(id: String, publicKey: String) throws {
        guard id != "dots" else {
            throw PluginError.package("the official DOTS publisher key is immutable")
        }
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
        trust: PluginTrust = .untrusted,
        expectedID: String? = nil,
        expectedVersion: String? = nil,
        requireLicense: Bool = false
    ) throws -> PluginManifest {
        if let signature {
            try PluginPackage.verify(
                package: package,
                signature: signature,
                publishers: trustedPublishers()
            )
        }
        catalog.paths.ensure()
        let manifest = try PluginPackage.unpack(
            package: package,
            into: catalog.paths.plugins,
            expectedID: expectedID,
            expectedVersion: expectedVersion,
            requireLicense: requireLicense
        )
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
        trust: PluginTrust = .untrusted,
        expectedID: String? = nil,
        expectedVersion: String? = nil,
        requireLicense: Bool = false
    ) async throws -> PluginManifest {
        guard url.scheme?.lowercased() == "https" else {
            throw PluginError.package("Marketplace downloads must use HTTPS")
        }
        let scratch = catalog.paths.runtime.appendingPathComponent("downloads", isDirectory: true)
        let name = url.lastPathComponent.isEmpty ? "package.dotsplugin" : url.lastPathComponent
        let destination = scratch.appendingPathComponent(name)
        try await FileDownloader.download(from: url, to: destination, sha256: sha256 ?? signature?.sha256)
        defer { try? FileManager.default.removeItem(at: destination) }
        return try install(
            package: destination,
            signature: signature,
            trust: trust,
            expectedID: expectedID,
            expectedVersion: expectedVersion,
            requireLicense: requireLicense
        )
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
