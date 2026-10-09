import Foundation

/// Tools the on-phone agent gets over the local workspace mirror. Every path is
/// resolved through `LocalWorkspaceStore.resolve`, so a traversal in a model's
/// tool call fails the same way a bad snapshot path does.
enum AgentTools {
    static let maximumReadCharacters = 60_000
    static let maximumListedFiles = 2_000

    static func readFile(at url: URL, offset: Int? = nil, limit: Int? = nil) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return "File is not UTF-8 text: \(url.lastPathComponent)" }
        let lines = text.components(separatedBy: "\n")
        let start = max(1, offset ?? 1)
        guard start <= lines.count else { return "Offset is past the end of the file; it has \(lines.count) lines." }
        let count = min(lines.count - start + 1, max(0, limit ?? lines.count))
        let end = start + count
        var emitted: [String] = []
        var size = 0
        var line = start
        while line < end {
            let candidate = lines[line - 1]
            let cost = candidate.utf8.count + 1
            if size + cost > maximumReadCharacters && !emitted.isEmpty { break }
            emitted.append(candidate)
            size += cost
            line += 1
        }
        ReadLedger.shared.recordLines(url, data: data, lines: start..<line, totalLines: lines.count)
        let body = emitted.joined(separator: "\n")
        return line >= end ? body : body + "\n\n[truncated] Continue with offset: \(line)"
    }
    static let askUserAnsweredDirective = """
    The user answered your clarification. Continue the original request now in the current mode: perform the
    requested work in ordinary execution, or return the complete plan in plan mode. Do not send a status-only
    reply while tools can proceed. Preserve unrelated pre-existing edits automatically; do not mention them
    unless a specific inspected conflict blocks the requested change.
    """
    static let verifiedMarker = "[cleanup:verified]"
    static let preservedMarker = "[cleanup:preserved]"
    static let failedMarker = "[cleanup:failed]"
    private static let allowedExtensions: Set<String> = ["c", "cc", "cpp", "cs", "csproj", "gradle", "h", "hpp", "ini", "java", "js", "jsx", "json", "kt", "kts", "mm", "plist", "props", "py", "resx", "rs", "swift", "targets", "toml", "ts", "tsx", "xml", "xaml", "yaml", "yml"]
    private static let protectedFragments = [".env", "credential", "secret", "token", "password", "keychain", "keystore"]
    private static let protectedExtensions: Set<String> = ["db", "sqlite", "sqlite3", "key", "pem", "p12", "pfx", "cer"]

    static func workspace(_ store: LocalWorkspaceStore) -> [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "list_files",
                description: "List files in the workspace. Optionally filter by a path prefix.",
                schema: object(["prefix": string("Only list paths starting with this prefix.")])
            ) { input in
                let prefix = input.string("prefix") ?? ""
                let paths = await MainActor.run { Self.walk(store) }
                    .filter { prefix.isEmpty || $0.hasPrefix(prefix) }
                if paths.isEmpty { return "No files matched." }
                return paths.prefix(maximumListedFiles).joined(separator: "\n")
            },

            AgentToolSpec(
                name: "read_file",
                description: "Read whole lines of a UTF-8 file. Use offset and limit to page through long files; all pages of the same version together authorize editing.",
                schema: object([
                    "path": string("Workspace-relative file path."),
                    "offset": ["type": "integer", "description": "First line, 1-based. Defaults to 1."],
                    "limit": ["type": "integer", "description": "Maximum number of lines to read."],
                ], required: ["path"])
            ) { input in
                let path = try input.required("path", tool: "read_file")
                let url = try await MainActor.run { try store.resolve(path) }
                let body = try readFile(at: url, offset: input.int("offset"), limit: input.int("limit"))
                let learned = await MainActor.run { MobileLessons.fileNotice(root: store.root, path: path) }
                return body + learned
            },

            AgentToolSpec(
                name: "write_file",
                description: "Create or overwrite a UTF-8 text file in the workspace. Rewriting a file you have not read, or one that changed since you read it, is refused.",
                schema: object([
                    "path": string("Workspace-relative file path."),
                    "content": string("Full new file contents."),
                ], required: ["path", "content"])
            ) { input in
                let path = try input.required("path", tool: "write_file")
                let content = input.string("content") ?? ""
                let result: String = try await MainActor.run {
                    let target = try store.resolve(path)
                    if let current = try? Data(contentsOf: target) {
                        switch ReadLedger.shared.state(for: target, data: current) {
                        case .unread: return "write_file needs a prior read_file for \(path). Read it first."
                        case .stale: return "write_file: \(path) changed since you last read it. Read it again."
                        case .fresh: break
                        }
                    }
                    try store.write(relativePath: path, data: Data(content.utf8))
                    // Record the just-written hash so a second write without re-read still passes,
                    // matching `WorkspaceTools.writeFile:341`.
                    if let written = try? Data(contentsOf: target) { ReadLedger.shared.record(target, data: written) }
                    else { ReadLedger.shared.record(target, data: Data(content.utf8)) }
                    return "Wrote \(content.utf8.count) bytes to \(path)." + MobileLessons.fileNotice(root: store.root, path: path)
                }
                return result
            },

            AgentToolSpec(
                name: FileEditTools.editName,
                description: """
                Replace exact text inside an existing file, without rewriting the rest of it. \
                Prefer this over write_file for any edit to a file you have already read. Each \
                old_text must match the file byte for byte and appear exactly once unless \
                replace_all is set; a match that is not unique is refused rather than guessed \
                at, so widen it with surrounding lines. Creating a new file still needs write_file.
                """,
                schema: [
                    "type": "object",
                    "properties": [
                        "path": string("Relative path to the existing file."),
                        "edits": [
                            "type": "array",
                            "description": "Replacements applied in order, all or none.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "old_text": string("Exact text to replace, copied from read_file."),
                                    "new_text": string("Replacement text. Empty deletes the match."),
                                    "replace_all": [
                                        "type": "boolean",
                                        "description": "Replace every occurrence instead of requiring one unique match.",
                                    ],
                                ],
                                "required": ["old_text", "new_text"],
                                "additionalProperties": false,
                            ],
                        ],
                    ],
                    "required": ["path", "edits"],
                    "additionalProperties": false,
                ]
            ) { input in
                let path = try input.required("path", tool: FileEditTools.editName)
                guard let edits = input.objectArray("edits") else {
                    return "Tool error: edits must be an array of {old_text, new_text} objects."
                }
                return await FileEditTools.edit(path: path, edits: edits) { relative in
                    try await MainActor.run { try store.resolve(relative) }
                }
            },

            AgentToolSpec(
                name: FileEditTools.globName,
                description: """
                Find files by name pattern inside the workspace and get back paths newest-first. \
                Supports * and ? within one path segment, ** across segments, and {a,b} groups — \
                so "**/*.swift", "Sources/**/*Test*.swift", "config.{json,yml}". A pattern with no \
                slash matches filenames at any depth. Use search_files instead when the content, not \
                the name, is what you are looking for.
                """,
                schema: [
                    "type": "object",
                    "properties": [
                        "pattern": string("Glob pattern, relative to the searched directory."),
                        "path": string("Relative directory to search. Defaults to the workspace root."),
                    ],
                    "required": ["pattern"],
                    "additionalProperties": false,
                ]
            ) { input in
                let pattern = try input.required("pattern", tool: FileEditTools.globName)
                let path = input.string("path") ?? ""
                return await FileEditTools.glob(pattern: pattern, path: path) { relative in
                    try await MainActor.run { try store.resolve(relative) }
                }
            },

            AgentToolSpec(
                name: "remove_file",
                description: "Remove one proven-unused source, config, test, or import artifact. Requires a reason and reference terms; credentials, state, user data, directories, and symlinks are never removable.",
                schema: object([
                    "path": string("Workspace-relative file path."),
                    "reason": string("Why the old artifact is no longer part of the active architecture."),
                    "referenceTerms": string("Old symbols or paths to search for, separated by commas, semicolons, or new lines."),
                ], required: ["path", "reason", "referenceTerms"])
            ) { input in
                let path = try input.required("path", tool: "remove_file")
                let reason = try input.required("reason", tool: "remove_file")
                let referenceTerms = try input.required("referenceTerms", tool: "remove_file")
                return await MainActor.run { Self.removeFile(path: path, reason: reason, referenceTerms: referenceTerms, store: store) }
            },

            AgentToolSpec(
                name: "search_files",
                description: "Search workspace text files for a regular expression.",
                schema: object([
                    "pattern": string("Regular expression to match."),
                    "prefix": string("Only search paths starting with this prefix."),
                ], required: ["pattern"])
            ) { input in
                let regex = try NSRegularExpression(pattern: try input.required("pattern", tool: "search_files"))
                let prefix = input.string("prefix") ?? ""
                let paths = await MainActor.run { Self.walk(store) }.filter { prefix.isEmpty || $0.hasPrefix(prefix) }
                var hits: [String] = []
                for path in paths {
                    guard let url = try? await MainActor.run(body: { try store.resolve(path) }),
                          let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                        let value = String(line)
                        if regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil {
                            hits.append("\(path):\(index + 1): \(value.prefix(300))")
                            if hits.count >= 200 { return hits.joined(separator: "\n") + "\n… more matches not listed" }
                        }
                    }
                }
                return hits.isEmpty ? "No matches." : hits.joined(separator: "\n")
            },
        ]
    }

    /// Shell and SQL, so the agent reaches the same runtimes the user does from
    /// the Terminal tab rather than a parallel set of file primitives.
    /// When a desktop is paired, build-like commands are forwarded to it via
    /// `RemoteControlClient` (real `zsh`); otherwise the virtual shell runs them.
    @MainActor
    static func runtime(shell: LocalShell, store: LocalWorkspaceStore, git: MobileGitClient? = nil, remote: RemoteControlClient? = nil) -> [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "run_command",
                description: "Run a command. Virtual commands (\(LocalShell.commands.joined(separator: ", "))) run on-phone; build/test commands (npm, swift, dotnet, cargo, pytest, gradle, xcodebuild) are forwarded to the paired desktop when available, otherwise they return a remote-unavailable hint.",
                schema: object(["command": string("The command line to run.")], required: ["command"])
            ) { input in
                let command = try input.required("command", tool: "run_command")
                // Try remote runner for heavy commands when a desktop is paired.
                if let remote, Self.shouldTryRemote(command), await MainActor.run(body: {
                    remote.isPaired && store.selectedProject.remoteProjectID != nil && store.selectedProject.remoteProjectID == remote.remoteSelectedProjectID
                }) {
                    if let remoteOutput = await Self.runRemote(command, remote: remote) {
                        return remoteOutput.ifEmpty("(no output)")
                    }
                }
                return await MainActor.run { shell.execute(command) }.ifEmpty("(no output)")
            },

            AgentToolSpec(
                name: "ask_user",
                description: "Ask only for material information the workspace cannot answer. A pre-existing dirty or staged worktree is not a reason to ask; preserve it without mentioning it. After the user answers, immediately continue the original request in the current mode and do not send a status-only reply while tools can proceed.",
                schema: object(["question": string("The question to show the user.")], required: ["question"])
            ) { _ in
                "The user answer is pending."
            },

            AgentToolSpec(
                name: "computer_use",
                description: "Interact with the paired desktop's environment: capture a screenshot, move the mouse, click, type, press keys, or scroll. Requires a paired desktop with Computer Use enabled in its Settings; the desktop's approval policy applies (approval happens in Settings → Tools → Live events).",
                schema: Self.computerUseSchema
            ) { input in
                let action = try input.required("action", tool: "computer_use")
                guard let remote, await MainActor.run(body: { remote.isPaired }) else {
                    return "unsupported_on_mobile: Computer Use requires a paired desktop (macOS, Windows, or Linux) with Computer Use enabled."
                }
                var payload: [String: RemoteJSONValue] = ["action": .string(action)]
                for key in ["button", "text", "key", "path"] {
                    if let value = input.string(key) { payload[key] = .string(value) }
                }
                for key in ["x", "y", "dx", "dy"] {
                    if let value = input.int(key) { payload[key] = .number(Double(value)) }
                }
                do {
                    let response = try await remote.command(kind: "computer_use", payload: payload)
                    if response.status == "approval-required", let approvalId = response.approvalId {
                        return "The paired desktop needs approval for this computer_use action (approval id \(approvalId)). Open Settings → Tools → Live events to allow or reject it, then retry."
                    }
                    if let message = response.error, !message.isEmpty { return "computer_use failed: \(message)" }
                    if case .object(let object) = response.result {
                        if let output = object["output"]?.string ?? object["outputPreview"]?.string, !output.isEmpty { return output }
                    }
                    if case .string(let output) = response.result, !output.isEmpty { return output }
                    return "computer_use \(action) completed on the paired desktop."
                } catch {
                    return "computer_use failed on the paired desktop: \(error.localizedDescription)"
                }
            },

            AgentToolSpec(
                name: "native_browser",
                description: "Use the paired desktop's native in-app browser to open pages, read page text, inspect/evaluate JavaScript, click, type, or navigate history. Requires the selected desktop project and desktop approval.",
                schema: Self.nativeBrowserSchema
            ) { input in
                guard let remote, await MainActor.run(body: {
                    remote.isPaired && store.selectedProject.remoteProjectID != nil
                        && store.selectedProject.remoteProjectID == remote.remoteSelectedProjectID
                }) else {
                    return "unsupported_on_mobile: native_browser requires a paired desktop with the same project selected."
                }
                let action = try input.required("action", tool: "native_browser")
                var payload: [String: RemoteJSONValue] = ["action": .string(action)]
                for key in ["url", "path", "script", "selector", "text"] {
                    if let value = input.string(key), !value.isEmpty { payload[key] = .string(value) }
                }
                for key in ["x", "y"] {
                    if let value = input.int(key) { payload[key] = .number(Double(value)) }
                }
                do {
                    let response = try await remote.command(kind: "native_browser", payload: payload)
                    if response.status == "approval-required" {
                        return "The paired desktop needs approval for this browser action. Approve it in Settings → Tools → Live events, then retry."
                    }
                    if let error = response.error, !error.isEmpty { return "native_browser failed: \(error)" }
                    if case .object(let result) = response.result,
                       let output = result["output"]?.string ?? result["outputPreview"]?.string { return output }
                    if case .string(let output) = response.result { return output }
                    return "native_browser \(action) completed on the paired desktop."
                } catch { return "native_browser failed on the paired desktop: \(error.localizedDescription)" }
            },

            AgentToolSpec(
                name: "sql",
                description: "Run SQL against a SQLite database file in the workspace.",
                schema: object([
                    "database": string("Workspace-relative path to the .db file."),
                    "statement": string("SQL to execute."),
                ], required: ["database", "statement"])
            ) { input in
                let database = try input.required("database", tool: "sql")
                let statement = try input.required("statement", tool: "sql")
                let url = try await MainActor.run { try store.resolve(database) }
                return try LocalSQL(path: url).run(statement).ifEmpty("(no rows)")
            },

            AgentToolSpec(
                name: "remember",
                description: "Record something that must outlive this conversation: a lasting user preference, a settled project choice, or a standing fact about the project. One call per fact, with a short stable key so a later fact on the same subject replaces it. Never record a secret, a guess, or what only matters to the current request.",
                schema: object([
                    "kind": string("preference: how the user wants work done. decision: a settled project choice. project: a standing fact about the project."),
                    "key": string("Short stable subject, e.g. \"language\", \"goal\", \"design-system\"."),
                    "text": string("The fact itself, one sentence, written so it stands alone months later. The project keys \"architecture\", \"conventions\" and \"design-system\" may run to 1,200 characters."),
                ], required: ["kind", "text"])
            ) { input in
                let kind = try input.required("kind", tool: "remember")
                let text = try input.required("text", tool: "remember")
                let key = input.string("key") ?? ""
                return await MainActor.run { MobileFacts.record(root: store.root, kind: kind, key: key, text: text) }
            },

            AgentToolSpec(
                name: "git",
                description: "Run a real local Git operation through the native libgit2 backend. Supported operations: clone, fetch, checkout, create_branch, status, diff, commit, push.",
                schema: object([
                    "operation": string("Git operation to run."),
                    "argument": string("URL, branch, or commit message, depending on the operation."),
                    "second": string("Remote or branch, depending on the operation."),
                    "authorName": string("Commit author name."),
                    "authorEmail": string("Commit author email."),
                ], required: ["operation"])
            ) { input in
                guard let git else { return "unsupported_on_mobile: the native MobileGitClient backend is not linked." }
                let operation = try input.required("operation", tool: "git")
                var arguments: [String: String] = [:]
                for key in ["argument", "second", "authorName", "authorEmail"] {
                    if let value = input.string(key) { arguments[key] = value }
                }
                let result = await git.execute(operation: operation, arguments: arguments)
                return result.unavailable ? "unsupported_on_mobile: \(result.output)" : result.output.ifEmpty("(no output)")
            },
        ]
    }

    // MARK: - Computer Use schema

    /// Mirrors the desktop `ComputerUseTools` schema so the model can pass the
    /// same arguments it would on macOS; the relay forwards them untouched.
    nonisolated(unsafe) static let computerUseSchema: [String: Any] = object([
        "action": [
            "type": "string",
            "enum": ["screenshot", "mouse_move", "left_click", "right_click", "middle_click", "double_click", "triple_click", "mouse_down", "mouse_up", "type", "key", "scroll"],
            "description": "Action to perform on the paired desktop.",
        ] as [String: Any],
        "x": ["type": "integer", "description": "X screen coordinate for mouse actions."] as [String: Any],
        "y": ["type": "integer", "description": "Y screen coordinate for mouse actions."] as [String: Any],
        "dx": ["type": "integer", "description": "Horizontal scroll amount for the scroll action."] as [String: Any],
        "dy": ["type": "integer", "description": "Vertical scroll amount for the scroll action."] as [String: Any],
        "button": [
            "type": "string",
            "enum": ["left", "right", "middle"],
            "description": "Mouse button for mouse_down and mouse_up.",
        ] as [String: Any],
        "text": ["type": "string", "description": "Text to type for the type action."] as [String: Any],
        "key": ["type": "string", "description": "Key combination (for example cmd+shift+s) for the key action."] as [String: Any],
        "path": ["type": "string", "description": "Destination path for screenshot, relative to the desktop workspace."] as [String: Any],
    ], required: ["action"])

    // MARK: - Remote runner helpers

    private static let remoteHeavyPattern = #"(?i)(^|[\s;&|])(npm|yarn|pnpm|swift|dotnet|cargo|pytest|gradle|xcodebuild|make|cmake|bundle|pod|fastlane)(\s|$)"#

    static func shouldTryRemote(_ command: String) -> Bool {
        command.range(of: remoteHeavyPattern, options: .regularExpression) != nil
    }

    private static func runRemote(_ command: String, remote: RemoteControlClient) async -> String? {
        // Check pairing on main actor
        let isPaired = await MainActor.run { remote.isPaired }
        guard isPaired else { return nil }
        do {
            let response = try await remote.command(kind: "run_command", payload: ["command": .string(command)])
            // Desktop may require approval
            if response.status == "approval-required", let approvalId = response.approvalId {
                return "Remote desktop needs approval (id \(approvalId)). Approve on desktop Settings → Access Mode, or run a virtual command."
            }
            if response.status == "failed" || response.httpStatus == 401 || response.httpStatus == 404 {
                return nil // fallback to virtual shell
            }
            // Try artifact first (full output)
            if case .object(let obj) = response.result {
                if let artifactId = obj["artifactId"]?.string, !artifactId.isEmpty {
                    if let full = try? await remote.artifactText(artifactId), !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return full
                    }
                }
                if let preview = obj["outputPreview"]?.string, !preview.isEmpty { return preview }
                if let out = obj["output"]?.string, !out.isEmpty { return out }
            }
            if let msg = response.error, !msg.isEmpty { return msg }
            return nil
        } catch {
            // Network / pairing error → fallback
            return nil
        }
    }

    @MainActor
    static func walk(_ store: LocalWorkspaceStore) -> [String] {
        (try? store.agentFiles().map(\.path)) ?? []
    }

    static func mayDeleteFiles(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.range(of: #"(?i)(^|[\s;&|])(rm|unlink|rmdir|del|erase|Remove-Item|git\s+clean)([\s]|$)"#, options: .regularExpression) != nil
    }

    @MainActor
    static func removeFile(path: String, reason: String, referenceTerms: String, store: LocalWorkspaceStore) -> String {
        let terms = referenceTerms.split(whereSeparator: { ",;\n\r".contains($0) }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !terms.isEmpty, terms.count <= 20, terms.allSatisfy({ $0.count <= 200 }) else {
            return "\(preservedMarker) Removal needs a reason and bounded reference terms."
        }
        do {
            if try store.hasSymlinkComponent(path) {
                return "\(preservedMarker) Symlink removal is not allowed; the artifact was kept."
            }
            let target = try store.resolve(path)
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            let lowerName = target.lastPathComponent.lowercased()
            let lowerExtension = target.pathExtension.lowercased()
            guard values.isRegularFile == true, values.isDirectory != true, values.isSymbolicLink != true else {
                return "\(preservedMarker) The target is a directory, symlink, or non-regular file and was kept."
            }
            guard !protectedFragments.contains(where: { lowerName.contains($0) }), !protectedExtensions.contains(lowerExtension), lowerName != "provider-state.json", lowerName != "conversations.json", lowerName != "state.sqlite" else {
                return "\(preservedMarker) Credential, state, or user data is protected and was kept."
            }
            guard allowedExtensions.contains(lowerExtension) else {
                return "\(preservedMarker) Only source, config, test, and import artifacts can be removed."
            }
            let files = try store.agentFiles()
            guard files.count <= 5_000 else { return "\(preservedMarker) Cleanup could not be verified because the workspace is too large to scan safely." }
            let targetPath = target.standardizedFileURL.path
            for file in files where allowedExtensions.contains(URL(fileURLWithPath: file.path).pathExtension.lowercased()) {
                let candidate = try store.resolve(file.path)
                guard candidate.standardizedFileURL.path != targetPath else { continue }
                let text = try String(contentsOf: candidate, encoding: .utf8)
                if terms.contains(where: { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
                    return "\(preservedMarker) A live reference was found; the old artifact was kept."
                }
            }
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                return "\(failedMarker) The artifact could not be removed: \(error.localizedDescription)"
            }
            guard !FileManager.default.fileExists(atPath: target.path) else { return "\(failedMarker) The artifact could not be verified as removed." }
            return "\(verifiedMarker) Removed proven-unused artifact \(path)."
        } catch {
            return "\(preservedMarker) Cleanup could not be verified; the artifact was kept."
        }
    }

    static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    @MainActor
    private static let nativeBrowserSchema: [String: Any] = object([
        "action": ["type": "string", "enum": ["open", "navigate", "get_content", "screenshot", "evaluate_js", "click", "type", "reload", "back", "forward"]],
        "url": string("URL to open or navigate to."),
        "path": string("Optional screenshot path relative to the selected desktop project."),
        "script": string("JavaScript to evaluate in the desktop browser."),
        "selector": string("CSS selector for click or type."),
        "text": string("Text to type into the selected element."),
        "x": ["type": "integer", "description": "Optional click coordinate."],
        "y": ["type": "integer", "description": "Optional click coordinate."],
    ], required: ["action"])

    static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self }
}
