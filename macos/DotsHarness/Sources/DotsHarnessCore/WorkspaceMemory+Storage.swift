// Copyright (c) 2026 DOTS
// Event store: identity, projection, signing and replay.

import CryptoKit
import Foundation
import PluginRuntime

extension WorkspaceMemory {
    func loadExisting() {
        guard let root = memoryDirectory else { return }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let loaded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              loaded["schemaVersion"] as? Int == 1,
              loaded["projectId"] is String,
              loaded["rootAuthority"] is [String: Any] else { return }
        manifest = loaded
        // Written by earlier versions and never read: the vault travels with its
        // folder, and an absolute path differs on every machine that clones it.
        manifest?.removeValue(forKey: "workspaceRoot")
        try? ensureIdentity()
        if let stateData = try? Data(contentsOf: root.appendingPathComponent("state.json")),
           let cachedState = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any],
           cachedState["schemaVersion"] as? Int == 1 {
            state = cachedState
        } else {
            rebuildProjection()
        }
        mapText = (try? String(contentsOf: root.appendingPathComponent("map.md"), encoding: .utf8)) ?? ""
        syncFacts()
    }

    func initializeWorkspace() throws {
        guard let root = memoryDirectory, let identity else { throw WorkspaceMemoryError.noWorkspace }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for folder in ["events", "tasks", "decisions", "conversations"] {
            try fileManager.createDirectory(at: root.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
        }
        let projectID = UUID().uuidString
        manifest = [
            "schemaVersion": 1,
            "projectId": projectID,
            "createdAt": isoNow(),
            "rootAuthority": [
                "personId": identity.personID,
                "deviceId": identity.deviceID,
                "publicKey": identity.publicKey,
                "keyId": identity.keyID,
                "algorithm": "P-256-SHA256",
            ],
            "revision": 0,
        ]
        try writeJSON(manifest!, to: root.appendingPathComponent("manifest.json"))
        _ = try writeEvent(
            type: "workspace.initialized",
            scope: "project",
            payload: [
                "projectId": projectID,
                "personId": identity.personID,
                "deviceId": identity.deviceID,
                "displayName": identity.displayName,
                "role": MemoryRole.owner.rawValue,
                "score": 100,
                "publicKey": identity.publicKey,
            ]
        )
    }

    func ensureIdentity() throws {
        if identity != nil, privateKey != nil { return }
        paths.ensure(fileManager: fileManager)
        let identityURL = paths.root.appendingPathComponent("memory-identity.json")
        if let data = try? Data(contentsOf: identityURL),
           let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data),
           let keyData = Data(base64Encoded: stored.privateKey),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: keyData) {
            identity = stored
            privateKey = key
            return
        }
        let key = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let deviceID = digest(key.publicKey.rawRepresentation)
        let stored = StoredIdentity(
            personID: UUID().uuidString,
            displayName: NSUserName().isEmpty ? "User" : NSUserName(),
            privateKey: key.rawRepresentation.base64EncodedString(),
            publicKey: publicKey,
            deviceID: deviceID,
            keyID: "device-\(String(deviceID.prefix(16)))"
        )
        let data = try JSONEncoder().encode(stored)
        try fileManager.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try data.write(to: identityURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityURL.path)
        identity = stored
        privateKey = key
    }

    /// The root listing is compared on every prompt. The stack scan below it reads
    /// manifests two levels down, so it runs only when that listing changed or, with
    /// `deep`, when a finished task touched a manifest.
    func updateMapIfNeeded(deep: Bool = false) throws {
        guard let workspaceURL, let root = memoryDirectory else { return }
        let structure = mapStructure(workspaceURL)
        let indexURL = root.appendingPathComponent("index.json")
        let index = (try? Data(contentsOf: indexURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let known = index["technologies"] as? [String]
        // A map written by an older build is rebuilt even when the project has
        // not moved: what the map says changed, not what it describes.
        let rootUnchanged = index["schemaVersion"] as? Int == Self.mapSchemaVersion
            && index["rootFingerprint"] as? String == structure.fingerprint
        if rootUnchanged, let known, !deep {
            stack = known
            // The note's frontmatter carries an `updated` stamp and wiki links. The
            // prompt gets the same body a fresh build produces, so a reload does not
            // read as a changed project.
            if let note = try? String(contentsOf: root.appendingPathComponent("map.md"), encoding: .utf8),
               let start = note.range(of: "# Project Map") {
                mapText = note[start.lowerBound...].components(separatedBy: "\n\nBack to [[index]]")[0]
            }
            return
        }
        let technologies = Self.detectTechnologies(in: workspaceURL, fileManager: fileManager)
        stack = technologies
        if let projectID { profile.recordTechnologies(technologies, projectID: projectID) }
        if rootUnchanged, known == technologies { return }
        let markdown = mapMarkdown(workspaceURL, structure: structure, technologies: technologies)
        let fingerprint = digest(Data((structure.fingerprint + "\n" + technologies.joined(separator: ",")).utf8))
        mapText = markdown
        try writeJSON([
            "schemaVersion": Self.mapSchemaVersion,
            "fingerprint": fingerprint,
            "rootFingerprint": structure.fingerprint,
            "updatedAt": isoNow(),
            "topLevel": structure.topLevel,
            "manifests": structure.manifests,
            "technologies": technologies,
        ], to: indexURL)
        let mapFront = frontmatter([
            "id": "map",
            "type": "map",
            "title": "Project map",
            "updated": isoNow(),
        ], tags: ["map"], links: ["index"])
        try (mapFront + "\n" + markdown + "\n\nBack to [[index]]\n")
            .write(to: root.appendingPathComponent("map.md"), atomically: true, encoding: .utf8)
        let mapRevision = (state["lastMapRevision"] as? Int ?? 0) + 1
        _ = try? writeEvent(type: "map.updated", scope: "project", payload: ["revision": mapRevision, "fingerprint": fingerprint])
        writeIndexNote()
    }

    /// 3: the map no longer names the workspace's absolute path.
    static let mapSchemaVersion = 3

    private static let ignoredDirectories: Set<String> = [".git", ".mem", "node_modules", "vendor", "build", "dist", ".build", "bin", "obj", "target", "Pods"]

    private func mapStructure(_ workspace: URL) -> (fingerprint: String, topLevel: [String], manifests: [String]) {
        let urls = (try? fileManager.contentsOfDirectory(at: workspace, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        var topLevel: [String] = []
        var manifestPaths: [String] = []
        var fingerprint: [String] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            guard !Self.ignoredDirectories.contains(name) else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let directory = values?.isDirectory == true
            let large = (values?.fileSize ?? 0) > 1_000_000
            if !directory && (large || binaryFileName(name)) {
                fingerprint.append("\(name):ignored")
                continue
            }
            topLevel.append(directory ? "\(name)/" : name)
            fingerprint.append("\(name):\(directory ? "d" : "f")")
            if isManifest(name) { manifestPaths.append(name) }
        }
        return (fingerprint.joined(separator: "\n"), topLevel, manifestPaths.sorted())
    }

    private func mapMarkdown(
        _ workspace: URL,
        structure: (fingerprint: String, topLevel: [String], manifests: [String]),
        technologies: [String]
    ) -> String {
        let stack = technologies.isEmpty ? "Unknown" : technologies.joined(separator: ", ")
        var lines = ["# Project Map", "", "## Workspace", "", "- Stack: \(stack)", "", "## Top-level", ""]
        lines.append(contentsOf: structure.topLevel.map { "- `\($0)`" })
        lines += ["", "## Important files", ""]
        lines.append(contentsOf: structure.manifests.map { "- `\($0)`" })
        lines += ["", "## Guidance", "", "- Source files and task history are selected by the native host as needed.", "- The private project context is not exposed through workspace file tools."]
        return lines.joined(separator: "\n")
    }

    /// What the project is built with, read from its manifests rather than asked
    /// of the user. Monorepos keep them a level or two down (`mobile/android/`).
    /// ponytail: breadth-first, two levels, 200 directories; a deeper layout is
    /// missed until a task touches its manifest - raise the bounds if that bites.
    static func detectTechnologies(in workspace: URL, fileManager: FileManager = .default) -> [String] {
        var found = Set<String>()
        var level = [workspace]
        var listed = 0
        for depth in 0...2 {
            var next: [URL] = []
            for directory in level where listed < 200 {
                listed += 1
                let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                for url in urls {
                    let name = url.lastPathComponent
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        if name.hasSuffix(".xcodeproj") {
                            found.insert("Swift")
                        } else if depth < 2, !ignoredDirectories.contains(name) {
                            next.append(url)
                        }
                    } else if isStackManifest(name) {
                        found.formUnion(technologies(inManifest: url))
                    }
                }
            }
            level = next
        }
        return found.sorted()
    }

    static func isStackManifest(_ name: String) -> Bool {
        ["pubspec.yaml", "Package.swift", "package.json", "wrangler.toml", "wrangler.json", "wrangler.jsonc",
         "Cargo.toml", "go.mod", "pyproject.toml", "requirements.txt", "build.gradle", "build.gradle.kts",
         "pom.xml", "composer.json", "Gemfile"].contains(name)
            || name.hasSuffix(".csproj") || name.hasSuffix(".sln")
    }

    private static let packageFrameworks: [String: String] = [
        "react-native": "React Native", "expo": "Expo", "next": "Next.js", "react": "React", "vue": "Vue",
        "nuxt": "Nuxt", "svelte": "Svelte", "@angular/core": "Angular", "hono": "Hono", "express": "Express",
        "electron": "Electron", "tailwindcss": "Tailwind CSS",
    ]

    private static func technologies(inManifest url: URL) -> [String] {
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

    private func isManifest(_ name: String) -> Bool {
        ["Package.swift", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "pom.xml", "build.gradle", "Makefile", "README.md", "CONTRACT.md"].contains(name)
            || name.hasSuffix(".csproj") || name.hasSuffix(".sln")
    }

    private func binaryFileName(_ name: String) -> Bool {
        let extensions = Set(["app", "bin", "dmg", "exe", "dll", "dylib", "so", "zip", "gz", "7z", "png", "jpg", "jpeg", "gif", "webp", "pdf", "mp3", "mp4", "mov", "wav"])
        return extensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    /// Cold start / repair path: replays the whole event log, verifying every
    /// signature. Only `loadExisting()` reaches it now — see `commit(_:)`.
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
        for event in candidates where verifyEvent(event) {
            let parents = event["parents"] as? [String] ?? []
            guard parents.allSatisfy({ validEventIDs.contains($0) }) else { continue }
            events.append(event)
            if let eventID = event["eventId"] as? String { validEventIDs.insert(eventID) }
            apply(event)
        }
        if let latest = events.last, let revision = latest["lamport"] as? Int {
            state["revision"] = revision
            if var manifest {
                manifest["revision"] = revision
                self.manifest = manifest
                if let root = memoryDirectory { try? writeJSON(manifest, to: root.appendingPathComponent("manifest.json")) }
            }
        }
        if let root = memoryDirectory { try? writeJSON(state, to: root.appendingPathComponent("state.json")) }
        writeDecisionNotes()
        writeConversationNotes()
        writeIndexNote()
        writePreferencesNote()
    }

    private func verifyEvent(_ event: [String: Any]) -> Bool {
        guard event["schemaVersion"] as? Int == 1,
              event["projectId"] as? String == projectID,
              let actor = event["actor"] as? [String: Any],
              let publicKey = actor["publicKey"] as? String,
              let signature = (event["signature"] as? [String: Any])?["value"] as? String,
              let keyData = Data(base64Encoded: publicKey),
              let key = try? P256.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        let base = invitationWithoutSignature(event)
        guard let data = try? JSONSerialization.data(withJSONObject: base, options: [.sortedKeys]),
              let signatureData = Data(base64Encoded: signature),
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
              key.isValidSignature(ecdsa, for: data) else { return false }
        guard let deviceID = actor["deviceId"] as? String, digest(keyData) == deviceID else { return false }
        if deviceID == rootDeviceID { return publicKey == rootPublicKeyString }
        if event["type"] as? String == "member.accepted" {
            guard let payload = event["payload"] as? [String: Any],
                  payload["publicKey"] as? String == publicKey,
                  payload["deviceId"] as? String == deviceID else { return false }
            return events.contains { existing in
                existing["type"] as? String == "member.invited"
                    && (existing["payload"] as? [String: Any])?["publicKey"] as? String == publicKey
                    && (existing["payload"] as? [String: Any])?["personId"] as? String == payload["personId"] as? String
            }
        }
        return member(deviceID: deviceID)?["revoked"] as? Bool != true
    }

    private func apply(_ event: [String: Any]) {
        guard let type = event["type"] as? String,
              let payload = event["payload"] as? [String: Any] else { return }
        switch type {
        case "workspace.initialized", "member.accepted":
            upsertMember(payload)
            if type == "member.accepted" {
                let personID = payload["personId"] as? String
                state["pendingProposals"] = (state["pendingProposals"] as? [[String: Any]] ?? []).filter {
                    let invited = $0["payload"] as? [String: Any]
                    return invited?["personId"] as? String != personID
                }
            }
        case "member.invited":
            break
        case "member.revoked":
            if let deviceID = payload["deviceId"] as? String { setMember(deviceID: deviceID, key: "revoked", value: true) }
        case "member.updated":
            if let deviceID = payload["deviceId"] as? String {
                if let role = payload["role"] { setMember(deviceID: deviceID, key: "role", value: role) }
                if let score = payload["score"] { setMember(deviceID: deviceID, key: "score", value: score) }
                if let displayName = payload["displayName"] { setMember(deviceID: deviceID, key: "displayName", value: displayName) }
            }
        case "preference.set":
            guard let personID = payload["personId"] as? String, let key = payload["key"] as? String else { return }
            var all = state["activePreferences"] as? [String: Any] ?? [:]
            var preferences = all[personID] as? [String: Any] ?? [:]
            if let old = preferences[key] {
                var superseded = state["supersededValues"] as? [[String: Any]] ?? []
                superseded.append(["key": key, "value": old, "personId": personID, "eventId": event["eventId"] as Any])
                state["supersededValues"] = superseded
            }
            preferences[key] = payload["value"] ?? NSNull()
            all[personID] = preferences
            state["activePreferences"] = all
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
        case "conversation.archived", "conversation.restored", "conversation.deleted":
            guard let conversationID = payload["conversationId"] as? String else { return }
            var conversations = state["conversationStates"] as? [String: Any] ?? [:]
            conversations[conversationID] = [
                "conversationId": conversationID,
                "title": payload["title"] as? String ?? conversationID,
                "state": String(type.dropFirst("conversation.".count)),
                "eventId": event["eventId"] as? String ?? "",
                "updatedAt": event["createdAt"] as? String ?? "",
                "revision": event["lamport"] as? Int ?? 0,
            ]
            state["conversationStates"] = conversations
        default: break
        }
    }

    @discardableResult
    func writeEvent(
        type: String,
        scope: String,
        supersedes: [String] = [],
        payload: [String: Any]
    ) throws -> String {
        guard let root = memoryDirectory, let identity, let privateKey,
              let projectID else { throw WorkspaceMemoryError.noWorkspace }
        guard canWrite(for: type) else { throw WorkspaceMemoryError.unauthorized }
        let eventID = UUID().uuidString
        let lamport = max(revision, events.map { $0["lamport"] as? Int ?? 0 }.max() ?? 0) + 1
        let parents = events.last.flatMap { $0["eventId"] as? String }.map { [$0] } ?? []
        let object: [String: Any] = [
            "schemaVersion": 1,
            "eventId": eventID,
            "type": type,
            "scope": scope,
            "projectId": projectID,
            "actor": [
                "personId": identity.personID,
                "deviceId": identity.deviceID,
                "keyId": identity.keyID,
                "publicKey": identity.publicKey,
            ],
            "lamport": lamport,
            "createdAt": isoNow(),
            "parents": parents,
            "supersedes": supersedes,
            "payload": payload,
        ]
        let signed = try signedObject(object, key: privateKey, actor: identity)
        try fileManager.createDirectory(at: root.appendingPathComponent("events"), withIntermediateDirectories: true)
        try writeJSON(signed, to: root.appendingPathComponent("events").appendingPathComponent("\(eventID).json"))
        commit(signed)
        return eventID
    }

    /// Folds one locally-authored event into the projection.
    ///
    /// This used to call `rebuildProjection()`, which re-read and re-verified
    /// every event file and rewrote every decision and conversation note plus an
    /// index that re-parses all of them — so a single append cost O(history)
    /// file operations, on the main actor, several times per run. Full replay is
    /// now reserved for load, when `state.json` is missing or unreadable.
    private func commit(_ event: [String: Any]) {
        events.append(event)
        apply(event)
        guard let revision = event["lamport"] as? Int else { return }
        state["revision"] = revision
        if var manifest {
            manifest["revision"] = revision
            self.manifest = manifest
        }
        guard let root = memoryDirectory else { return }
        if let manifest { try? writeJSON(manifest, to: root.appendingPathComponent("manifest.json")) }
        try? writeJSON(state, to: root.appendingPathComponent("state.json"))
        refreshDerivedNotes(for: event)
    }

    /// Writes only the notes the event type actually feeds.
    private func refreshDerivedNotes(for event: [String: Any]) {
        switch event["type"] as? String {
        case "decision.accepted":
            writeDecisionNote(event)
            writeIndexNote()
        case "conversation.archived", "conversation.restored", "conversation.deleted":
            writeConversationNote(for: event)
            writeIndexNote()
        case "preference.set":
            writePreferencesNote()
        default:
            break
        }
    }

    func signedObject(_ object: [String: Any], key: P256.Signing.PrivateKey?, actor: StoredIdentity) throws -> [String: Any] {
        guard let key else { throw WorkspaceMemoryError.unauthorized }
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let signature = try key.signature(for: canonical).rawRepresentation.base64EncodedString()
        var result = object
        result["signature"] = ["algorithm": "P-256-SHA256", "value": signature]
        return result
    }
}
