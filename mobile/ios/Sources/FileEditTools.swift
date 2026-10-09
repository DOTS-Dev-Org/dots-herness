// Surgical file editing and filename search for the on-phone agent loop.
// Ported from `macos/DotsHarness/Sources/DotsHarnessCore/WorkspaceTools+Editing.swift`;
// the mobile layer has no `WorkspaceTools` type, so path resolution arrives as an
// injected closure and every other rule matches the desktop one for one.

import Foundation

/// `edit_file` and `glob`.
///
/// `write_file` replaces a whole file, which forces the model to reproduce every
/// byte it does not intend to change — and a file it never read is refused for
/// exactly that reason. `edit_file` is the other half: it names the text to
/// replace, so the untouched 90 % of the file is never in the transcript. It is
/// still guarded by the same read ledger, because an edit applied to bytes the
/// model has not seen is the same loss in a smaller wrapper.
enum FileEditTools {
    static let editName = "edit_file"
    static let globName = "glob"

    static let maximumEdits = 50
    static let globResultCap = 200
    /// Directory walks stop here rather than reporting a partial list as if it
    /// were complete.
    static let globScanLimit = 20_000
    /// The same directories the workspace mirror itself refuses to hash.
    static let ignoredScanDirectories: Set<String> = [
        ".git", ".mem", ".build", "build", "bin", "obj", "dist", "node_modules", "Pods", "DerivedData",
    ]

    /// Resolves a model-supplied workspace-relative path. Lives behind a parameter
    /// because `LocalWorkspaceStore.resolve` is main-actor isolated, and because it
    /// keeps both tools testable against a temporary directory.
    typealias PathResolver = @Sendable (String) async throws -> URL

    // MARK: - edit_file

    /// The whole `edit_file` answer: a model-facing `"Tool error: …"` for every
    /// rejection, or the one-line summary of what changed. Rejections all say
    /// "Nothing was written", and they mean it — the file is only opened for write
    /// once every replacement has matched.
    static func edit(path: String, edits: [[String: Any]], resolve: @escaping PathResolver) async -> String {
        guard edits.isEmpty == false else { return "Tool error: edits is empty; at least one replacement is required." }
        guard edits.count <= maximumEdits else {
            return "Tool error: too many edits in one call (max \(maximumEdits)). Split them into separate calls."
        }
        let file: URL
        do {
            file = try await resolve(path)
        } catch {
            return "Tool error: \(error.localizedDescription)"
        }
        guard let current = try? Data(contentsOf: file) else {
            return "Tool error: \(path) does not exist. write_file creates a new file; edit_file only changes an existing one."
        }
        guard let text = String(data: current, encoding: .utf8) else {
            return "Tool error: \(path) is not valid UTF-8 text."
        }
        // Same authority rule as write_file: an edit assumes the model has seen the
        // bytes it is matching against.
        switch ReadLedger.shared.state(for: file, data: current) {
        case .unread: return "Tool error: \(path) has not been read in this conversation. Read it before editing."
        case .stale: return "Tool error: \(path) changed since it was read. Read it again before editing."
        case .fresh: break
        }
        switch apply(edits: edits, to: text, path: path) {
        case .rejected(let reason):
            return reason
        case .applied(let updated, let summary):
            return write(updated: updated, to: file, path: path, summary: summary)
        }
    }

    enum EditOutcome {
        case rejected(String)
        case applied(updated: String, summary: String)
    }

    /// The pure half of `edit_file`: all-or-nothing, so a rejected replacement
    /// leaves the file untouched rather than half-applied.
    static func apply(edits: [[String: Any]], to text: String, path: String) -> EditOutcome {
        var updated = text
        var summary: [String] = []
        for (index, edit) in edits.enumerated() {
            guard let oldText = edit["old_text"] as? String, let newText = edit["new_text"] as? String else {
                return .rejected("Tool error: edit \(index + 1) needs both old_text and new_text. Nothing was written.")
            }
            guard !oldText.isEmpty else {
                return .rejected("Tool error: edit \(index + 1) has an empty old_text, which would match everywhere. Nothing was written.")
            }
            let replaceAll = edit["replace_all"] as? Bool ?? false
            let found = occurrences(of: oldText, in: updated)
            switch found.count {
            case 0:
                return .rejected("Tool error: edit \(index + 1) matched nothing in \(path). Nothing was written — check the exact text and whitespace with read_file.")
            case 1:
                break
            default:
                guard replaceAll else {
                    let lines = found.prefix(5).map { String(lineNumber(in: updated, at: $0)) }
                    return .rejected("""
                    Tool error: edit \(index + 1) matched \(found.count) places in \(path) \
                    (around line\(lines.count == 1 ? "" : "s") \(lines.joined(separator: ", "))). \
                    Nothing was written. Widen old_text with surrounding lines, or set replace_all.
                    """)
                }
            }
            if replaceAll {
                updated = updated.replacingOccurrences(of: oldText, with: newText)
                summary.append("replaced \(found.count) occurrence\(found.count == 1 ? "" : "s")")
            } else {
                let range = updated.range(of: oldText)!
                updated.replaceSubrange(range, with: newText)
                summary.append("replaced 1 occurrence")
            }
        }
        return .applied(updated: updated, summary: summary.joined(separator: "; "))
    }

