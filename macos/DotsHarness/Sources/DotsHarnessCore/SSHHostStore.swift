// Copyright (c) 2026 DOTS
// The app's view of the user's SSH hosts: the list comes from ~/.ssh/config,
// the extra bookkeeping (which hosts we enrolled, which folder was last used)
// lives beside it in Application Support.

import Combine
import Foundation
import PluginRuntime

@MainActor
public final class SSHHostStore: ObservableObject {
    /// Per-host bookkeeping the ssh config has no place for.
    public struct Record: Codable, Sendable, Equatable {
        public var alias: String
        public var managedByApp: Bool
        public var enrolledAt: Date?
        public var lastRemotePath: String?
        public var recentRemotePaths: [String]
        /// True once the alias has disappeared from ~/.ssh/config. Kept rather
        /// than deleted so the user is told the host went missing instead of
        /// silently losing it.
        public var missing: Bool

        public init(
            alias: String,
            managedByApp: Bool = false,
            enrolledAt: Date? = nil,
            lastRemotePath: String? = nil,
            recentRemotePaths: [String] = [],
            missing: Bool = false
        ) {
            self.alias = alias
            self.managedByApp = managedByApp
            self.enrolledAt = enrolledAt
            self.lastRemotePath = lastRemotePath
            self.recentRemotePaths = recentRemotePaths
            self.missing = missing
        }
    }

    @Published public private(set) var hosts: [SSHHost] = []
    @Published public private(set) var records: [String: Record] = [:]

    private let configFile: SSHConfigFile
    private let storeURL: URL
    private let vault = ProviderVault()

    public init(configFile: SSHConfigFile = SSHConfigFile(), storeURL: URL? = nil) {
        self.configFile = configFile
        self.storeURL = storeURL ?? SupportPaths.default().root.appendingPathComponent("ssh-hosts.json")
        loadRecords()
        reload()
    }

    public var isAvailable: Bool { SSHRunner.isAvailable }

    public func host(alias: String) -> SSHHost? {
        hosts.first { $0.alias == alias }
    }

    public func record(alias: String) -> Record {
        records[alias] ?? Record(alias: alias)
    }

    /// `~/.ssh/config` is the source of truth for the list — the user may have
    /// edited it by hand or by another tool since we last looked.
    public func reload() {
        let configured = configFile.hosts()
        hosts = configured
        let aliases = Set(configured.map(\.alias))
        for (alias, var record) in records where record.missing != !aliases.contains(alias) {
            record.missing = !aliases.contains(alias)
            records[alias] = record
        }
        for host in configured where records[host.alias] == nil {
            records[host.alias] = Record(alias: host.alias, managedByApp: host.managedByApp)
        }
        saveRecords()
    }

    public func add(_ host: SSHHost, enrolled: Bool) throws {
        try configFile.add(host)
        var record = record(alias: host.alias)
        record.managedByApp = true
        if enrolled { record.enrolledAt = Date() }
        record.missing = false
        records[host.alias] = record
        saveRecords()
        reload()
    }

    public func remove(alias: String) throws {
        SSHRunner.closeMaster(alias: alias)
        try configFile.remove(alias: alias)
        records[alias] = nil
        try? vault.remove(passwordKey(alias))
        saveRecords()
        reload()
    }

    public func rememberRemotePath(alias: String, path: String) {
        var record = record(alias: alias)
        record.lastRemotePath = path
        record.recentRemotePaths = ([path] + record.recentRemotePaths.filter { $0 != path }).prefix(8).map { $0 }
        records[alias] = record
        saveRecords()
    }

    // MARK: - Optional password storage

    /// Off by default. Enrollment installs a key so the password is not needed
    /// again; this exists only for a user who explicitly wants it kept, and it
    /// goes to the Keychain — never to a file, and never to ~/.ssh/config.
    public func storePassword(_ password: String, alias: String) throws {
        try vault.set(password, for: passwordKey(alias))
    }

    public func storedPassword(alias: String) -> String? {
        try? vault.get(passwordKey(alias))
    }

    public func forgetPassword(alias: String) {
        try? vault.remove(passwordKey(alias))
    }

    private func passwordKey(_ alias: String) -> String { "ssh.password.\(alias)" }

    // MARK: - Persistence

    private func loadRecords() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else { return }
        records = decoded
    }

    private func saveRecords() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storeURL, options: .atomic)
    }
}
