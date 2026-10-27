// Copyright (c) 2026 DOTS
// Project event compatibility and replay. New project facts use `.mem/facts.md`.

import CryptoKit
import Foundation
import PluginRuntime

private struct WorkspaceProjectMapUpdate: Sendable {
    let root: URL
    let technologies: [String]
    let mapText: String
    let recordTechnologies: Bool
    let indexData: Data?
    let mapNote: String?
}

extension WorkspaceMemory {
    /// Repository entries are untrusted: a symlink can point at any file, so it is deleted and never copied.
    /// Returns true when the entry was a symlink.
    private func discardSymbolicLink(_ url: URL) -> Bool {
        guard isSymbolicLink(url) else { return false }
        try? fileManager.removeItem(at: entryPath(url))
        return true
    }

    /// Asks about the link itself, not the file it names. A directory URL carries a trailing
    /// slash, and a lookup through it follows the link, so every check uses the bare path.
    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? entryPath(url).resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private func entryPath(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent)
    }

    func loadExisting() {
        guard let root = memoryDirectory else { return }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let loaded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              loaded["schemaVersion"] as? Int == 1,
              loaded["projectId"] is String else { return }
        manifest = loaded
        // Written by earlier versions and never read: the vault travels with its
        // folder, and an absolute path differs on every machine that clones it.
        manifest?.removeValue(forKey: "workspaceRoot")
        loadLegacyIdentity()
        moveUserContentOutOfRepository()
        // Replay old event files for compatibility. New project facts use `.mem/facts.md`;
        // signatures no longer grant repository access. Builds before this one left state.json.
        rebuildProjection()
        mapText = (try? String(contentsOf: root.appendingPathComponent("map.md"), encoding: .utf8)) ?? ""
        if let projectID, let workspaceURL { profile.recordProject(name: workspaceURL.lastPathComponent, projectID: projectID) }
    }

    /// Creates the project's memory when the first prompt has not yet. Feedback needs the
    /// project id, which names the person's folder; opening a workspace does not call this.
    public func openProject() throws {
        guard enabled, workspaceURL != nil else { throw WorkspaceMemoryError.noWorkspace }
        if manifest == nil { try initializeWorkspace() }
    }

    func initializeWorkspace() throws {
        guard let root = memoryDirectory else { throw WorkspaceMemoryError.noWorkspace }
        // The manifest may have arrived since the workspace was opened (a checkout, a pull), or
        // be unreadable (a merge conflict). Overwriting it gives the project a new id and strands
        // every record kept under the old one, so an existing manifest is never replaced.
        let manifestURL = root.appendingPathComponent("manifest.json")
        if fileManager.fileExists(atPath: manifestURL.path) || isSymbolicLink(manifestURL) {
            loadExisting()
            guard manifest != nil else { throw WorkspaceMemoryError.invalidManifest }
            return
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let projectID = UUID().uuidString
        manifest = [
            "schemaVersion": 1,
            "projectId": projectID,
            "createdAt": isoNow(),
        ]
        try writeJSON(manifest!, to: root.appendingPathComponent("manifest.json"))
        if let workspaceURL { profile.recordProject(name: workspaceURL.lastPathComponent, projectID: projectID) }
    }

    /// Read only attribution fields from an old identity file when migrating local activity.
    /// The legacy private key is ignored; repository permissions are handled by Git.
    func loadLegacyIdentity() {
        guard identity == nil else { return }
        let identityURL = paths.root.appendingPathComponent("memory-identity.json")
        if let data = try? Data(contentsOf: identityURL),
           let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data) {
            identity = stored
        }
    }

    /// The root listing is compared on every prompt. The stack scan below it reads
    /// manifests two levels down, so it runs only when that listing changed or, with
    /// `deep`, when a finished task touched a manifest.
    func updateMapIfNeeded(deep: Bool = false) throws {
        guard let workspaceURL, let root = memoryDirectory else { return }
        let update = try Self.makeMapUpdate(
            workspace: workspaceURL,
            root: root,
            deep: deep,
            existingMapText: mapText
        )
        try applyMapUpdate(update)
    }

    func scheduleMapUpdateInBackground() {
        guard let workspaceURL = workspaceURL?.standardizedFileURL,
              let root = memoryDirectory,
              let projectID else { return }
        let requestKey = workspaceURL.path
        guard mapRefreshInFlight.insert(requestKey).inserted else { return }
        let cachedMapText = mapText

        Task { @MainActor [weak self] in
            let update = await MemoryWorkQueue.run {
                try? Self.makeMapUpdate(
                    workspace: workspaceURL,
                    root: root,
                    deep: false,
                    existingMapText: cachedMapText
                )
            }
            guard let self else { return }
            self.mapRefreshInFlight.remove(requestKey)
            guard self.enabled,
                  self.workspaceURL?.standardizedFileURL == workspaceURL,
                  self.projectID == projectID,
                  let update else { return }
            do { try self.applyMapUpdate(update) } catch { }
        }
    }

    private func applyMapUpdate(_ update: WorkspaceProjectMapUpdate) throws {
        stack = update.technologies
        mapText = update.mapText
        if update.recordTechnologies, let projectID {
            profile.recordTechnologies(update.technologies, projectID: projectID)
        }
        guard let indexData = update.indexData, let mapNote = update.mapNote else { return }
        try fileManager.createDirectory(at: update.root, withIntermediateDirectories: true)
        try indexData.write(to: update.root.appendingPathComponent("index.json"), options: .atomic)
        try mapNote.write(to: update.root.appendingPathComponent("map.md"), atomically: true, encoding: .utf8)
        writeIndexNote()
    }

    nonisolated private static func makeMapUpdate(
        workspace: URL,
        root: URL,
        deep: Bool,
        existingMapText: String
    ) throws -> WorkspaceProjectMapUpdate {
        let scanPaths = WorkspaceTools.scanFilePaths(workspace)
        let structure = mapStructure(workspace, paths: scanPaths)
        let indexURL = root.appendingPathComponent("index.json")
        let index = (try? Data(contentsOf: indexURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let known = index["technologies"] as? [String]
        // A map written by an older build is rebuilt even when the project has not moved.
        let rootUnchanged = index["schemaVersion"] as? Int == mapSchemaVersion
            && index["rootFingerprint"] as? String == structure.fingerprint
        if rootUnchanged, let known, !deep {
            return WorkspaceProjectMapUpdate(
                root: root,
                technologies: known,
                mapText: cachedMapText(in: root) ?? existingMapText,
                recordTechnologies: false,
                indexData: nil,
                mapNote: nil
            )
        }

        let technologies = detectTechnologies(in: workspace, paths: scanPaths)
        let documents = documentOutlines(in: workspace, paths: scanPaths)
        if rootUnchanged, known == technologies, index["documents"] as? [String] == documents {
            return WorkspaceProjectMapUpdate(
                root: root,
                technologies: technologies,
                mapText: existingMapText,
                recordTechnologies: true,
                indexData: nil,
                mapNote: nil
            )
        }

        let markdown = mapMarkdown(workspace, paths: scanPaths, structure: structure, technologies: technologies, documents: documents)
        let fingerprintInput = structure.fingerprint + "\n" + technologies.joined(separator: ",") + "\n" + documents.joined(separator: "\n")
        let fingerprint = SHA256.hash(data: Data(fingerprintInput.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let indexData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": mapSchemaVersion,
            "fingerprint": fingerprint,
            "rootFingerprint": structure.fingerprint,
            "updatedAt": mapTimestamp(),
            "topLevel": structure.topLevel,
            "manifests": structure.manifests,
            "technologies": technologies,
            "documents": documents,
        ], options: [.prettyPrinted, .sortedKeys])
        let mapFront = [
            "---",
            "id: map",
            "title: Project map",
            "type: map",
            "updated: \(mapTimestamp())",
            "tags: [map]",
            "links: [\"index\"]",
            "---",
        ].joined(separator: "\n")
        let mapNote = mapFront + "\n" + markdown + "\n\nBack to [[index]]\n"
        return WorkspaceProjectMapUpdate(
            root: root,
            technologies: technologies,
            mapText: markdown,
            recordTechnologies: true,
            indexData: indexData,
            mapNote: mapNote
        )
    }

    nonisolated private static func cachedMapText(in root: URL) -> String? {
        guard let note = try? String(contentsOf: root.appendingPathComponent("map.md"), encoding: .utf8),
              let start = note.range(of: "# Project Map") else { return nil }
        return note[start.lowerBound...].components(separatedBy: "\n\nBack to [[index]]")[0]
    }

    nonisolated private static func mapTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    /// 6: all map sections use the same ignore and sensitive-path policy as the code graph.
    nonisolated static let mapSchemaVersion = 6

    nonisolated private static func mapStructure(
        _ workspace: URL,
        paths: [String]
    ) -> (fingerprint: String, topLevel: [String], manifests: [String]) {
        var topLevel = Set<String>()
        var manifestPaths: [String] = []
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard let first = components.first else { continue }
            if components.count == 1 {
                let url = workspace.appendingPathComponent(path)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard size <= 1_000_000, !Self.binaryFileName(first) else { continue }
                topLevel.insert(first)
                if Self.isManifest(first) { manifestPaths.append(first) }
            } else {
                topLevel.insert(first + "/")
            }
        }
        return (WorkspaceTools.scanRevision(workspace, paths: paths), topLevel.sorted(), manifestPaths.sorted())
    }

    nonisolated private static func mapMarkdown(
        _ workspace: URL,
        paths: [String],
        structure: (fingerprint: String, topLevel: [String], manifests: [String]),
        technologies: [String],
        documents: [String]
    ) -> String {
        let stack = technologies.isEmpty ? "Unknown" : technologies.joined(separator: ", ")
        var lines = ["# Project Map", "", "## Workspace", "", "- Stack: \(stack)", "", "## Top-level", ""]
        lines.append(contentsOf: structure.topLevel.map { "- `\($0)`" })
        lines += ["", "## Important files", ""]
        lines.append(contentsOf: structure.manifests.map { "- `\($0)`" })
        let layout = ProjectMap.markdown(Array(paths.prefix(ProjectMap.maxFiles))) { ProjectMap.head(workspace.appendingPathComponent($0)) }
        if !layout.isEmpty { lines += ["", layout] }
        if !documents.isEmpty {
            lines += ["", "## Documents", "", "Each with its headings. Read the one that covers the request before searching the code."]
            lines.append(contentsOf: documents.map { "- \($0)" })
        }
        lines += ["", "## Guidance", "", "- Source files and task history are selected by the native host as needed.", "- The private project context is not exposed through workspace file tools."]
        return lines.joined(separator: "\n")
    }

    /// The project's own documents, each with its title and section headings, so a request
    /// is pointed at the document that covers it without a model having read any.
    /// ponytail: three levels down, 24 documents, read again only when the map is rebuilt -
    /// the root listing moved or a task changed a document. An edit made outside the app
    /// waits for one of those; add a stamp to the per-prompt check if that bites.
    nonisolated private static func documentOutlines(in workspace: URL, paths: [String]) -> [String] {
        var found: [(path: String, url: URL)] = []
        for path in paths.prefix(3_000) {
            let components = path.split(separator: "/")
            let name = String(components.last ?? "")
            guard components.count <= 3, name.lowercased().hasSuffix(".md"), !["AGENTS.md", "CLAUDE.md"].contains(name) else { continue }
            found.append((path, workspace.appendingPathComponent(path)))
        }
        return found
            .sorted { ($0.url.pathComponents.count, $0.path) < ($1.url.pathComponents.count, $1.path) }
            .prefix(24)
            .compactMap { entry -> String? in
                let url = entry.url
                guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 400_000,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                var fenced = false
                var headings: [String] = []
                for line in text.split(whereSeparator: \.isNewline) {
                    // A shell comment in a code block is not a heading.
                    if line.hasPrefix("```") {
                        fenced.toggle()
                    } else if !fenced, line.hasPrefix("# ") || line.hasPrefix("## ") {
                        headings.append(String(line.drop { $0 == "#" || $0 == " " }))
                    }
                }
                let path = "`\(entry.path)`"
                return headings.isEmpty ? path : "\(path) - \(sanitizeMapExcerpt(headings.prefix(8).joined(separator: "; "), limit: 160))"
            }
    }

    /// What the project is built with, read from its manifests rather than asked
    /// of the user. Monorepos keep them a level or two down (`mobile/android/`).
    /// ponytail: breadth-first, two levels, 200 directories; a deeper layout is
    /// missed until a task touches its manifest - raise the bounds if that bites.
    nonisolated static func detectTechnologies(in workspace: URL, paths: [String]) -> [String] {
        var found = Set<String>()
        for path in paths.prefix(3_000) {
            let components = path.split(separator: "/").map(String.init)
            guard components.count <= 3 else { continue }
            if components.dropLast().prefix(2).contains(where: { $0.lowercased().hasSuffix(".xcodeproj") }) {
                found.insert("Swift")
            }
            let url = workspace.appendingPathComponent(path)
            if isStackManifest(url.lastPathComponent) {
                found.formUnion(technologies(inManifest: url))
            }
        }
        return found.sorted()
    }

    nonisolated static func isStackManifest(_ name: String) -> Bool {
        ["pubspec.yaml", "Package.swift", "package.json", "wrangler.toml", "wrangler.json", "wrangler.jsonc",
         "Cargo.toml", "go.mod", "pyproject.toml", "requirements.txt", "build.gradle", "build.gradle.kts",
         "pom.xml", "composer.json", "Gemfile"].contains(name)
            || name.hasSuffix(".csproj") || name.hasSuffix(".sln")
    }

    private nonisolated static let packageFrameworks: [String: String] = [
        "react-native": "React Native", "expo": "Expo", "next": "Next.js", "react": "React", "vue": "Vue",
        "nuxt": "Nuxt", "svelte": "Svelte", "@angular/core": "Angular", "hono": "Hono", "express": "Express",
        "electron": "Electron", "tailwindcss": "Tailwind CSS",
    ]

    private nonisolated static func technologies(inManifest url: URL) -> [String] {
        let name = url.lastPathComponent
        func text() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        switch name {
        case "pubspec.yaml": return [text().contains("sdk: flutter") ? "Flutter" : "Dart"]
        case "Package.swift": return ["Swift"]
        case "package.json":
            let object = (try? Data(contentsOf: url))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let dependencies = ["dependencies", "devDependencies"]
                .flatMap { (object[$0] as? [String: Any] ?? [:]).keys }
            return [dependencies.contains("typescript") ? "TypeScript" : "JavaScript"]
                + dependencies.compactMap { packageFrameworks[$0] }
        case "wrangler.toml", "wrangler.json", "wrangler.jsonc": return ["Cloudflare Workers"]
        case "Cargo.toml": return ["Rust"]
        case "go.mod": return ["Go"]
        case "pyproject.toml", "requirements.txt": return ["Python"]
        case "build.gradle", "build.gradle.kts": return [text().contains("com.android") ? "Android" : "JVM (Gradle)"]
        case "pom.xml": return ["Java (Maven)"]
        case "composer.json": return ["PHP"]
        case "Gemfile": return ["Ruby"]
        default: return [".NET"]
        }
    }

    private nonisolated static func isManifest(_ name: String) -> Bool {
        ["Package.swift", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "pom.xml", "build.gradle", "Makefile", "README.md", "CONTRACT.md"].contains(name)
            || name.hasSuffix(".csproj") || name.hasSuffix(".sln")
    }

    private nonisolated static func binaryFileName(_ name: String) -> Bool {
        let extensions = Set(["app", "bin", "dmg", "exe", "dll", "dylib", "so", "zip", "gz", "7z", "png", "jpg", "jpeg", "gif", "webp", "pdf", "mp3", "mp4", "mov", "wav"])
        return extensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    nonisolated private static func sanitizeMapExcerpt(_ text: String, limit: Int) -> String {
        SecretRedaction.sanitize(text, limit: limit)
    }

    /// Reads the legacy event log for backward compatibility; current writes use facts.md.
    private func rebuildProjection() {
        state = Self.emptyState()
        events = []
        guard let root = memoryDirectory,
              let files = try? fileManager.contentsOfDirectory(at: root.appendingPathComponent("events"), includingPropertiesForKeys: nil) else { return }
        let candidates = files.filter { $0.pathExtension == "json" }.compactMap { url -> [String: Any]? in
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object
        }.sorted {
            let left = ($0["lamport"] as? Int ?? 0, $0["eventId"] as? String ?? "")
            let right = ($1["lamport"] as? Int ?? 0, $1["eventId"] as? String ?? "")
            return left.0 == right.0 ? left.1 < right.1 : left.0 < right.0
        }
        var validEventIDs = Set<String>()
        let presentEventIDs = Set(candidates.compactMap { $0["eventId"] as? String })
        for event in candidates where verifyEvent(event) {
            // A parent missing from the folder was moved to the user layer, which is
            // not a broken chain. A parent that is present but failed verification is.
            let parents = event["parents"] as? [String] ?? []
            guard parents.allSatisfy({ validEventIDs.contains($0) || !presentEventIDs.contains($0) }) else { continue }
            if let eventID = event["eventId"] as? String { validEventIDs.insert(eventID) }
            // Legacy membership events remain in the chain but never change project memory.
            guard isReadableProjectEvent(event) else { continue }
            events.append(event)
            apply(event)
        }
        // The revision is derived, never stored: a file every event rewrote would conflict
        // whenever two people commit memory in parallel.
        if let latest = events.last, let revision = latest["lamport"] as? Int {
            state["revision"] = revision
        }
        writeDecisionNotes()
        writeIndexNote()
    }

    private func verifyEvent(_ event: [String: Any]) -> Bool {
        guard event["schemaVersion"] as? Int == 1,
              event["projectId"] as? String == projectID else { return false }
        // Old events may still be signed. Their content remains readable, but signatures no
        // longer grant repository access or define project ownership.
        guard let signature = (event["signature"] as? [String: Any])?["value"] as? String else { return true }
        guard let actor = event["actor"] as? [String: Any],
              let publicKey = actor["publicKey"] as? String,
              let keyData = Data(base64Encoded: publicKey),
              let key = try? P256.Signing.PublicKey(rawRepresentation: keyData),
              let data = try? JSONSerialization.data(withJSONObject: eventWithoutSignature(event), options: [.sortedKeys]),
              let signatureData = Data(base64Encoded: signature),
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
              key.isValidSignature(ecdsa, for: data) else { return false }
        return true
    }

    /// Repository access is enforced by Git. Legacy membership events are ignored.
    private func isReadableProjectEvent(_ event: [String: Any]) -> Bool {
        let type = event["type"] as? String ?? ""
        guard event["scope"] as? String == "project" else { return false }
        return !type.hasPrefix("member.") && type != "workspace.initialized"
    }

    private func apply(_ event: [String: Any]) {
        guard let type = event["type"] as? String,
              let payload = event["payload"] as? [String: Any] else { return }
        switch type {
        case "workspace.initialized", "member.accepted", "member.invited", "member.revoked", "member.updated":
            break
        case "project.default.set":
            var defaults = state["projectDefaults"] as? [String: Any] ?? [:]
            // An entry set without a value is one the user took back.
            if let key = payload["key"] as? String { defaults[key] = payload["value"] as? String }
            state["projectDefaults"] = defaults
        case "decision.proposed":
            var proposals = state["pendingProposals"] as? [[String: Any]] ?? []
            proposals.append(event)
            state["pendingProposals"] = proposals
        case "decision.accepted":
            var accepted = state["acceptedDecisions"] as? [[String: Any]] ?? []
            let key = decisionKey(event)
            if let index = accepted.firstIndex(where: { decisionKey($0) == key }) {
                let old = accepted[index]
                guard eventWins(event, over: old) else {
                    var supersededValues = state["supersededValues"] as? [[String: Any]] ?? []
                    supersededValues.append(["eventId": event["eventId"] as Any, "supersededBy": old["eventId"] as Any, "reason": "authority"])
                    state["supersededValues"] = supersededValues
                    return
                }
                accepted[index] = event
                var supersededValues = state["supersededValues"] as? [[String: Any]] ?? []
                supersededValues.append(["eventId": old["eventId"] as Any, "supersededBy": event["eventId"] as Any, "reason": "authority"])
                state["supersededValues"] = supersededValues
            } else {
                accepted.append(event)
            }
            let superseded = Set(event["supersedes"] as? [String] ?? [])
            state["acceptedDecisions"] = accepted.filter { !superseded.contains($0["eventId"] as? String ?? "") }
            state["pendingProposals"] = (state["pendingProposals"] as? [[String: Any]] ?? []).filter { $0["eventId"] as? String != payload["eventId"] as? String }
        case "decision.rejected":
            state["pendingProposals"] = (state["pendingProposals"] as? [[String: Any]] ?? []).filter { $0["eventId"] as? String != payload["proposalEventId"] as? String }
        case "map.updated":
            state["lastMapRevision"] = payload["revision"] as? Int ?? (state["lastMapRevision"] as? Int ?? 0)
        default: break
        }
    }

    /// Used only while reading old repository events; new facts are stored in facts.md.
    static let sharedEventScopes: Set<String> = ["project"]

    /// The person's own activity: tasks, tool calls, file changes and chat lifecycle.
    /// Kept beside their other records on this Mac, never in the repository.
    func recordActivity(type: String, payload: [String: Any]) {
        guard let url = userMemoryDirectory?.appendingPathComponent("activity.jsonl") else { return }
        try? appendJSONLine([
            "schemaVersion": 1,
            "type": type,
            "createdAt": isoNow(),
            "projectId": projectID ?? "",
            "payload": payload,
        ], to: url)
    }

    /// Moves the person's own activity and preferences that earlier builds wrote into the
    /// repository into the user layer. An event moves only when its signature verifies, this
    /// device signed it, and it names this person. Anything else stays in the folder untouched:
    /// a teammate's record is theirs, and an unsigned file cannot be attributed. Loose repository
    /// files (tasks, chats, feedback, lessons, rules) are no longer imported; the copies on this
    /// Mac are the only ones read. Each moved copy lands before its repository file is removed.
    /// Git history still holds the old copies. A link inside the repository is removed as a link
    /// and never followed; a linked `.mem` is not migrated at all, because it names some other memory store.
    func moveUserContentOutOfRepository() {
        guard let root = memoryDirectory, !isSymbolicLink(root), let userRoot = userMemoryDirectory, let identity, let projectID else { return }
        let activityURL = userRoot.appendingPathComponent("activity.jsonl")
        let eventsURL = root.appendingPathComponent("events", isDirectory: true)
        // A linked events folder is removed as a link; the files it names stay where they are.
        let eventFiles: [URL] = discardSymbolicLink(eventsURL) ? [] : ((try? fileManager.contentsOfDirectory(at: eventsURL, includingPropertiesForKeys: nil)) ?? [])
        // Ids already in the activity log, matched as ids. A text search of the log also finds an id
        // in another event's `parents`, and that parent was then deleted without ever being written.
        var loggedIDs = Set(((try? String(contentsOf: activityURL, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .compactMap { ((try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any])?["eventId"] as? String })
        for url in eventFiles where url.pathExtension == "json" {
            if discardSymbolicLink(url) { continue }
            guard let data = try? Data(contentsOf: url),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if (event["type"] as? String ?? "").hasPrefix("member.") { continue }
            if Self.sharedEventScopes.contains(event["scope"] as? String ?? "") { continue }
            // Only this device's own signed events move. An unsigned or foreign event stays where it is.
            guard verifyEvent(event),
                  let actor = event["actor"] as? [String: Any],
                  actor["publicKey"] as? String == identity.publicKey,
                  actor["personId"] as? String == identity.personID else { continue }
            let eventID = event["eventId"] as? String ?? ""
            do {
                if !loggedIDs.contains(eventID) { try appendJSONLine(event, to: activityURL) }
            } catch { continue }
            loggedIDs.insert(eventID)
            if event["type"] as? String == "preference.set",
               let payload = event["payload"] as? [String: Any],
               let rawKey = payload["key"] as? String,
               let rawValue = payload["value"] as? String {
                let key = sanitize(rawKey, limit: 60)
                let value = sanitize(rawValue, limit: 240)
                if key == "language" {
                    try? profile.setPreference(key: key, value: value)
                } else if !key.isEmpty {
                    try? profile.setProjectPreference(projectID: projectID, key: key, value: value)
                }
            }
            try? fileManager.removeItem(at: url)
        }
        // Derived copies with nothing left in the repository to derive them from.
        try? fileManager.removeItem(at: root.appendingPathComponent("preferences.md"))
    }

}
