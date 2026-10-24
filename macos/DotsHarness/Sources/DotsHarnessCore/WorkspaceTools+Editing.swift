// Copyright (c) 2026 DOTS
// Surgical file editing and filename search for the native agent loop.

import Foundation
import HarnessPluginKit

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

    static let globResultCap = 200
    /// Directory walks stop here rather than reporting a partial list as if it
    /// were complete.
    static let globScanLimit = 20_000

    static let definitions: [AgentToolDefinition] = [editDefinition, globDefinition]

    static let editDefinition = AgentToolDefinition(
        name: editName,
        description: """
        Replace exact text inside an existing file, without rewriting the rest of it. \
        Prefer this over write_file for any edit to a file you have already read. Each \
        old_text must match the file byte for byte and appear exactly once unless \
        replace_all is set; a match that is not unique is refused rather than guessed \
        at, so widen it with surrounding lines. Creating a new file still needs write_file.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Relative path to the existing file."),
                ]),
                "edits": .object([
                    "type": .string("array"),
                    "description": .string("Replacements applied in order, all or none."),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "old_text": .object([
                                "type": .string("string"),
                                "description": .string("Exact text to replace, copied from read_file."),
                            ]),
                            "new_text": .object([
                                "type": .string("string"),
                                "description": .string("Replacement text. Empty deletes the match."),
                            ]),
                            "replace_all": .object([
                                "type": .string("boolean"),
                                "description": .string("Replace every occurrence instead of requiring one unique match."),
                            ]),
                        ]),
                        "required": .array([.string("old_text"), .string("new_text")]),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
            ]),
            "required": .array([.string("path"), .string("edits")]),
            "additionalProperties": .bool(false),
        ])
    )

    static let globDefinition = AgentToolDefinition(
        name: globName,
        description: """
        Find files by name pattern inside the workspace and get back paths newest-first. \
        Supports * and ? within one path segment, ** across segments, and {a,b} groups — \
        so "**/*.swift", "Sources/**/*Test*.swift", "config.{json,yml}". A pattern with no \
        slash matches filenames at any depth. Use grep_files instead when the content, not \
        the name, is what you are looking for.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "pattern": .object([
                    "type": .string("string"),
                    "description": .string("Glob pattern, relative to the searched directory."),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Relative directory to search. Defaults to the workspace root."),
                ]),
            ]),
            "required": .array([.string("pattern")]),
            "additionalProperties": .bool(false),
        ])
    )

    // MARK: - edit_file

    /// Returns nil on success and the model-facing reason on rejection, so the
    /// caller's error prefix stays in one place.
    static func edit(
        path: String,
        edits: [[String: Any]],
        workspace: URL,
        conversationID: String
    ) -> String {
        guard !edits.isEmpty else { return "Tool error: edits is empty; at least one replacement is required." }
        guard edits.count <= 50 else { return "Tool error: too many edits in one call (max 50). Split them into separate calls." }
        let file: URL
        do {
            file = try WorkspaceTools.resolve(path, workspace: workspace)
        } catch {
            return "Tool error: \(error.localizedDescription)"
        }
        guard let current = try? Data(contentsOf: file) else {
            return "Tool error: \(path) does not exist. write_file creates a new file; edit_file only changes an existing one."
        }
        guard let text = String(data: current, encoding: .utf8) else {
            return "Tool error: \(path) is not valid UTF-8 text."
        }
        // An edit assumes the model has seen the bytes it is matching against. Unlike
        // write_file it does not need the whole file: the lines it replaces must lie
        // inside pages read from this exact version.
        let totalLines = text.components(separatedBy: "\n").count
        let coverage = ReadLedger.shared.coverage(for: file, data: current, totalLines: totalLines, conversationID: conversationID)
        switch coverage.state {
        case .unread: return "Tool error: \(path) has not been read in this conversation. Read it before editing."
        case .stale: return "Tool error: \(path) changed since it was read. Read it again before editing."
        case .fresh: break
        }
        var covered = coverage.lines
        let partial = !covered.contains(integersIn: 1..<(totalLines + 1))

        var updated = text
        var summary: [String] = []
        for (index, edit) in edits.enumerated() {
            guard let oldText = edit["old_text"] as? String, let newText = edit["new_text"] as? String else {
                return "Tool error: edit \(index + 1) needs both old_text and new_text. Nothing was written."
            }
            guard !oldText.isEmpty else {
                return "Tool error: edit \(index + 1) has an empty old_text, which would match everywhere. Nothing was written."
            }
            let replaceAll = edit["replace_all"] as? Bool ?? false
            let found = occurrences(of: oldText, in: updated)
            switch found.count {
            case 0:
                return "Tool error: edit \(index + 1) matched nothing in \(path). Nothing was written — check the exact text and whitespace with read_file."
            case 1:
                break
            default:
                guard replaceAll else {
                    let lines = found.prefix(5).map { lineNumber(in: updated, at: $0) }
                    return """
                    Tool error: edit \(index + 1) matched \(found.count) places in \(path) \
                    (around line\(lines.count == 1 ? "" : "s") \(lines.map(String.init).joined(separator: ", "))). \
                    Nothing was written. Widen old_text with surrounding lines, or set replace_all.
                    """
                }
            }
            if partial {
                let touched = (replaceAll ? found : Array(found.prefix(1))).map { position -> (start: Int, end: Int) in
                    let match = updated.range(of: oldText, range: position..<updated.endIndex)!
                    let last = updated.index(before: match.upperBound)
                    return (newlineCount(in: updated, upTo: position) + 1, newlineCount(in: updated, upTo: last) + 1)
                }
                if let unread = touched.first(where: { !covered.contains(integersIn: $0.start...$0.end) }) {
                    return "Tool error: edit \(index + 1) changes lines \(unread.start)-\(unread.end) of \(path), which were not read in this conversation. "
                        + "Read them with read_file offset/limit first. Nothing was written."
                }
                let delta = newlineCount(in: newText) - newlineCount(in: oldText)
                for span in touched.sorted(by: { $0.start > $1.start }) {
                    covered = shiftedLines(covered, editStart: span.start, editEnd: span.end, delta: delta)
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

        let data = Data(updated.utf8)
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            return "Tool error: could not write \(path): \(error.localizedDescription)"
        }
        if partial {
            // Carry what was read over to the new version, shifted past each edit, so
            // the next edit in the same section needs no reread.
            let newTotal = updated.components(separatedBy: "\n").count
            for range in covered.rangeView {
                let lines = range.lowerBound..<min(range.upperBound, newTotal + 1)
                ReadLedger.shared.recordLines(file, data: data, lines: lines, totalLines: newTotal, conversationID: conversationID)
            }
        } else {
            ReadLedger.shared.record(file, data: data, conversationID: conversationID)
        }
        return "Edited \(WorkspaceTools.relativePath(file, workspace: workspace)) (\(summary.joined(separator: "; ")))."
            + changedLines(before: text, after: updated)
    }

    static let changedLinesShown = 40

    /// The edited region of the new file, numbered, with two lines of context: the
    /// model sees the result without a follow-up read_file. One span from the first
    /// to the last changed line; a span wider than `changedLinesShown` only names
    /// its line range.
    static func changedLines(before: String, after: String) -> String {
        let a = before.components(separatedBy: "\n"), b = after.components(separatedBy: "\n")
        var top = 0
        while top < a.count, top < b.count, a[top] == b[top] { top += 1 }
        var bottom = 0
        while bottom < a.count - top, bottom < b.count - top, a[a.count - 1 - bottom] == b[b.count - 1 - bottom] { bottom += 1 }
        let start = max(0, top - 2), end = min(b.count, b.count - bottom + 2)
        if end - start > changedLinesShown {
            return "\nChanged lines \(top + 1)-\(b.count - bottom): too wide to show; read_file them if needed."
        }
        return "\n" + (start..<end).map { "\($0 + 1): \(b[$0])" }.joined(separator: "\n")
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

    /// Counts "\n" bytes, the same separator read_file pages by, so a CRLF line is one
    /// line here too (Swift treats "\r\n" as a single Character).
    static func newlineCount(in text: String, upTo position: String.Index? = nil) -> Int {
        text[text.startIndex..<(position ?? text.endIndex)].utf8.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
    }

    /// Moves read lines after an edit of `editStart...editEnd` that changed the
    /// line count by `delta`: later lines shift, the edited span stretches or
    /// shrinks, earlier lines stay.
    static func shiftedLines(_ lines: IndexSet, editStart: Int, editEnd: Int, delta: Int) -> IndexSet {
        var result = lines
        result.remove(integersIn: editStart...editEnd)
        result.shift(startingAt: editEnd + 1, by: delta)
        if editEnd + delta >= editStart { result.insert(integersIn: editStart...(editEnd + delta)) }
        return result
    }

    static func lineNumber(in text: String, at position: String.Index) -> Int {
        1 + text[text.startIndex..<position].reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
    }

    // MARK: - glob

    static func glob(pattern: String, path: String, workspace: URL) -> String {
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
            base = try WorkspaceTools.resolve(path, workspace: workspace)
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
            base: base,
            workspace: workspace
        )
        guard !matches.isEmpty else {
            return "glob \(trimmed): no files found."
        }
        let shown = matches.prefix(globResultCap).map(\.relative)
        let header = matches.count > globResultCap
            ? "glob \(trimmed) under \(WorkspaceTools.relativePath(base, workspace: workspace)): \(globResultCap) newest of \(matches.count) matches — narrow the pattern"
            : "glob \(trimmed) under \(WorkspaceTools.relativePath(base, workspace: workspace)): \(matches.count) file\(matches.count == 1 ? "" : "s")"
        return ([header] + shown).joined(separator: "\n")
    }

    /// Newest first: when an agent is looking for "the file I just made", the
    /// modification time carries more signal than alphabetical order.
    private static func globMatches(
        expression: NSRegularExpression,
        patternHasSlash: Bool,
        base: URL,
        workspace: URL
    ) -> [(relative: String, modified: Date)] {
        let root = base.standardizedFileURL.resolvingSymlinksInPath()
        var found: [(relative: String, modified: Date)] = []
        var scanned = 0
        WorkspaceTools.scanFiles(root) { candidate in
            scanned += 1
            if scanned > globScanLimit { return false }
            let relative = WorkspaceTools.relativePath(candidate, workspace: root)
            if isMatch(expression: expression, relative: relative, patternHasSlash: patternHasSlash, lastComponent: candidate.lastPathComponent) {
                let modified = (try? candidate.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                found.append((relative, modified ?? .distantPast))
            }
            return true
        }
        return found.sorted { lhs, rhs in
            lhs.modified == rhs.modified ? lhs.relative < rhs.relative : lhs.modified > rhs.modified
        }
    }

    private static func isMatch(
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
}
