// Copyright (c) 2026 DOTS
// Reads the user's ~/.ssh/config for the remote work-location picker and
// writes back only the stanzas the app itself created.

import Foundation

public enum SSHConfigStore {
    static let beginMarker = "# >>> DotsHarness managed host: "
    static let endMarker = "# <<< DotsHarness managed host: "

    // MARK: - Parsing

    /// Parses `Host` stanzas into pickable hosts.
    ///
    /// Pattern stanzas (`Host *`, `!bastion`, `web?`) and `Match` blocks are
    /// skipped: they configure other connections rather than name one machine,
    /// so they are not destinations a user can pick. `Include` is followed one
    /// level deep for reading — many configs keep their hosts in `config.d/*` —
    /// but the app never writes into an included file.
    public static func parse(
        _ text: String,
        includeLoader: ((String) -> String?)? = nil,
        followIncludes: Bool = true
    ) -> [SSHHost] {
        var hosts: [SSHHost] = []
        var managedAliases: Set<String> = []
        var currentAlias: String?
        var currentIsPattern = false
        var currentManaged = false
        var fields: [String: String] = [:]
        var skippingMatch = false

        func flush() {
            defer {
                currentAlias = nil
                currentIsPattern = false
                currentManaged = false
                fields = [:]
            }
            guard let alias = currentAlias, !currentIsPattern else { return }
            let hostName = fields["hostname"] ?? alias
            let user = fields["user"] ?? ""
            let port = fields["port"].flatMap(Int.init) ?? 22
            hosts.append(
                SSHHost(
                    alias: alias,
                    hostName: hostName,
                    user: user,
                    port: (1...65535).contains(port) ? port : 22,
                    identityFile: fields["identityfile"],
                    managedByApp: currentManaged || managedAliases.contains(alias)
                )
            )
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(beginMarker) {
                managedAliases.insert(String(line.dropFirst(beginMarker.count)).trimmingCharacters(in: .whitespaces))
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }

            guard let (keyword, value) = splitDirective(line) else { continue }
            switch keyword {
            case "host":
                flush()
                skippingMatch = false
                let aliases = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard let first = aliases.first else { continue }
                currentAlias = first
                currentIsPattern = aliases.contains { $0.contains("*") || $0.contains("?") || $0.hasPrefix("!") }
                currentManaged = managedAliases.contains(first)
            case "match":
                flush()
                skippingMatch = true
            case "include":
                guard followIncludes, !skippingMatch else { continue }
                for pattern in value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
                    for path in expandIncludePaths(pattern) {
                        guard let included = includeLoader?(path) ?? defaultIncludeLoader(path) else { continue }
                        hosts.append(contentsOf: parse(included, includeLoader: includeLoader, followIncludes: false))
                    }
                }
            default:
                guard !skippingMatch, currentAlias != nil else { continue }
                if fields[keyword] == nil { fields[keyword] = value }
            }
        }
        flush()

