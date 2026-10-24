// Copyright (c) 2026 DOTS
// Frontmatter, parsing and file helpers.

import CryptoKit
import Foundation
import PluginRuntime

extension WorkspaceMemory {
    func frontmatter(_ fields: [String: String], tags: [String], links: [String]) -> String {
        var lines = ["---"]
        for key in fields.keys.sorted() { lines.append("\(key): \(fields[key] ?? "")") }
        lines.append("tags: [\(tags.joined(separator: ", "))]")
        lines.append("links: [\(links.map { "\"\($0)\"" }.joined(separator: ", "))]")
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    func parseFrontmatter(_ text: String) -> [String: String] {
        guard text.hasPrefix("---\n") else { return [:] }
        let rest = text.dropFirst(4)
        guard let end = rest.range(of: "\n---") else { return [:] }
        var result: [String: String] = [:]
        for line in rest[..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }

    func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---\n") else { return text }
        let rest = text.dropFirst(4)
        guard let end = rest.range(of: "\n---") else { return text }
        return String(rest[rest.index(end.upperBound, offsetBy: 0)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parseList(_ raw: String?) -> [String] {
        guard var value = raw, value.hasPrefix("["), value.hasSuffix("]") else { return [] }
        value = String(value.dropFirst().dropLast())
        return value.split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            .filter { !$0.isEmpty }
    }

    func extractWikilinks(_ text: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        var search = text.startIndex
        while let open = text.range(of: "[[", range: search..<text.endIndex),
              let close = text.range(of: "]]", range: open.upperBound..<text.endIndex) {
            let target = String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !target.isEmpty, seen.insert(target).inserted { result.append(target) }
            search = close.upperBound
        }
        return result
    }

    func quoted(_ text: String, limit: Int) -> String {
        "\"\(sanitize(text, limit: limit).replacingOccurrences(of: "\"", with: "'"))\""
    }

    func unquoted(_ text: String) -> String {
        var value = text
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    func taskNoteField(_ name: String, in lines: [String]) -> String {
        lines.first { $0.hasPrefix("\(name):") }
            .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: " \"")) } ?? ""
    }

    func eventWithoutSignature(_ object: [String: Any]) -> [String: Any] {
        object.filter { $0.key != "signature" }
    }

    func parseArguments(_ call: AgentToolCall) -> [String: Any]? {
        guard let data = call.arguments.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func safeWorkspaceURL(_ path: String, workspace: URL) -> URL? {
        let url = URL(fileURLWithPath: path.isEmpty ? "." : path, relativeTo: workspace).standardizedFileURL
        let root = workspace.standardizedFileURL.path
        let memory = root + "/.mem"
        guard (url.path == root || url.path.hasPrefix(root + "/")), url.path != memory, !url.path.hasPrefix(memory + "/") else { return nil }
        return url
    }

    func safePath(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.split(separator: "/").contains(where: { $0 == ".env" || $0.lowercased().contains("secret") || $0.lowercased().contains("token") }) { return "<redacted>" }
        return String(normalized.prefix(300))
    }

    func sanitize(_ text: String, limit: Int) -> String {
        SecretRedaction.sanitize(text, limit: limit)
    }

    func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static let isoFormatter = ISO8601DateFormatter()
    func isoNow() -> String { Self.isoFormatter.string(from: Date()) }

    func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Project state only. Schema 2 dropped the per-person and per-chat fields that
    /// schema 1 kept here; a state file without this version is rebuilt on load.
    static func emptyState() -> [String: Any] {
        [
            "schemaVersion": stateSchemaVersion,
            "revision": 0,
            "projectDefaults": [String: Any](),
            "acceptedDecisions": [[String: Any]](),
            "pendingProposals": [[String: Any]](),
            "supersededValues": [[String: Any]](),
            "lastMapRevision": 0,
        ]
    }

    static let stateSchemaVersion = 2

    /// Appends one JSON object as a line. The user layer's logs are append-only, so a
    /// crash loses at most the line being written.
    func appendJSONLine(_ object: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}

/// Collapses whitespace and redacts credentials. Called for every task note and tool
/// record; the patterns are compiled once instead of on every call.
enum SecretRedaction {
    nonisolated(unsafe) private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)
    nonisolated(unsafe) private static let secrets = [
        #"(?i)(api[_-]?key|token|password|secret)\s*[:=]\s*[^\s,;]+"#,
        #"(?i)bearer\s+[A-Za-z0-9._\-]+"#,
        #"(?i)authorization\s*:\s*[^\s,;]+"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func sanitize(_ text: String, limit: Int) -> String {
        var result = text.replacingMatches(of: whitespace, with: " ")
        for pattern in secrets { result = result.replacingMatches(of: pattern, with: "[redacted]") }
        return String(result.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

extension String {
    /// `replacingOccurrences(of:options: .regularExpression)` with a precompiled pattern.
    func replacingMatches(of regex: NSRegularExpression, with template: String) -> String {
        regex.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }
}
