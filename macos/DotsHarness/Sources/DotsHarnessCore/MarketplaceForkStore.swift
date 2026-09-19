// Copyright (c) 2026 DOTS
// Local, non-destructive Marketplace forks.

import Foundation
import HarnessPluginKit
import PluginRuntime

public struct MarketplaceFork: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var upstreamID: String
    public var upstreamVersion: String
    public var upstreamVersionAvailable: String?
    public var customized: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        upstreamID: String,
        upstreamVersion: String,
        upstreamVersionAvailable: String? = nil,
        customized: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.upstreamID = upstreamID
        self.upstreamVersion = upstreamVersion
        self.upstreamVersionAvailable = upstreamVersionAvailable
        self.customized = customized
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@MainActor
public final class MarketplaceForkStore: ObservableObject {
    @Published public private(set) var forks: [MarketplaceFork] = []

    public let catalog: PluginCatalog
    private let fileManager = FileManager.default

    public init(catalog: PluginCatalog) {
        self.catalog = catalog
        load()
    }

    private var storeURL: URL {
        catalog.paths.root.appendingPathComponent("marketplace-forks.json")
    }

    public func fork(for upstreamID: String) -> MarketplaceFork? {
        forks.first { $0.upstreamID == upstreamID }
    }

    public func hasFork(for upstreamID: String) -> Bool {
        fork(for: upstreamID) != nil
    }

    public func folder(for fork: MarketplaceFork) -> URL {
        catalog.paths.plugins.appendingPathComponent(fork.id, isDirectory: true)
    }

    @discardableResult
    public func createFork(upstreamID: String, upstreamVersion: String) throws -> MarketplaceFork {
        if let existing = fork(for: upstreamID) { return existing }
        guard let source = catalog.entries.first(where: { $0.manifest.id == upstreamID })?.url,
              fileManager.fileExists(atPath: source.path) else {
            throw PluginError.package("installed Marketplace source for \(upstreamID) was not found")
        }
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        let forkID = "\(upstreamID).fork.\(suffix)"
        let fork = MarketplaceFork(id: forkID, upstreamID: upstreamID, upstreamVersion: upstreamVersion)
        let destination = folder(for: fork)
        try fileManager.createDirectory(at: catalog.paths.plugins, withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
        try rewriteManifest(at: destination, id: forkID, upstreamID: upstreamID)
        forks.append(fork)
        persist()
        catalog.refresh()
        // A fork starts disabled and untrusted. Editing source never silently
        // grants native execution rights.
        catalog.setTrust(forkID, .untrusted)
        catalog.setEnabled(forkID, false)
        return fork
    }

    public func setDisabled(_ fork: MarketplaceFork, _ disabled: Bool) {
        catalog.setEnabled(fork.id, !disabled && catalog.entries.first(where: { $0.manifest.id == fork.id })?.trust == .trusted)
    }

    public func acceptAndEnable(_ fork: MarketplaceFork) {
        catalog.setTrust(fork.id, .trusted)
        catalog.setEnabled(fork.id, true)
    }

    public func delete(_ fork: MarketplaceFork) throws {
        let target = folder(for: fork)
        guard target.standardizedFileURL.path.hasPrefix(catalog.paths.plugins.standardizedFileURL.path),
              fileManager.fileExists(atPath: target.path) else {
            throw PluginError.package("fork not found")
        }
        try fileManager.removeItem(at: target)
        forks.removeAll { $0.id == fork.id }
        persist()
        catalog.refresh()
    }

    public func export(_ fork: MarketplaceFork, to destination: URL) throws {
        guard fileManager.fileExists(atPath: folder(for: fork).path) else {
            throw PluginError.package("fork not found")
        }
        try PluginPackage.pack(folder: folder(for: fork), to: destination)
    }

    public func markUpstreamVersion(_ version: String, for upstreamID: String) {
        guard let index = forks.firstIndex(where: { $0.upstreamID == upstreamID }),
              let available = SemVer(version),
              let current = SemVer(forks[index].upstreamVersion),
              current < available else { return }
        forks[index].upstreamVersionAvailable = version
        forks[index].updatedAt = Date()
        persist()
    }

    /// Explicitly accepts upstream metadata while preserving the fork folder.
    /// The source and native library are never overwritten automatically.
    public func acknowledgeUpstream(_ fork: MarketplaceFork, version: String) {
        guard let index = forks.firstIndex(where: { $0.id == fork.id }) else { return }
        forks[index].upstreamVersion = version
        forks[index].upstreamVersionAvailable = nil
        forks[index].updatedAt = Date()
        persist()
    }

    private func rewriteManifest(at folder: URL, id: String, upstreamID: String) throws {
        let url = folder.appendingPathComponent("plugin.yml")
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var idFound = false
        var nameFound = false
        for index in lines.indices {
            if lines[index].hasPrefix("id:") {
                lines[index] = "id: \(id)"
                idFound = true
            } else if lines[index].hasPrefix("name:") {
                lines[index] += " (Özelleştirildi)"
                nameFound = true
            }
        }
        if !idFound { lines.insert("id: \(id)", at: 0) }
        if !nameFound { lines.insert("name: \(id) (Özelleştirildi)", at: 1) }
        lines.append("# DOTS upstream: \(upstreamID)")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([MarketplaceFork].self, from: data) else { return }
        forks = decoded.filter { fileManager.fileExists(atPath: folder(for: $0).path) }
    }

    private func persist() {
        try? fileManager.createDirectory(at: catalog.paths.root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(forks) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}
