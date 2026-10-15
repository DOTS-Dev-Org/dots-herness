// Copyright (c) 2026 DOTS
// Small, workspace-scoped tools for the native agent loop.

import CryptoKit
import Foundation
import HarnessPluginKit

public enum WorkspaceTools {
    private static let verifiedRemovalMarker = "[cleanup:verified]"
    private static let preservedRemovalMarker = "[cleanup:preserved]"
    private static let failedRemovalMarker = "[cleanup:failed]"
    private static let cleanupExtensions: Set<String> = [
        "c", "cc", "cpp", "cs", "csproj", "gradle", "h", "hpp", "ini", "java", "js", "jsx", "json",
        "kt", "kts", "m", "mm", "php", "plist", "props", "py", "resx", "rs", "swift", "targets", "toml",
        "ts", "tsx", "xml", "xaml", "yaml", "yml",
    ]
    static let ignoredScanDirectories: Set<String> = [
        ".git", ".mem", ".build", "build", "bin", "obj", "dist", "node_modules", "Pods", "DerivedData",
    ]
    private static let protectedNames: Set<String> = ["provider-state.json", "conversations.json", "state.sqlite", "state.db"]
    public static let definitions: [AgentToolDefinition] = workspaceDefinitions + FileEditTools.definitions + [generatedMediaDefinition, generatedMediaInspectionDefinition] + SimulatorTools.definitions + AndroidEmulatorTools.definitions
    public static let readOnlyDefinitions: [AgentToolDefinition] = (workspaceDefinitions + FileEditTools.definitions).filter {
        readOnlyNames.contains($0.name)
    }
    static let readOnlyNames: Set<String> = ["list_files", "read_file", "grep_files", FileEditTools.globName, generatedMediaInspectionName]

    static let generatedMediaName = "copy_generated_media"
    static let generatedMediaInspectionName = "inspect_generated_media"

