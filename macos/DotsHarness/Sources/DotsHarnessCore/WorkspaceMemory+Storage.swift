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
        try? ensureIdentity()
        if let stateData = try? Data(contentsOf: root.appendingPathComponent("state.json")),
           let cachedState = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any],
           cachedState["schemaVersion"] as? Int == 1 {
            state = cachedState
        } else {
            rebuildProjection()
        }
        mapText = (try? String(contentsOf: root.appendingPathComponent("map.md"), encoding: .utf8)) ?? ""
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
            "workspaceRoot": workspaceURL?.standardizedFileURL.path ?? "",
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

    func updateMapIfNeeded() throws {
        guard let workspaceURL, let root = memoryDirectory else { return }
        let structure = mapStructure(workspaceURL)
        let fingerprint = digest(Data(structure.fingerprint.utf8))
        let indexURL = root.appendingPathComponent("index.json")
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           index["fingerprint"] as? String == fingerprint {
            mapText = (try? String(contentsOf: root.appendingPathComponent("map.md"), encoding: .utf8)) ?? mapText
            return
        }
        mapText = structure.markdown
        try writeJSON([
            "schemaVersion": 1,
            "fingerprint": fingerprint,
            "updatedAt": isoNow(),
            "topLevel": structure.topLevel,
            "manifests": structure.manifests,
        ], to: indexURL)
        let mapFront = frontmatter([
            "id": "map",
            "type": "map",
            "title": "Project map",
            "updated": isoNow(),
        ], tags: ["map"], links: ["index"])
        try (mapFront + "\n" + structure.markdown + "\n\nBack to [[index]]\n")
            .write(to: root.appendingPathComponent("map.md"), atomically: true, encoding: .utf8)
        let mapRevision = (state["lastMapRevision"] as? Int ?? 0) + 1
        _ = try? writeEvent(type: "map.updated", scope: "project", payload: ["revision": mapRevision, "fingerprint": fingerprint])
        writeIndexNote()
    }

    private func mapStructure(_ workspace: URL) -> (fingerprint: String, markdown: String, topLevel: [String], manifests: [String]) {
        let ignored: Set<String> = [".git", ".mem", "node_modules", "vendor", "build", "dist", ".build", "bin", "obj", "target"]
        let urls = (try? fileManager.contentsOfDirectory(at: workspace, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        var topLevel: [String] = []
        var manifestPaths: [String] = []
        var fingerprint: [String] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            guard !ignored.contains(name) else { continue }
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
        let language = manifestPaths.contains("Package.swift") ? "Swift" : "Unknown"
        var lines = ["# Project Map", "", "## Workspace", "", "- Root: `\(workspace.path)`", "- Primary language: \(language)", "", "## Top-level", ""]
        lines.append(contentsOf: topLevel.map { "- `\($0)`" })
        lines += ["", "## Important files", ""]
        lines.append(contentsOf: manifestPaths.sorted().map { "- `\($0)`" })
        lines += ["", "## Guidance", "", "- Source files and task history are selected by the native host as needed.", "- The private project context is not exposed through workspace file tools."]
        return (fingerprint.joined(separator: "\n"), lines.joined(separator: "\n"), topLevel, manifestPaths.sorted())
    }

    private func isManifest(_ name: String) -> Bool {
        ["Package.swift", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "pom.xml", "build.gradle", "Makefile", "README.md", "CONTRACT.md"].contains(name)
            || name.hasSuffix(".csproj") || name.hasSuffix(".sln")
    }

    private func binaryFileName(_ name: String) -> Bool {
        let extensions = Set(["app", "bin", "dmg", "exe", "dll", "dylib", "so", "zip", "gz", "7z", "png", "jpg", "jpeg", "gif", "webp", "pdf", "mp3", "mp4", "mov", "wav"])
        return extensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

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
            if let key = payload["key"] as? String { defaults[key] = payload["value"] ?? NSNull() }
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
        rebuildProjection()
        return eventID
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
