// Copyright (c) 2026 DOTS
// Marketplace: a static registry.json of installable `.dotsplugin` packages.

import Foundation
import HarnessPluginKit
import PluginRuntime

public struct MarketplaceEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String
    public var author: String
    /// declarative | native | js — informational; trust still gates loading.
    public var tier: String
    public var homepage: String?
    public var downloadURL: String
    public var sha256: String?
    public var signature: PluginSignature?
    public var screenshots: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, author, tier, homepage, downloadURL, sha256, signature, screenshots
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        tier = try c.decodeIfPresent(String.self, forKey: .tier) ?? "declarative"
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        downloadURL = try c.decode(String.self, forKey: .downloadURL)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        signature = try c.decodeIfPresent(PluginSignature.self, forKey: .signature)
        screenshots = try c.decodeIfPresent([String].self, forKey: .screenshots) ?? []
    }
}

public struct MarketplaceIndex: Codable, Sendable {
    public var version: Int
    public var plugins: [MarketplaceEntry]

    enum CodingKeys: String, CodingKey { case version, plugins }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        plugins = try c.decodeIfPresent([MarketplaceEntry].self, forKey: .plugins) ?? []
    }
}

public enum MarketplaceStatus: Sendable, Equatable {
    case notInstalled
    case upToDate
    case updateAvailable(installed: String)
}

@MainActor
public final class MarketplaceClient: ObservableObject {
    public static let defaultIndex = "https://dots.net.tr/harness/registry.json"

    @Published public private(set) var entries: [MarketplaceEntry] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var busyIDs: Set<String> = []

    public var indexURL: URL
    private let catalog: PluginCatalog
    private let installer: PluginInstaller

    public init(indexURL: URL, catalog: PluginCatalog) {
        self.indexURL = indexURL
        self.catalog = catalog
        self.installer = PluginInstaller(catalog: catalog)
        loadCached()
    }

    private var cacheURL: URL {
        catalog.paths.runtime.appendingPathComponent("marketplace.json")
    }

    public func loadCached() {
        guard let data = try? Data(contentsOf: cacheURL),
              let index = try? JSONDecoder().decode(MarketplaceIndex.self, from: data) else { return }
        entries = index.plugins
    }

    public func refresh() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            var request = URLRequest(url: indexURL, timeoutInterval: 30)
            request.setValue("DotsHarness", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                lastError = "registry HTTP \(status)"
                return
            }
            let index = try JSONDecoder().decode(MarketplaceIndex.self, from: data)
            entries = index.plugins
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: cacheURL, options: .atomic)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func status(_ entry: MarketplaceEntry) -> MarketplaceStatus {
        guard let installed = catalog.entries.first(where: { $0.manifest.id == entry.id })?.manifest.version else {
            return .notInstalled
        }
        if let a = SemVer(installed), let b = SemVer(entry.version), a < b {
            return .updateAvailable(installed: installed)
        }
        return .upToDate
    }

    /// Downloads, verifies (if signed), unpacks, and refreshes the catalog.
    /// Compiled (`native`/`js`) plugins install untrusted; the user raises trust
    /// from Settings before they load.
    public func install(_ entry: MarketplaceEntry) async throws {
        guard let url = URL(string: entry.downloadURL) else {
            throw PluginError.package("bad download URL for \(entry.id)")
        }
        busyIDs.insert(entry.id)
        defer { busyIDs.remove(entry.id) }
        _ = try await installer.installRemote(url: url, sha256: entry.sha256, signature: entry.signature)
    }

    public func remove(_ id: String) throws {
        try installer.remove(id: id)
    }
}
