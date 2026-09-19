// Copyright (c) 2026 DOTS
// Cloudflare-backed registry of installable native `.dotsplugin` packages.

import Foundation
import HarnessPluginKit
import PluginRuntime

public struct MarketplaceArtifact: Codable, Sendable, Equatable {
    public var platform: String
    public var architecture: String
    public var downloadURL: String?
    public var sha256: String?
    public var signature: PluginSignature?
    public var size: Int64
    public var status: String
    public var error: String?

    private enum CodingKeys: String, CodingKey {
        case platform, architecture, downloadURL, sha256, signature, size
        case status, error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decode(String.self, forKey: .platform)
        architecture = try c.decode(String.self, forKey: .architecture)
        downloadURL = try c.decodeIfPresent(String.self, forKey: .downloadURL)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        signature = try c.decodeIfPresent(PluginSignature.self, forKey: .signature)
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? (downloadURL == nil ? "pending" : "ready")
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

public struct MarketplaceTarget: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var platform: String
    public var architecture: String

    public var id: String { "\(platform)/\(architecture)" }
    public var title: String {
        switch platform {
        case "macos": return "macOS · \(architecture)"
        case "windows": return "Windows · \(architecture)"
        case "linux": return "Linux · \(architecture)"
        default: return id
        }
    }

    public init(platform: String, architecture: String) {
        self.platform = platform
        self.architecture = architecture
    }