    static let generatedMediaDefinition = AgentToolDefinition(
        name: generatedMediaName,
        description: "Copy a generated image from the current conversation into the current coding workspace. Use only when the user asks to reuse the generated asset in the project.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "source_path": .object([
                    "type": .string("string"),
                    "description": .string("Exact absolute path from the Generated media artifact context."),
                ]),
                "destination_path": .object([
                    "type": .string("string"),
                    "description": .string("Workspace-relative destination path, including the filename."),
                ]),
            ]),
            "required": .array([.string("source_path"), .string("destination_path")]),
        ])
    )

    static let generatedMediaInspectionDefinition = AgentToolDefinition(
        name: generatedMediaInspectionName,
        description: "Inspect a generated image only when its visual content is needed. The normal conversation carries only the exact file path; this tool attaches that file to the next model request for visual inspection.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "source_path": .object([
                    "type": .string("string"),
                    "description": .string("Exact absolute path from the Generated media artifact context."),
                ]),
                "instruction": .object([
                    "type": .string("string"),
                    "description": .string("Optional visual inspection question."),
                ]),
            ]),
            "required": .array([.string("source_path")]),
            "additionalProperties": .bool(false),
        ])
    )

    public static func isReadOnly(_ name: String) -> Bool { readOnlyNames.contains(name) }

    public static func isVerifiedRemovalResult(_ result: String) -> Bool { result.hasPrefix(verifiedRemovalMarker) }
    public static func isPreservedRemovalResult(_ result: String) -> Bool { result.hasPrefix(preservedRemovalMarker) }
    public static func isFailedRemovalResult(_ result: String) -> Bool { result.hasPrefix(failedRemovalMarker) }
    public static func mayDeleteFiles(_ command: String?) -> Bool {
        guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let pattern = #"(?i)(^|[\s;&|])(rm|unlink|del|erase|rmdir|remove-item|git\s+clean)([\s;&|]|$)"#
        return command.range(of: pattern, options: .regularExpression) != nil
    }

    /// A shell command that could send local content to a network peer — the
    /// primitive a prompt-injected instruction (from a read file, a tool
    /// result, a plugin) would need to exfiltrate a secret. This forces an
    /// approval prompt even in `.full` permission mode (see AgentBridge's
    /// `requestApprovalIfNeeded`): "don't ask about ordinary side effects"
    /// is not "auto-send local files to arbitrary hosts because something the
    /// agent read told it to". `git`'s own network use (push/pull/fetch/clone)
    /// is deliberately excluded — it names no arbitrary host on the command
    /// line, so it is not the exfiltration primitive this guards against.
    public static func mayAccessNetwork(_ command: String?) -> Bool {
        guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let pattern = #"(?i)(^|[\s;&|])(curl|wget|nc|ncat|netcat|telnet|scp|sftp|ssh)([\s;&|]|$)"#
        return command.range(of: pattern, options: .regularExpression) != nil
    }

    public static func copyGeneratedMedia(
        sourcePath: String,
        destinationPath: String,
        allowedSourcePaths: Set<String>,
        workspace: URL
    ) -> String {
        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL.resolvingSymlinksInPath()
        let allowed = allowedSourcePaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
        }
        guard allowed.contains(source.path), FileManager.default.fileExists(atPath: source.path) else {
            return "Tool error: the generated media artifact is not available in this conversation."
        }
        guard !destinationPath.isEmpty, !destinationPath.hasPrefix("/") else {
            return "Tool error: destination_path must be relative to the workspace."
        }
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let destination = URL(fileURLWithPath: destinationPath, relativeTo: root)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard destination.path == root.path || destination.path.hasPrefix(root.path + "/") else {
            return "Tool error: destination_path is outside the workspace."
        }
        guard !destination.path.hasPrefix(root.appendingPathComponent(".mem").path + "/"), destination.path != root.appendingPathComponent(".mem").path else {
            return "Tool error: the memory directory is unavailable."
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return "Tool error: destination already exists: \(relativePath(destination, workspace: root))"
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            return "Copied generated media to \(relativePath(destination, workspace: root))."
        } catch {
            return "Tool error: could not copy generated media: \(error.localizedDescription)"
        }
    }

    static let workspaceDefinitions: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: "list_files",
            description: "List files and directories inside the current workspace.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path. Use . for the workspace root."),
                    ]),
                ]),
            ])
        ),
        AgentToolDefinition(
            name: "read_file",
            description: """
            Read a UTF-8 text file inside the current workspace. Returns 250 lines by \
            default; a longer file ends with a continuation line naming the next offset. \
            Prefer a narrow offset/limit range for relevant sections. edit_file only needs \
            the lines it replaces to have been read; read every page only when write_file \
            will rewrite the whole file.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path to the file."),
                    ]),
                    "offset": .object([
                        "type": .string("integer"),
                        "description": .string("First line to read, 1-based. Defaults to the start of the file."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("How many lines to read. Defaults to 250."),
                    ]),
                ]),
                "required": .array([.string("path")]),
            ])
        ),
        AgentToolDefinition(
            name: "write_file",
            description: """
            Create or replace a UTF-8 text file inside the current workspace. It writes \
            the whole file, so read an existing file first: rewriting one you have not \
            read, or one that changed since you read it, is refused.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path to the file."),
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("Complete file contents."),
                    ]),
                ]),
                "required": .array([.string("path"), .string("content")]),
            ])
        ),
        AgentToolDefinition(
            name: "remove_file",
            description: "Remove one unused source/config/test/import file only after references are checked.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Workspace-relative file path.")]),
                    "reason": .object(["type": .string("string"), "description": .string("Why this old artifact is no longer needed.")]),
                    "referenceTerms": .object(["type": .string("string"), "description": .string("Old symbols or paths to search for, separated by commas or new lines.")]),
                ]),
                "required": .array([.string("path"), .string("reason"), .string("referenceTerms")]),
            ])
        ),
        AgentToolDefinition(
            name: "grep_files",
            description: """
            Search file contents inside the workspace with a regular expression and get back \
            path:line:text matches. Prefer this over a shell grep: it skips build and dependency \
            directories, bounds its own output, and answers in one call.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "pattern": .object([
                        "type": .string("string"),
                        "description": .string("ICU regular expression to match against each line."),
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative directory to search. Defaults to the workspace root."),
                    ]),
                    "extensions": .object([
                        "type": .string("string"),
                        "description": .string("Optional comma-separated file extensions to limit the search, e.g. swift,json."),
                    ]),
                ]),
                "required": .array([.string("pattern")]),
            ])
        ),
        AgentToolDefinition(
            name: "run_command",
            description: "Run a shell command with the workspace as its current directory.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("Command to run with /bin/zsh."),
                    ]),
                ]),
                "required": .array([.string("command")]),
            ])
        ),
    ]

    /// Runs a tool call on a remote work location over SSH.
    ///
    /// Only `run_command` crosses the wire in this phase. Every other
    /// workspace tool is refused rather than quietly falling back to the local
    /// disk: writing to the wrong machine is the one failure this feature
    /// must not have, so the remote branch never reaches `FileManager`.
    public static func executeRemote(
        _ call: AgentToolCall,
        target: SSHTarget,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) -> String {
        guard call.name == "run_command" else {
            return AppCopy.format("tool.remoteUnavailable", call.name, target.alias)
        }
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String else {
            return AppCopy.text("tool.missingCommand")
        }
        if command.range(of: #"(?:^|[\s/])\.mem(?:[\s/]|$)"#, options: .regularExpression) != nil {
            return AppCopy.format("tool.error", AppCopy.text("tool.pathUnavailable"))
        }
        do {
            let output = try SSHRunner.run(target: target, command: command, onOutput: onOutput)
            if output.timedOut { return AppCopy.text("tool.timedOut") }
            let text = String(output.text.prefix(24_000))
            if output.status != 0, SSHRunner.isTransportFailure(text) {
                // Told apart from an ordinary non-zero exit so the agent does
                // not go looking for a bug in code that never ran.
                return AppCopy.format("ssh.disconnected", target.alias) + "\n" + text
            }
            let suffix = output.status == 0 ? "" : "\n" + AppCopy.format("tool.exitStatus", output.status)
            return text.isEmpty ? AppCopy.text("tool.noOutput") + suffix : text + suffix
        } catch {
            return AppCopy.format("tool.error", error.localizedDescription)
        }
    }

    public static func execute(
        _ call: AgentToolCall,
        workspace: URL,
        conversationID: String,
        sandboxPolicy: SandboxExecutionPolicy? = nil,
        readRoots: [URL] = [],
        isCancelled: @Sendable () -> Bool = { false },
        onOutput: (@Sendable (String) -> Void)? = nil
    ) -> String {
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AppCopy.format("tool.invalidArguments", call.name)
        }

        do {
            switch call.name {
            case "list_files":
                let path = object["path"] as? String ?? "."
                return try listFiles(at: path, workspace: workspace, readRoots: readRoots)
            case "read_file":
                guard let path = object["path"] as? String else { return AppCopy.text("tool.missingPath") }
                return try readFile(
                    at: path,
                    offset: object["offset"] as? Int,
                    limit: object["limit"] as? Int,
                    workspace: workspace,
                    conversationID: conversationID,
                    readRoots: readRoots
                )
            case "write_file":
                guard let path = object["path"] as? String,
                      let content = object["content"] as? String else {
                    return AppCopy.text("tool.missingPathOrContent")
                }
                return try writeFile(at: path, content: content, workspace: workspace, conversationID: conversationID)
            case "remove_file":
                guard let path = object["path"] as? String,
                      let reason = object["reason"] as? String,
                      let referenceTerms = object["referenceTerms"] as? String else {
                    return failedRemovalMarker + " A path, reason, and reference search are required."
                }
                return try removeFile(at: path, reason: reason, referenceTerms: referenceTerms, workspace: workspace)
            case "grep_files":
                guard let pattern = object["pattern"] as? String else { return AppCopy.text("tool.missingPattern") }
                return try grepFiles(
                    pattern: pattern,
                    path: object["path"] as? String ?? ".",
                    extensions: object["extensions"] as? String,
                    workspace: workspace,
                    readRoots: readRoots
                )
            case FileEditTools.editName:
                guard let path = object["path"] as? String else { return AppCopy.text("tool.missingPath") }
                guard let edits = object["edits"] as? [[String: Any]] else {
                    return "Tool error: edits must be an array of {old_text, new_text} objects."
                }
                return FileEditTools.edit(path: path, edits: edits, workspace: workspace, conversationID: conversationID)
            case FileEditTools.globName:
                guard let pattern = object["pattern"] as? String else { return AppCopy.text("tool.missingPattern") }
                return FileEditTools.glob(pattern: pattern, path: object["path"] as? String ?? ".", workspace: workspace)
            case "run_command":
                guard let command = object["command"] as? String else { return AppCopy.text("tool.missingCommand") }
                return try run(
                    command: command,
                    workspace: workspace,
                    sandboxPolicy: sandboxPolicy,
                    isCancelled: isCancelled,
                    onOutput: onOutput
                )
            case "ios_simulator":
                return SimulatorTools.execute(object, workspace: workspace)
            case AndroidEmulatorTools.toolName:
                return AndroidEmulatorTools.execute(object, workspace: workspace)
            default:
                return AppCopy.format("tool.unknown", call.name)
            }
        } catch {
            return AppCopy.format("tool.error", error.localizedDescription)
        }
    }

    private static func isContained(_ path: String, in root: URL, allowFileRoot: Bool) -> Bool {
        let candidate = URL(fileURLWithPath: path, relativeTo: root)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if allowFileRoot { return candidate.path == root.deletingLastPathComponent().path || candidate.path == root.path }
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }

    private static func listFiles(at path: String, workspace: URL, readRoots: [URL]) throws -> String {
        let directory = try resolveRead(path, workspace: workspace, readRoots: readRoots)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return AppCopy.format("tool.notDirectory", path)
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsPackageDescendants]
        )
        let names = try urls
            .filter { $0.lastPathComponent != ".mem" }
            .filter { try $0.resourceValues(forKeys: [.isHiddenKey]).isHidden != true }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(200)
            .map { url -> String in
                let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                return isDirectory ? "\(url.lastPathComponent)/" : url.lastPathComponent
            }
        return names.isEmpty ? AppCopy.text("tool.empty") : names.joined(separator: "\n")
    }

    private static let grepMaxMatches = 100
    private static let grepMaxFiles = 5_000
    private static let grepMaxLineCharacters = 240

    private static func grepFiles(pattern: String, path: String, extensions: String?, workspace: URL, readRoots: [URL]) throws -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return AppCopy.format("tool.invalidPattern", pattern)
        }
        let root = try resolveRead(path, workspace: workspace, readRoots: readRoots)
        let filter = Set(
            (extensions ?? "")
                .split(whereSeparator: { ", \n".contains($0) })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
        )
        guard let enumerator = fileManager().enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) else { return AppCopy.text("tool.empty") }

        var matches: [String] = []
        var scanned = 0
        var truncated = false
        while let candidate = enumerator.nextObject() as? URL {
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isDirectory == true {
                let name = candidate.lastPathComponent
                if ignoredScanDirectories.contains(name) || name == ".mem" { enumerator.skipDescendants() }
                continue
            }
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            if !filter.isEmpty, !filter.contains(candidate.pathExtension.lowercased()) { continue }
            scanned += 1
            if scanned > grepMaxFiles { truncated = true; break }
            guard let text = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            let relative = relativePath(candidate, workspace: workspace.standardizedFileURL)
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let value = String(line)
                let range = NSRange(value.startIndex..<value.endIndex, in: value)
                guard regex.firstMatch(in: value, range: range) != nil else { continue }
                let shown = value.count > grepMaxLineCharacters
                    ? String(value.prefix(grepMaxLineCharacters)) + "…"
                    : value
                matches.append("\(relative):\(offset + 1):\(shown)")
                if matches.count >= grepMaxMatches { truncated = true; break }
            }
            if truncated { break }
        }
        if matches.isEmpty { return AppCopy.text("tool.noMatches") }
        return matches.joined(separator: "\n") + (truncated ? "\n\n" + AppCopy.text("tool.truncated") : "")
    }

    static let readMaxBytes = 60_000
    /// A read without an explicit limit returns one page: most questions need a
    /// section, and a later page is one offset away.
    static let defaultReadLines = 250
    static let defaultReadMaxBytes = 20_000

    /// Reads whole lines, never a partial one, and stops at `readMaxBytes`. A cut
    /// answer names the line to continue from, so a long file stays reachable
    /// without falling back to a shell command.
    private static func readFile(at path: String, offset: Int?, limit: Int?, workspace: URL, conversationID: String, readRoots: [URL]) throws -> String {
        let file = try resolveRead(path, workspace: workspace, readRoots: readRoots)
        let data = try Data(contentsOf: file)
        guard let text = String(data: data, encoding: .utf8) else {
            return AppCopy.format("tool.notUTF8", path)
        }
        let lines = text.components(separatedBy: "\n")
        let start = max(1, offset ?? 1)
        guard start <= lines.count else {
            return AppCopy.format("tool.offsetPastEnd", lines.count)
        }
        let end = min(lines.count, start + max(0, limit ?? defaultReadLines) - 1)
        let maxBytes = limit == nil ? defaultReadMaxBytes : readMaxBytes

        var emitted: [String] = []
        var bytes = 0
        var line = start
        while line <= end {
            let candidate = lines[line - 1]
            let size = candidate.utf8.count + 1
            if bytes + size > maxBytes, !emitted.isEmpty { break }
            emitted.append(candidate)
            bytes += size
            line += 1
        }
        let body = emitted.joined(separator: "\n")
        // Pages from the same on-disk version together authorize a complete read.
        ReadLedger.shared.recordLines(file, data: data, lines: start..<line,
                                      totalLines: lines.count, conversationID: conversationID)
        // A default page that stops before the end of the file says so; an explicit
        // limit that was met in full is the answer that was asked for.
        let more = limit == nil ? line <= lines.count : line <= end
        return more
            ? body + "\n\n" + AppCopy.format("tool.truncatedAt", line)
            : body
    }

    private static func writeFile(at path: String, content: String, workspace: URL, conversationID: String) throws -> String {
        let file = try resolve(path, workspace: workspace)
        // write_file replaces the whole file, so an unread or externally changed
        // file would lose whatever the model never saw. Refuse instead.
        if let current = try? Data(contentsOf: file) {
            switch ReadLedger.shared.state(for: file, data: current, conversationID: conversationID) {
            case .unread: return AppCopy.format("tool.writeNeedsRead", path)
            case .stale: return AppCopy.format("tool.writeStale", path)
            case .fresh: break
            }
        }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data(content.utf8)
        try data.write(to: file, options: .atomic)
        ReadLedger.shared.record(file, data: data, conversationID: conversationID)
        return AppCopy.format("tool.wrote", relativePath(file, workspace: workspace), content.utf8.count)
    }

    private static func removeFile(at path: String, reason: String, referenceTerms: String, workspace: URL) throws -> String {
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return failedRemovalMarker + " A removal reason is required." }
        let rawTerms = referenceTerms
            .split(whereSeparator: { ",;\n\r".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !rawTerms.isEmpty else { return failedRemovalMarker + " Reference search terms are required." }
        guard rawTerms.count <= 20, rawTerms.allSatisfy({ $0.count <= 200 }) else {
            return preservedRemovalMarker + " Reference search could not be bounded; file was kept."
        }
        let terms = rawTerms.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

        let lexical = URL(fileURLWithPath: path, relativeTo: workspace).standardizedFileURL
        let file = try resolve(path, workspace: workspace)
        guard fileManager().fileExists(atPath: file.path) else { return preservedRemovalMarker + " File was not found: \(path)" }
        let values = try lexical.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if values.isSymbolicLink == true { return preservedRemovalMarker + " Symlink removal is not allowed: \(path)" }
        if values.isDirectory == true { return preservedRemovalMarker + " Directory removal is not allowed: \(path)" }
        guard isCleanupCandidate(file) else { return preservedRemovalMarker + " This file is protected from agent cleanup: \(path)" }

        let root = workspace.standardizedFileURL
        guard let enumerator = fileManager().enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else {
            return preservedRemovalMarker + " Reference scan could not be verified; file was kept."
        }
        var count = 0
        while let candidate = enumerator.nextObject() as? URL {
            let relative = relativePath(candidate, workspace: root)
            let components = relative.split(separator: "/").map(String.init)
            if components.contains(where: { ignoredScanDirectories.contains($0) }) {
                if (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                continue
            }
            let candidateValues = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if candidateValues.isSymbolicLink == true {
                if candidateValues.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard candidateValues.isRegularFile == true,
                  candidate.standardizedFileURL.path != file.standardizedFileURL.path,
                  isCleanupCandidate(candidate) else { continue }
            count += 1
            guard count <= 5_000 else { return preservedRemovalMarker + " Reference scan limit reached; file was kept." }
            let text = try String(contentsOf: candidate, encoding: .utf8)
            if terms.contains(where: { text.contains($0) }) {
                return preservedRemovalMarker + " Live reference found; file was kept: \(relativePath(file, workspace: root))"
            }
        }

        do {
            try fileManager().removeItem(at: file)
        } catch {
            return failedRemovalMarker + " File deletion failed: \(error.localizedDescription)"
        }
        guard !fileManager().fileExists(atPath: file.path) else { return failedRemovalMarker + " File deletion could not be verified: \(path)" }
        return verifiedRemovalMarker + " Removed \(relativePath(file, workspace: root)). Reason: \(reason.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private static func isCleanupCandidate(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if protectedNames.contains(name) || name.hasPrefix(".env") { return false }
        let lower = name.lowercased()
        if ["credential", "secret", "token", "password", "keychain", "keystore"].contains(where: { lower.contains($0) }) { return false }
        if ["db", "sqlite", "sqlite3", "pem", "key", "p12", "pfx"].contains(url.pathExtension.lowercased()) { return false }
        return cleanupExtensions.contains(url.pathExtension.lowercased())
    }

    private static func fileManager() -> FileManager { .default }

    private static func run(
        command: String,
        workspace: URL,
        sandboxPolicy: SandboxExecutionPolicy? = nil,
        isCancelled: @Sendable () -> Bool = { false },
        onOutput: (@Sendable (String) -> Void)? = nil,
        onExit: ((Int32) -> Void)? = nil
    ) throws -> String {
        if command.range(of: #"(?:^|[\s/])\.mem(?:[\s/]|$)"#, options: .regularExpression) != nil {
            throw NativeAgentError(AppCopy.text("tool.pathUnavailable"))
        }
        let process = Process()
        let output = Pipe()
        if let sandboxPolicy {
            let workspacePath = SandboxProfile.canonicalURL(workspace).path
            guard workspacePath == sandboxPolicy.workspaceURL.path else {
                throw NativeAgentError("Sandbox policy workspace does not match the command workspace.")
            }
            process.executableURL = SandboxProfile.executableURL
            process.arguments = try SandboxProfile.arguments(
                executable: "/bin/zsh",
                arguments: ["-lc", command],
                policy: sandboxPolicy
            )
            process.environment = ProcessInfo.processInfo.environment
                .merging(SandboxProfile.cacheEnvironment(workspaceURL: workspace)) { _, new in new }
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
        }
        process.currentDirectoryURL = workspace
        process.standardOutput = output
        process.standardError = output

        // Drain the pipe concurrently: a poll-then-read approach deadlocks once the
        // child fills the ~64KB pipe buffer and blocks on write before it can exit.
        let sink = OutputSink()
        let reader = output.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                sink.append(chunk)
                if let text = String(data: chunk, encoding: .utf8) { onOutput?(text) }
            }
        }
        try process.run()

        let pid = process.processIdentifier
        // Put the child in its own process group so a timeout or a user cancel
        // can signal the whole tree — background jobs (`&`), pipelines,
        // `npm` → node — not just the top-level zsh. Racing the child's exec
        // here is benign: on the rare EACCES the child is still in our group and
        // we fall back to signalling just its pid.
        let group: pid_t = (setpgid(pid, pid) == 0) ? -pid : pid

        // SIGTERM the tree, give it up to 2s to unwind, then SIGKILL whatever
        // ignored it, and reap the direct child so it cannot linger as a zombie.
        func halt() {
            kill(group, SIGTERM)
            var waited = 0.0
            while process.isRunning, waited < 2.0 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                waited += 0.05
            }
            if process.isRunning { kill(group, SIGKILL) }
            process.waitUntilExit()
            reader.readabilityHandler = nil
        }

        let deadline = Date().addingTimeInterval(45)
        while process.isRunning {
            if isCancelled() {
                halt()
                return "Command canceled after user interrupt."
            }
            if Date() >= deadline {
                halt()
                return AppCopy.text("tool.timedOut")
            }
            try awaitRunLoop()
        }
        process.waitUntilExit()
        reader.readabilityHandler = nil

        onExit?(process.terminationStatus)
        let data = sink.drain()
        let text = String(data: data.prefix(24_000), encoding: .utf8) ?? AppCopy.text("tool.binaryOutput")
        let suffix = process.terminationStatus == 0
            ? ""
            : "\n" + AppCopy.format("tool.exitStatus", process.terminationStatus)
        return text.isEmpty ? AppCopy.text("tool.noOutput") + suffix : text + suffix
    }

    /// Runs a verification command and says whether it exited zero. The exit
    /// status is taken from the process, never parsed out of the localized text;
    /// a timeout, a cancel or a command that could not start all count as failed.
    static func runCheck(
        command: String,
        workspace: URL,
        sandboxPolicy: SandboxExecutionPolicy? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> (output: String, passed: Bool) {
        var status: Int32?
        do {
            let output = try run(
                command: command, workspace: workspace, sandboxPolicy: sandboxPolicy,
                isCancelled: isCancelled, onExit: { status = $0 }
            )
            return (output, status == 0)
        } catch {
            return (AppCopy.format("tool.error", error.localizedDescription), false)
        }
    }

    private static func awaitRunLoop() throws {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    /// The path a write lease is keyed by. It resolves exactly like the write
    /// itself, so a lease and the file it protects can never disagree.
    static func canonicalLeasePath(_ path: String, workspace: URL) -> String {
        URL(fileURLWithPath: path.isEmpty ? "." : path, relativeTo: workspace)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    /// Drops a file from a conversation's read ledger, for the case where the whole
    /// file was read but the answer handed to the model was shortened afterwards:
    /// a read the model never saw in full must not authorize a rewrite.
    static func forgetRead(
        _ call: AgentToolCall,
        workspace: URL,
        conversationID: String,
        readRoots: [URL]
    ) {
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["path"] as? String,
              let file = try? resolveRead(path, workspace: workspace, readRoots: readRoots) else { return }
        ReadLedger.shared.forget(file, conversationID: conversationID)
    }

    static func resolve(_ path: String, workspace: URL) throws -> URL {
        let relative = path.isEmpty ? "." : path
        // resolvingSymlinksInPath() is required: standardizedFileURL only normalizes
        // syntax, so a symlink placed inside the workspace would slip past the prefix
        // check (e.g. workspace/escape -> /etc, then read escape/hosts).
        let url = URL(fileURLWithPath: relative, relativeTo: workspace).standardizedFileURL.resolvingSymlinksInPath()
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path == root.path || url.path.hasPrefix(rootPath) else {
            throw NativeAgentError(AppCopy.format("tool.pathOutside", path))
        }
        let memoryRoot = root.appendingPathComponent(".mem").path
        guard url.path != memoryRoot && !url.path.hasPrefix(memoryRoot + "/") else {
            throw NativeAgentError(AppCopy.text("tool.pathUnavailable"))
        }
        return url
    }

    private static func resolveRead(_ path: String, workspace: URL, readRoots: [URL]) throws -> URL {
        if !path.hasPrefix("/") {
            return try resolve(path, workspace: workspace)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let allowedRoots = [workspace] + readRoots
        guard allowedRoots.contains(where: { root in
            let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
            let rootPath = canonical.path.hasSuffix("/") ? canonical.path : canonical.path + "/"
            return url.path == canonical.path || url.path.hasPrefix(rootPath)
        }) else {
            throw NativeAgentError(AppCopy.format("tool.pathOutside", path))
        }
        guard !url.path.contains("/.mem/") && !url.path.hasSuffix("/.mem") else {
            throw NativeAgentError(AppCopy.text("tool.pathUnavailable"))
        }
        return url
    }

    static func relativePath(_ url: URL, workspace: URL) -> String {
        let root = workspace.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path == root ? "." : path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Thread-safe accumulator for a pipe's readabilityHandler callbacks.
    private final class OutputSink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
        }

        func drain() -> Data {
            lock.lock(); defer { lock.unlock() }
            return data
        }
    }
}

/// One-way cancel latch shared between a detached tool run and the
/// `withTaskCancellationHandler` that watches the owning turn.
public final class ToolCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

/// Remembers the content hash of every file a conversation has fully read, so
/// `write_file` can tell an informed rewrite from a blind one. Scoped per
/// conversation: what one chat read says nothing about what another chat has
/// written since, so a shared ledger would let a second conversation rewrite a
/// file it never saw. Bounded per conversation; forgetting an entry only costs one
/// extra read.
final class ReadLedger: @unchecked Sendable {
    enum State { case fresh, stale, unread }

    static let shared = ReadLedger()
    private let lock = NSLock()
    private var scopes: [String: Scope] = [:]
    private let capacity = 512

    private struct Scope {
        var hashes: [String: String] = [:]
        var pages: [String: PageRead] = [:]
        var order: [String] = []
    }

    private struct PageRead {
        let hash: String
        var lines = IndexSet()
    }

    func recordLines(_ file: URL, data: Data, lines: Range<Int>, totalLines: Int, conversationID: String) {
        guard !lines.isEmpty else { return }
        let hash = Self.hash(data)
        lock.lock(); defer { lock.unlock() }
        var scope = scopes[conversationID, default: Scope()]
        if scope.hashes[file.path] == hash { return }
        if !scope.order.contains(file.path) { scope.order.append(file.path) }
        scope.hashes[file.path] = nil
        var page = scope.pages[file.path].flatMap { $0.hash == hash ? $0 : nil } ?? PageRead(hash: hash)
        page.lines.insert(integersIn: lines)
        if page.lines.contains(integersIn: 1..<(totalLines + 1)) {
            scope.hashes[file.path] = hash
            scope.pages[file.path] = nil
        } else {
            scope.pages[file.path] = page
        }
        while scope.order.count > capacity, let oldest = scope.order.first {
            scope.order.removeFirst()
            scope.hashes[oldest] = nil
            scope.pages[oldest] = nil
        }
        scopes[conversationID] = scope
    }

    func record(_ file: URL, data: Data, conversationID: String) {
        let hash = Self.hash(data)
        lock.lock(); defer { lock.unlock() }
        var scope = scopes[conversationID, default: Scope()]
        if !scope.order.contains(file.path) { scope.order.append(file.path) }
        scope.hashes[file.path] = hash
        scope.pages[file.path] = nil
        while scope.order.count > capacity, let oldest = scope.order.first {
            scope.order.removeFirst()
            scope.hashes[oldest] = nil
            scope.pages[oldest] = nil
        }
        scopes[conversationID] = scope
    }

    func forget(_ file: URL, conversationID: String) {
        lock.lock(); defer { lock.unlock() }
        guard var scope = scopes[conversationID] else { return }
        scope.hashes.removeValue(forKey: file.path)
        scope.pages.removeValue(forKey: file.path)
        scope.order.removeAll { $0 == file.path }
        scopes[conversationID] = scope
    }

    /// Lines (1-based) read from exactly this version. A complete read covers the
    /// whole file. Stale when an older version was read; unread when nothing was.
    func coverage(for file: URL, data: Data, totalLines: Int, conversationID: String) -> (state: State, lines: IndexSet) {
        let hash = Self.hash(data)
        lock.lock(); defer { lock.unlock() }
        let scope = scopes[conversationID]
        if let known = scope?.hashes[file.path] {
            return known == hash ? (.fresh, IndexSet(integersIn: 1..<(totalLines + 1))) : (.stale, IndexSet())
        }
        if let page = scope?.pages[file.path] {
            return page.hash == hash ? (.fresh, page.lines) : (.stale, IndexSet())
        }
        return (.unread, IndexSet())
    }

    func state(for file: URL, data: Data, conversationID: String) -> State {
        lock.lock()
        let known = scopes[conversationID]?.hashes[file.path]
        lock.unlock()
        guard let known else { return .unread }
        return known == Self.hash(data) ? .fresh : .stale
    }

    /// A closed conversation can never write again, so its reads must stop
    /// authorizing rewrites anywhere.
    func forgetConversation(_ conversationID: String) {
        lock.lock(); defer { lock.unlock() }
        scopes[conversationID] = nil
    }

    /// Test seam: a fresh ledger per test keeps the shared one out of it.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        scopes.removeAll()
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
