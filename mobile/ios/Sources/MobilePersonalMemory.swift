import Foundation
import CryptoKit

/// Device-local preferences and operational history. This store is outside the
/// workspace, so it is never included in project snapshots or Git operations.
enum MobilePersonalMemory {
    private struct Fact {
        var kind: String
        var key: String
        var text: String
    }

    static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerNess", isDirectory: true)
    }

    static func recordPreference(
        workspace: URL,
        userRoot: URL,
        key: String,
        text: String,
        scope: String
    ) -> String {
        let normalizedKey = collapse(key, limit: 60).lowercased()
        let normalizedText = collapse(text, limit: 240)
        guard !normalizedKey.isEmpty, !normalizedText.isEmpty else {
            return "That call was not usable. Send kind \"preference\", a short key, and a one-sentence text."
        }
        guard !MobileFacts.looksLikeSecret(key: normalizedKey, text: normalizedText) else {
            return "Not recorded: that looks like a credential. Keep secrets in secure storage and record only the non-secret fact."
        }

        do {
            try FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
            if scope == "user" {
                let path = userRoot.appendingPathComponent("user-facts.md")
                var facts = read(path).filter { $0.kind != "preference" || $0.key != normalizedKey }
                facts.append(Fact(kind: "preference", key: normalizedKey, text: normalizedText))
                try render(facts).write(to: path, atomically: true, encoding: .utf8)
            } else {
                let path = userRoot.appendingPathComponent("user_profile.json")
                var profile = (try? JSONSerialization.jsonObject(with: Data(contentsOf: path))) as? [String: Any] ?? [:]
                let project = projectIdentity(workspace)
                var all = profile["projectPreferences"] as? [String: [String: String]] ?? [:]
                var preferences = all[project] ?? [:]
                guard preferences[normalizedKey] != nil || preferences.count < 40 else {
                    return "This project already has the maximum number of saved preferences."
                }
                preferences[normalizedKey] = normalizedText
                all[project] = preferences
                profile["projectPreferences"] = all
                let data = try JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: path, options: .atomic)
            }
            return "Recorded preference \(normalizedKey): \(normalizedText)"
        } catch {
            return "Device-local memory is not available here, so nothing was recorded. Continue with the work; do not retry."
        }
    }

    static func text(userRoot: URL, workspace: URL? = nil) -> String {
        let projectKeys = workspace.map { root in
            MobileFacts.projectKeys(root: root, userRoot: userRoot)
                .union(projectPreferenceKeys(userRoot: userRoot, workspace: root).map { $0.lowercased() })
        } ?? []
        let facts = read(userRoot.appendingPathComponent("user-facts.md"))
            .filter { !projectKeys.contains($0.key.lowercased()) }
        let global = facts.isEmpty ? "" : render(facts).trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = [global].filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return "" }
        return "[Personal memory, stored on this device]\nUse these user preferences when the active project has no conflicting saved rule or fact. Project memory wins over any personal memory, including project-scoped preferences; the user's current request wins over both.\n"
            + pieces.joined(separator: "\n\n")
    }

    /// A compact view of local run events. It deliberately excludes chat text,
    /// tool output, and provider payloads.
    static func activityText(events: [MobileRuntimeEvent]) -> String {
        let summaries = events.filter { $0.kind == "run.summary" }.suffix(5)
        let lines = summaries.map { summary -> String in
            let runID = summary.payload["runId"] ?? ""
            let status = summary.payload["status"] ?? "unknown"
            let files = events.filter {
                ($0.kind == "file.changed" || $0.kind == "file.deleted")
                    && $0.payload["runId"] == runID
            }.compactMap { $0.payload["path"] }.uniqued().prefix(8)
            let counts = [
                count(summary.payload["addedCount"], label: "added"),
                count(summary.payload["modifiedCount"], label: "changed"),
                count(summary.payload["deletedCount"], label: "removed"),
            ].filter { !$0.isEmpty }.joined(separator: ", ")
            let detail = [counts, files.isEmpty ? "" : "files: \(files.joined(separator: ", "))"]
                .filter { !$0.isEmpty }.joined(separator: "; ")
            return "- Run \(runID.prefix(8)): \(status)\(detail.isEmpty ? "" : "; " + detail)"
        }
        guard !lines.isEmpty else { return "" }
        return "[Recent device-local project activity]\nThese are operation summaries, not conversation history.\n" + lines.joined(separator: "\n")
    }

    static func projectPreferenceText(userRoot: URL, workspace: URL) -> String {
        let path = userRoot.appendingPathComponent("user_profile.json")
        guard let data = try? Data(contentsOf: path),
              let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = profile["projectPreferences"] as? [String: [String: String]],
              let preferences = all[projectIdentity(workspace)], !preferences.isEmpty else { return "" }
        let projectKeys = MobileFacts.projectKeys(root: workspace, userRoot: userRoot)
        let lines = preferences.keys.sorted().filter { !projectKeys.contains($0.lowercased()) }.compactMap { key -> String? in
            guard let value = preferences[key] else { return nil }
            return "- \(key): \(value)"
        }
        return lines.isEmpty ? "" : "## Preferences for this project (device-local)\n" + lines.joined(separator: "\n")
    }

    static func projectPreferenceKeys(userRoot: URL, workspace: URL) -> Set<String> {
        let path = userRoot.appendingPathComponent("user_profile.json")
        guard let data = try? Data(contentsOf: path),
              let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = profile["projectPreferences"] as? [String: [String: String]],
              let preferences = all[projectIdentity(workspace)] else { return [] }
        return Set(preferences.keys)
    }

    static func projectMemoryFolder(userRoot: URL, workspace: URL) -> URL {
        let identity = projectMemoryIdentity(workspace)
        return userRoot.appendingPathComponent("user-memory", isDirectory: true)
            .appendingPathComponent(identity, isDirectory: true)
    }

    static func migrateLegacyProjectFile(_ name: String, workspace: URL, userRoot: URL) {
        let source = workspace.appendingPathComponent(".mem", isDirectory: true).appendingPathComponent(name)
        let destination = projectMemoryFolder(userRoot: userRoot, workspace: workspace).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: destination.path),
              FileManager.default.fileExists(atPath: source.path) else { return }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch { }
    }

    private static func projectIdentity(_ workspace: URL) -> String {
        let manifest = workspace.appendingPathComponent(".mem/manifest.json")
        if let data = try? Data(contentsOf: manifest),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = object["projectId"] as? String, !id.isEmpty {
            return id
        }
        return workspace.standardizedFileURL.path
    }

    private static func projectMemoryIdentity(_ workspace: URL) -> String {
        let manifest = workspace.appendingPathComponent(".mem/manifest.json")
        if let data = try? Data(contentsOf: manifest),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = object["projectId"] as? String, UUID(uuidString: id) != nil {
            return id
        }
        let digest = SHA256.hash(data: Data(workspace.standardizedFileURL.path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).lowercased()
    }

    private static func read(_ path: URL) -> [Fact] {
        guard let body = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        var result: [Fact] = []
        var kind = ""
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("## ") {
                kind = String(line.dropFirst(3)).lowercased()
            } else if line.hasPrefix("- "), !kind.isEmpty, let separator = line.range(of: " — ") {
                let key = line[line.index(line.startIndex, offsetBy: 2)..<separator.lowerBound]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " `"))
                let value = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, !value.isEmpty { result.append(Fact(kind: kind, key: key, text: value)) }
            }
        }
        return result
    }

    private static func render(_ facts: [Fact]) -> String {
        let groups = Dictionary(grouping: facts, by: \.kind)
        return groups.keys.sorted().compactMap { kind -> String? in
            guard let items = groups[kind], !items.isEmpty else { return nil }
            return "## \(kind)\n" + items.sorted { $0.key < $1.key }.map { "- \($0.key) — \($0.text)" }.joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
    }

    private static func collapse(_ value: String, limit: Int) -> String {
        String(value.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }

    private static func count(_ value: String?, label: String) -> String {
        guard let value, let number = Int(value), number > 0 else { return "" }
        return "\(number) \(label)"
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
