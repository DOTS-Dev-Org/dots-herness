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
    public var releaseID: String
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
    public var catalogScope: String
    public var category: String
    public var categoryConfidence: Double
    public var riskLevel: String
    public var permissions: [String]
    public var moderationStatus: String
    /// Listing metrics; nil until the registry serves them.
    public var publishedAt: String?
    public var downloads: Int?
    public var likes: Int?
    public var featured: Bool

    enum CodingKeys: String, CodingKey {
        case id, releaseID, name, version, description, author, tier, homepage, license, verificationStatus, sourceVisibility, sourceURL, downloadURL, sha256, signature, artifacts, screenshots
        case catalogScope, category, categoryConfidence, riskLevel, permissions, moderationStatus
        case publishedAt, downloads, likes, featured
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        releaseID = try c.decodeIfPresent(String.self, forKey: .releaseID) ?? id
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
        catalogScope = try c.decodeIfPresent(String.self, forKey: .catalogScope) ?? "community"
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "other"
        categoryConfidence = try c.decodeIfPresent(Double.self, forKey: .categoryConfidence) ?? 0
        riskLevel = try c.decodeIfPresent(String.self, forKey: .riskLevel) ?? "unknown"
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        moderationStatus = try c.decodeIfPresent(String.self, forKey: .moderationStatus) ?? "pending_review"
        publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
        downloads = try c.decodeIfPresent(Int.self, forKey: .downloads)
        likes = try c.decodeIfPresent(Int.self, forKey: .likes)
        featured = try c.decodeIfPresent(Bool.self, forKey: .featured) ?? false
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
    public var moderationStatus: String
    public var catalogScope: String
    public var category: String
    public var categoryConfidence: Double
    public var categorySource: String
    public var riskLevel: String
    public var riskFlags: [String]
    public var permissions: [String]
    public var moderationScores: [String: Double]
    public var moderationReason: String
    public var moderationModel: String?
    public var reviewedAt: String?
    public var reviewNotes: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case pluginID = "plugin_id"
        case version, license, status
        case createdAt = "created_at"
        case artifacts
        case moderationStatus = "moderation_status"
        case catalogScope = "catalog_scope"
        case category, categoryConfidence = "category_confidence"
        case categorySource = "category_source"
        case riskLevel = "risk_level"
        case riskFlags = "risk_flags"
        case permissions
        case moderationScores = "moderation_scores"
        case moderationReason = "moderation_reason"
        case moderationModel = "moderation_model"
        case reviewedAt = "reviewed_at"
        case reviewNotes = "review_notes"
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
        moderationStatus = try c.decodeIfPresent(String.self, forKey: .moderationStatus) ?? "pending_review"
        catalogScope = try c.decodeIfPresent(String.self, forKey: .catalogScope) ?? "community"
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "other"
        categoryConfidence = try c.decodeIfPresent(Double.self, forKey: .categoryConfidence) ?? 0
        categorySource = try c.decodeIfPresent(String.self, forKey: .categorySource) ?? "pending"
        riskLevel = try c.decodeIfPresent(String.self, forKey: .riskLevel) ?? "unknown"
        riskFlags = try c.decodeIfPresent([String].self, forKey: .riskFlags) ?? []
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        moderationScores = try c.decodeIfPresent([String: Double].self, forKey: .moderationScores) ?? [:]
        moderationReason = try c.decodeIfPresent(String.self, forKey: .moderationReason) ?? ""
        moderationModel = try c.decodeIfPresent(String.self, forKey: .moderationModel)
        reviewedAt = try c.decodeIfPresent(String.self, forKey: .reviewedAt)
        reviewNotes = try c.decodeIfPresent(String.self, forKey: .reviewNotes)
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

/// A project scaffold listing as the catalog serves it.
public struct MarketStarter: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var systemImage: String?
    public var category: String?
    public var title: String?
    public var detail: String?
    /// Sent to the agent as written.
    public var prompt: String
    public var downloads: Int?
    public var likes: Int?
    public var featured: Bool?
}