    public static let defaultTargets = [
        MarketplaceTarget(platform: "macos", architecture: "arm64"),
        MarketplaceTarget(platform: "macos", architecture: "x64"),
        MarketplaceTarget(platform: "windows", architecture: "x64"),
        MarketplaceTarget(platform: "linux", architecture: "x64"),
    ]
}

public struct MarketplaceEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String
    public var author: String
    /// native — the Marketplace accepts only compiled native plugins.
    public var tier: String
    public var homepage: String?
    public var license: String?
    public var verificationStatus: String
    public var sourceVisibility: String
    public var sourceURL: String?
    public var downloadURL: String?
    public var sha256: String?
    public var signature: PluginSignature?
    public var artifacts: [MarketplaceArtifact]
    public var screenshots: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, author, tier, homepage, license, verificationStatus, sourceVisibility, sourceURL, downloadURL, sha256, signature, artifacts, screenshots
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        tier = try c.decodeIfPresent(String.self, forKey: .tier) ?? "native"
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        verificationStatus = try c.decodeIfPresent(String.self, forKey: .verificationStatus) ?? "unverified"
        sourceVisibility = try c.decodeIfPresent(String.self, forKey: .sourceVisibility) ?? "public"
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        downloadURL = try c.decodeIfPresent(String.self, forKey: .downloadURL)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        signature = try c.decodeIfPresent(PluginSignature.self, forKey: .signature)
        artifacts = try c.decodeIfPresent([MarketplaceArtifact].self, forKey: .artifacts) ?? []
        screenshots = try c.decodeIfPresent([String].self, forKey: .screenshots) ?? []
    }

    public var currentArtifact: MarketplaceArtifact? {
        artifacts.first {
            $0.platform.caseInsensitiveCompare("macos") == .orderedSame
                && $0.architecture.caseInsensitiveCompare(Self.currentArchitecture) == .orderedSame
        }
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
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

public struct MarketplaceOwnedArtifact: Codable, Sendable, Identifiable, Equatable {
    public var platform: String
    public var architecture: String
    public var status: String
    public var error: String?

    public var id: String { "\(platform)/\(architecture)" }

    private enum CodingKeys: String, CodingKey {
        case platform, architecture
        case status = "build_status"
        case error = "build_error"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decode(String.self, forKey: .platform)
        architecture = try c.decode(String.self, forKey: .architecture)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

public struct MarketplaceOwnedRelease: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var pluginID: String
    public var version: String
    public var license: String
    public var status: String
    public var createdAt: String
    public var artifacts: [MarketplaceOwnedArtifact]

    private enum CodingKeys: String, CodingKey {
        case id
        case pluginID = "plugin_id"
        case version, license, status
        case createdAt = "created_at"
        case artifacts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pluginID = try c.decode(String.self, forKey: .pluginID)
        version = try c.decode(String.self, forKey: .version)
        license = try c.decodeIfPresent(String.self, forKey: .license) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "published"
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        artifacts = try c.decodeIfPresent([MarketplaceOwnedArtifact].self, forKey: .artifacts) ?? []
    }
}

public struct MarketplaceOwnedPlugin: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var license: String
    public var verificationStatus: String
    public var sourceVisibility: String
    public var unpublishedAt: String?
    public var releases: [MarketplaceOwnedRelease]

    private enum CodingKeys: String, CodingKey {
        case id, name, license
        case verificationStatus = "verification_status"
        case sourceVisibility = "source_visibility"
        case unpublishedAt = "unpublished_at"
        case releases
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        license = try c.decodeIfPresent(String.self, forKey: .license) ?? ""
        verificationStatus = try c.decodeIfPresent(String.self, forKey: .verificationStatus) ?? "unverified"
        sourceVisibility = try c.decodeIfPresent(String.self, forKey: .sourceVisibility) ?? "public"
        unpublishedAt = try c.decodeIfPresent(String.self, forKey: .unpublishedAt)
        releases = try c.decodeIfPresent([MarketplaceOwnedRelease].self, forKey: .releases) ?? []
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
    @Published public private(set) var ownedPlugins: [MarketplaceOwnedPlugin] = []

    public var indexURL: URL
    public let session: MarketplaceSession
    public let forks: MarketplaceForkStore
    private let catalog: PluginCatalog
    private let installer: PluginInstaller

    public init(indexURL: URL, catalog: PluginCatalog, session: MarketplaceSession = MarketplaceSession()) {
        self.indexURL = indexURL
        self.catalog = catalog
        self.session = session
        self.forks = MarketplaceForkStore(catalog: catalog)
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
            guard indexURL.scheme?.lowercased() == "https" else {
                throw PluginError.package("Marketplace registry must use HTTPS")
            }
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
            for entry in entries {
                forks.markUpstreamVersion(entry.version, for: entry.id)
            }
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

    public func refreshOwnedPlugins() async {
        guard session.isSignedIn else {
            ownedPlugins = []
            return
        }
        do {
            let (data, response) = try await session.authorizedData(path: "api/marketplace/me/plugins")
            guard (200..<300).contains(response.statusCode) else {
                throw MarketplaceSessionError.requestFailed(response.statusCode, String(decoding: data, as: UTF8.self))
            }
            struct Response: Decodable { var plugins: [MarketplaceOwnedPlugin] }
            ownedPlugins = try JSONDecoder().decode(Response.self, from: data).plugins
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Downloads, verifies, unpacks, and refreshes a signed native package.
    /// MarketplaceView asks for explicit user consent before reaching this path.
    public func install(_ entry: MarketplaceEntry) async throws {
        guard let artifact = entry.currentArtifact,
              artifact.status == "ready",
              let downloadURL = artifact.downloadURL,
              let sha256 = artifact.sha256,
              let signature = artifact.signature,
              let url = URL(string: downloadURL),
              url.scheme?.lowercased() == "https" else {
            throw PluginError.package("bad download URL for \(entry.id)")
        }
        busyIDs.insert(entry.id)
        defer { busyIDs.remove(entry.id) }
        _ = try await installer.installRemote(
            url: url,
            sha256: sha256,
            signature: signature,
            // MarketplaceView asks for explicit consent before calling install;
            // once accepted, native code is enabled immediately as promised.
            trust: .trusted,
            expectedID: entry.id,
            expectedVersion: entry.version,
            requireLicense: true
        )
    }

    public func remove(_ id: String) throws {
        try installer.remove(id: id)
    }

    public func unpublish(_ id: String) async throws {
        let (data, response) = try await session.authorizedData(
            path: "api/marketplace/plugins/\(id)",
            method: "DELETE"
        )
        guard (200..<300).contains(response.statusCode) else {
            throw MarketplaceSessionError.requestFailed(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        await refreshOwnedPlugins()
        await refresh()
    }
}