        // First stanza wins, the way ssh itself resolves a repeated alias.
        var seen: Set<String> = []
        return hosts.filter { seen.insert($0.alias).inserted }
    }

    /// `Keyword value`, `Keyword=value` and quoted values, comments stripped.
    static func splitDirective(_ line: String) -> (String, String)? {
        var body = line
        if let hash = body.firstIndex(of: "#") { body = String(body[body.startIndex..<hash]) }
        body = body.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        let separators: Set<Character> = [" ", "\t", "="]
        guard let splitIndex = body.firstIndex(where: { separators.contains($0) }) else { return nil }
        let keyword = String(body[body.startIndex..<splitIndex]).lowercased()
        var value = String(body[body.index(after: splitIndex)...])
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        guard !keyword.isEmpty, !value.isEmpty else { return nil }
        return (keyword, value)
    }

    private static func expandIncludePaths(_ pattern: String) -> [String] {
        var path = pattern
        if path.hasPrefix("~/") {
            path = NSHomeDirectory() + String(path.dropFirst(1))
        } else if !path.hasPrefix("/") {
            path = NSHomeDirectory() + "/.ssh/" + path
        }
        guard path.contains("*") || path.contains("?") else { return [path] }
        let directory = (path as NSString).deletingLastPathComponent
        let glob = (path as NSString).lastPathComponent
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return entries
            .filter { fnmatch(glob, $0, 0) == 0 }
            .sorted()
            .map { directory + "/" + $0 }
    }

    private static func defaultIncludeLoader(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - Rendering

    public static func render(_ host: SSHHost) -> String {
        var lines = [
            beginMarker + host.alias,
            "Host \(host.alias)",
            "    HostName \(host.hostName)",
        ]
        if !host.user.isEmpty { lines.append("    User \(host.user)") }
        lines.append("    Port \(host.port)")
        if let identityFile = host.identityFile, !identityFile.isEmpty {
            lines.append("    IdentityFile \(identityFile)")
            lines.append("    IdentitiesOnly yes")
        }
        lines.append(endMarker + host.alias)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Adds or replaces the app's own stanza for `host`. Everything outside the
    /// app's markers is preserved byte for byte, and an alias that already
    /// exists in a hand-written stanza is refused rather than rewritten.
    public static func upsert(_ host: SSHHost, into text: String) throws -> String {
        guard isValidAlias(host.alias) else {
            throw SSHError.configWriteFailed(host.alias)
        }
        let existingUnmanaged = parse(stripManagedBlocks(text), followIncludes: false)
        if existingUnmanaged.contains(where: { $0.alias == host.alias }) {
            throw SSHError.configWriteFailed(host.alias)
        }
        var body = removeManagedBlock(alias: host.alias, from: text)
        if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
        if !body.isEmpty { body += "\n" }
        return body + render(host)
    }

    public static func remove(alias: String, from text: String) -> String {
        removeManagedBlock(alias: alias, from: text)
    }

    /// True when the alias is safe as a config token and as an ssh argument.
    public static func isValidAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty, alias.count <= 64, !alias.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return alias.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func stripManagedBlocks(_ text: String) -> String {
        var kept: [String] = []
        var inside = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(beginMarker) { inside = true; continue }
            if trimmed.hasPrefix(endMarker) { inside = false; continue }
            if !inside { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    private static func removeManagedBlock(alias: String, from text: String) -> String {
        var kept: [String] = []
        var inside = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == beginMarker + alias { inside = true; continue }
            if inside {
                if trimmed == endMarker + alias { inside = false }
                continue
            }
            kept.append(line)
        }
        var result = kept.joined(separator: "\n")
        while result.hasSuffix("\n\n\n") { result.removeLast() }
        return result
    }
}

/// File-level access to `~/.ssh/config`, kept apart from the pure string logic
/// above so the parser and writer stay unit-testable without touching a disk.
public struct SSHConfigFile {
    public let url: URL
    private var fileManager: FileManager { .default }

    public init(url: URL? = nil) {
        self.url = url ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config")
    }

    public func read() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    public func hosts() -> [SSHHost] {
        SSHConfigStore.parse(read())
    }

    public func add(_ host: SSHHost) throws {
        try write(try SSHConfigStore.upsert(host, into: read()))
    }

    public func remove(alias: String) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try write(SSHConfigStore.remove(alias: alias, from: read()))
    }

    /// Atomic: a crash or a full disk leaves the previous config intact rather
    /// than a half-written one that could lock the user out of every host.
    private func write(_ text: String) throws {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let backup = url.appendingPathExtension("dots-backup")
        if fileManager.fileExists(atPath: url.path), !fileManager.fileExists(atPath: backup.path) {
            try? fileManager.copyItem(at: url, to: backup)
        }
        let temporary = directory.appendingPathComponent("config.dots-\(UUID().uuidString)")
        var body = text
        if !body.hasSuffix("\n") { body += "\n" }
        try body.write(to: temporary, atomically: false, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
    }
}