@MainActor
public final class MarketplaceClient: ObservableObject {
    // Read from the API host: the dots.net.tr/harness route does not reach the worker.
    public static let defaultIndex = MarketplaceSession.defaultAPIBase.absoluteString + "/harness/registry.json"
    public static let defaultCommunityIndex = MarketplaceSession.defaultAPIBase.absoluteString + "/harness/community-registry.json"

    @Published public private(set) var entries: [MarketplaceEntry] = []
    @Published public private(set) var communityEntries: [MarketplaceEntry] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var busyIDs: Set<String> = []
    @Published public private(set) var ownedPlugins: [MarketplaceOwnedPlugin] = []
    @Published public private(set) var likedIDs: Set<String> = []
    /// Liked skills and starters, keyed by catalog kind ("skill", "starter").
    @Published public private(set) var likedCatalog: [String: Set<String>] = [:]
    @Published public private(set) var starters: [MarketStarter] = []

    public var indexURL: URL
    public var communityIndexURL: URL
    public let session: MarketplaceSession
    public let forks: MarketplaceForkStore
    private let catalog: PluginCatalog
    private let installer: PluginInstaller

    public init(
        indexURL: URL,
        catalog: PluginCatalog,
        session: MarketplaceSession = MarketplaceSession(),
        communityIndexURL: URL = URL(string: MarketplaceClient.defaultCommunityIndex)!
    ) {
        self.indexURL = indexURL
        self.communityIndexURL = communityIndexURL
        self.catalog = catalog
        self.session = session
        self.forks = MarketplaceForkStore(catalog: catalog)
        self.installer = PluginInstaller(catalog: catalog)
        loadCached()
    }

    private var cacheURL: URL {
        catalog.paths.runtime.appendingPathComponent("marketplace.json")
    }

    private var startersCacheURL: URL {
        catalog.paths.runtime.appendingPathComponent("marketplace-starters.json")
    }

    private var communityCacheURL: URL {
        catalog.paths.runtime.appendingPathComponent("marketplace-community.json")
    }

    public func loadCached() {
        if let data = try? Data(contentsOf: cacheURL),
           let index = try? JSONDecoder().decode(MarketplaceIndex.self, from: data),
           index.version >= 3 {
            entries = index.plugins
        }
        if let data = try? Data(contentsOf: communityCacheURL),
           let index = try? JSONDecoder().decode(MarketplaceIndex.self, from: data),
           index.version >= 3 {
            communityEntries = index.plugins
        }
        if let data = try? Data(contentsOf: startersCacheURL),
           let cached = try? JSONDecoder().decode([MarketStarter].self, from: data) {
            starters = cached
        }
    }

