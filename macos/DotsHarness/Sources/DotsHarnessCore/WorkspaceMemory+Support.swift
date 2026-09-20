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

    var rootPublicKeyString: String? { (manifest?["rootAuthority"] as? [String: Any])?["publicKey"] as? String }
    var rootDeviceID: String? { (manifest?["rootAuthority"] as? [String: Any])?["deviceId"] as? String }
    var rootPublicKey: P256.Signing.PublicKey? {
        guard let value = rootPublicKeyString, let data = Data(base64Encoded: value) else { return nil }
        return try? P256.Signing.PublicKey(rawRepresentation: data)
    }

    func verify(signature: String, object: [String: Any], publicKey: P256.Signing.PublicKey) -> Bool {
        guard let signatureData = Data(base64Encoded: signature),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return false }
        return publicKey.isValidSignature(signature, for: data)
    }

    func invitationWithoutSignature(_ object: [String: Any]) -> [String: Any] {
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
        var result = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let patterns = [
            #"(?i)(api[_-]?key|token|password|secret)\s*[:=]\s*[^\s,;]+"#,
            #"(?i)bearer\s+[A-Za-z0-9._\-]+"#,
            #"(?i)authorization\s*:\s*[^\s,;]+"#,
        ]
        for pattern in patterns { result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression) }
        return String(result.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
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

    static func emptyState() -> [String: Any] {
        [
            "revision": 0,
            "members": [[String: Any]](),
            "projectDefaults": [String: Any](),
            "activePreferences": [String: Any](),
            "acceptedDecisions": [[String: Any]](),
            "pendingProposals": [[String: Any]](),
            "supersededValues": [[String: Any]](),
            "conversationStates": [String: Any](),
            "lastMapRevision": 0,
        ]
    }
}