    static func write(updated: String, to file: URL, path: String, summary: String) -> String {
        let data = Data(updated.utf8)
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            return "Tool error: could not write \(path): \(error.localizedDescription)"
        }
        ReadLedger.shared.record(file, data: data)
        return "Edited \(path) (\(summary))."
    }

    /// Overlapping matches are counted left to right, the same way the subsequent
    /// replacement consumes them — so a count of two never describes one rewrite.
    static func occurrences(of needle: String, in haystack: String) -> [String.Index] {
        var positions: [String.Index] = []
        var cursor = haystack.startIndex
        while let found = haystack.range(of: needle, range: cursor..<haystack.endIndex) {
            positions.append(found.lowerBound)
            cursor = found.upperBound
        }
        return positions
    }

    static func lineNumber(in text: String, at position: String.Index) -> Int {
        1 + text[text.startIndex..<position].reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
    }

    // MARK: - glob

    static func glob(pattern: String, path: String, resolve: @escaping PathResolver) async -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Tool error: pattern is required." }
        guard !trimmed.hasPrefix("/"), !trimmed.contains("..") else {
            return "Tool error: pattern must stay inside the workspace."
        }
        guard let expression = globRegex(trimmed) else {
            return "Tool error: the pattern could not be compiled — check for an unclosed { or [."
        }
        let base: URL
        do {
            base = try await resolve(path)
        } catch {
            return "Tool error: \(error.localizedDescription)"
        }
        let values = try? base.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else {
            return "Tool error: \(path) is not a directory."
        }

        let matches = globMatches(
            expression: expression,
            patternHasSlash: trimmed.contains("/"),
            base: base
        )
        let shownDirectory = path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "." : path
        guard !matches.isEmpty else {
            return "glob \(trimmed): no files found."
        }
        let shown = matches.prefix(globResultCap).map(\.relative)
        let header = matches.count > globResultCap
            ? "glob \(trimmed) under \(shownDirectory): \(globResultCap) newest of \(matches.count) matches — narrow the pattern"
            : "glob \(trimmed) under \(shownDirectory): \(matches.count) file\(matches.count == 1 ? "" : "s")"
        return ([header] + shown).joined(separator: "\n")
    }

    /// Newest first: when an agent is looking for "the file I just made", the
    /// modification time carries more signal than alphabetical order.
    static func globMatches(
        expression: NSRegularExpression,
        patternHasSlash: Bool,
        base: URL
    ) -> [(relative: String, modified: Date)] {
        let root = base.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: []
        ) else { return [] }
        var found: [(relative: String, modified: Date)] = []
        var scanned = 0
        for case let candidate as URL in enumerator {
            let relative = relativePath(candidate, inside: root)
            let components = relative.split(separator: "/").map(String.init)
            if components.contains(where: { ignoredScanDirectories.contains($0) || $0.hasPrefix(".mem") }) {
                if (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let values = try? candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey]
            )
            if values?.isSymbolicLink == true {
                if (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            scanned += 1
            if scanned > globScanLimit { break }
            if isMatch(expression: expression, relative: relative, patternHasSlash: patternHasSlash, lastComponent: components.last ?? "") {
                found.append((relative, values?.contentModificationDate ?? .distantPast))
            }
        }
        return found.sorted { lhs, rhs in
            lhs.modified == rhs.modified ? lhs.relative < rhs.relative : lhs.modified > rhs.modified
        }
    }

    static func isMatch(
        expression: NSRegularExpression,
        relative: String,
        patternHasSlash: Bool,
        lastComponent: String
    ) -> Bool {
        func full(_ value: String) -> Bool {
            expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
        if full(relative) { return true }
        // "**/*.swift" already crosses separators; a bare "*.swift" should still
        // reach nested files, which is what an agent means when it types one.
        return !patternHasSlash && full(lastComponent)
    }

    /// Compiles a glob into an anchored regular expression. `**` alone spans path
    /// separators, `**/` also matches zero directories, and a brace group becomes a
    /// non-capturing alternation.
    static func globRegex(_ pattern: String) -> NSRegularExpression? {
        guard let source = globPattern(pattern) else { return nil }
        return try? NSRegularExpression(pattern: source)
    }

    static func globPattern(_ pattern: String) -> String? {
        var output = ""
        var braceDepth = 0
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            let next = pattern.index(after: index)
            switch character {
            case "*":
                if next < pattern.endIndex, pattern[next] == "*" {
                    let after = pattern.index(after: next)
                    if after < pattern.endIndex, pattern[after] == "/" {
                        // `**/` may stand for zero directories as well as many, so
                        // "src/**/*.ts" has to keep matching "src/a.ts".
                        output += "(?:[^/]*/)*"
                        index = pattern.index(after: after)
                        continue
                    }
                    output += ".*"
                    index = after
                    continue
                }
                output += "[^/]*"
                index = next
            case "?":
                output += "[^/]"
                index = next
            case "{":
                braceDepth += 1
                output += "(?:"
                index = next
            case "}":
                guard braceDepth > 0 else { return nil }
                braceDepth -= 1
                output += ")"
                index = next
            case ",":
                output += braceDepth > 0 ? "|" : ","
                index = next
            case "[":
                // Copy the class verbatim; an unterminated one is a broken pattern.
                guard let close = pattern[next...].firstIndex(of: "]"), close != next else { return nil }
                output += "[" + String(pattern[next..<close]) + "]"
                index = pattern.index(after: close)
            default:
                output += regexEscaped(character)
                index = next
            }
        }
        guard braceDepth == 0 else { return nil }
        return "^\(output)$"
    }

    /// Only the metacharacters that can actually reach here are escaped: the
    /// switch above has already consumed `*`, `?`, `{`, `}`, `,` and `[`.
    private static func regexEscaped(_ character: Character) -> String {
        ".+^$()|\\][]".contains(character) ? "\\\(character)" : String(character)
    }

    /// `.` for the searched directory itself, otherwise the path under it. Matches
    /// the desktop helper this replaces, which is what the result lines show.
    /// Symlinks are deliberately not resolved here — the walk refuses them, and
    /// resolving would rename the entry the model asked about.
    static func relativePath(_ url: URL, inside base: URL) -> String {
        let root = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path == root ? "." : path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