    /// Raw skills or starters catalog from the API host; nil when offline or malformed upstream.
    public func catalogData(_ name: String) async -> Data? {
        var request = URLRequest(url: session.apiBase.appendingPathComponent("harness/\(name).json"), timeoutInterval: 30)
        request.setValue("DotsHarness", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    public func refreshStarters() async {
        guard let data = await catalogData("starters"),
              let fresh = try? JSONDecoder().decode([MarketStarter].self, from: data) else { return }
        starters = fresh
        persist(data, at: startersCacheURL)
    }

    /// Reports one install of a skill or one use of a starter; returns the server's count.
    @discardableResult
    public func recordCatalogDownload(kind: String, id: String) async -> Int? {
        var request = URLRequest(url: session.apiBase.appendingPathComponent("harness/catalog/\(kind)/\(id)/download"))
        request.httpMethod = "POST"
        request.setValue("DotsHarness", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let downloads = (try? JSONDecoder().decode([String: Int].self, from: data))?["downloads"] else { return nil }
        if kind == "starter", let index = starters.firstIndex(where: { $0.id == id }) { starters[index].downloads = downloads }
        return downloads
    }

    /// Likes a skill or starter; returns the server's count.
    @discardableResult
    public func setCatalogLiked(_ liked: Bool, kind: String, id: String) async throws -> Int {
        let (data, response) = try await session.authorizedData(
            path: "api/marketplace/catalog/\(kind)/\(id)/like",
            method: "POST",
            body: try JSONEncoder().encode(["liked": liked]),
            contentType: "application/json"
        )
        guard (200..<300).contains(response.statusCode),
              let likes = (try? JSONDecoder().decode([String: Int].self, from: data))?["likes"] else {
            throw MarketplaceSessionError.requestFailed(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        if liked { likedCatalog[kind, default: []].insert(id) } else { likedCatalog[kind]?.remove(id) }
        if kind == "starter", let index = starters.firstIndex(where: { $0.id == id }) { starters[index].likes = likes }
        return likes
    }

    public func refresh() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            let (data, index) = try await fetchIndex(at: indexURL)
            entries = index.plugins
            for entry in entries { forks.markUpstreamVersion(entry.version, for: entry.id) }
            persist(data, at: cacheURL)
        } catch {
            lastError = error.localizedDescription
        }
        do {
            let (data, index) = try await fetchIndex(at: communityIndexURL)
            communityEntries = index.plugins
            persist(data, at: communityCacheURL)
        } catch {
            if lastError == nil { lastError = "Community registry: \(error.localizedDescription)" }
        }
    }

    private func fetchIndex(at url: URL) async throws -> (Data, MarketplaceIndex) {
        guard url.scheme?.lowercased() == "https" else {
            throw PluginError.package("Marketplace registry must use HTTPS")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("DotsHarness", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PluginError.package("registry HTTP \(status)")
        }
        let index = try JSONDecoder().decode(MarketplaceIndex.self, from: data)
        guard index.version >= 3 else {
            throw PluginError.package("Marketplace registry is missing moderation metadata")
        }
        return (data, index)
    }

    private func persist(_ data: Data, at url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
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

    public func refreshLikes() async {
        guard session.isSignedIn else {
            likedIDs = []
            likedCatalog = [:]
            return
        }
        guard let (data, response) = try? await session.authorizedData(path: "api/marketplace/me/likes"),
              response.statusCode == 200,
              let ids = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        likedIDs = Set(ids["plugin_ids"] ?? [])
        likedCatalog = ["skill": Set(ids["skill_ids"] ?? []), "starter": Set(ids["starter_ids"] ?? [])]
    }

    /// The server owns the count: the listing shows whatever it answers, never a local guess.
    public func setLiked(_ liked: Bool, id: String) async throws {
        let (data, response) = try await session.authorizedData(
            path: "api/marketplace/plugins/\(id)/like",
            method: "POST",
            body: try JSONEncoder().encode(["liked": liked]),
            contentType: "application/json"
        )
        guard (200..<300).contains(response.statusCode),
              let likes = (try? JSONDecoder().decode([String: Int].self, from: data))?["likes"] else {
            throw MarketplaceSessionError.requestFailed(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        if liked { likedIDs.insert(id) } else { likedIDs.remove(id) }
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].likes = likes }
        if let index = communityEntries.firstIndex(where: { $0.id == id }) { communityEntries[index].likes = likes }
    }

    public func report(
        _ entry: MarketplaceEntry,
        reason: String,
        details: String = ""
    ) async throws {
        let body: [String: Any] = [
            "release_id": entry.releaseID,
            "reason": reason,
            "details": details,
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (responseData, response) = try await session.authorizedData(
            path: "api/marketplace/plugins/\(entry.id)/reports",
            method: "POST",
            body: data,
            contentType: "application/json"
        )
        guard (200..<300).contains(response.statusCode) else {
            throw MarketplaceSessionError.requestFailed(response.statusCode, String(decoding: responseData, as: UTF8.self))
        }
    }

    /// Downloads, verifies, unpacks, and refreshes a signed native package.
    /// MarketplaceView asks for explicit user consent before reaching this path.
    public func install(_ entry: MarketplaceEntry) async throws {
        guard entry.moderationStatus == "approved" else {
            throw PluginError.package("plugin is not approved for Marketplace installation")
        }
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
