// Copyright (c) 2026 DOTS
// Private, workspace-scoped memory owned by the native macOS host.

import CryptoKit
import Foundation
import PluginRuntime

public enum MemoryRole: String, Codable, Sendable, CaseIterable {
    case owner
    case approver
    case contributor
    case observer

    public var rank: Int {
        switch self {
        case .owner: return 3
        case .approver: return 2
        case .contributor: return 1
        case .observer: return 0
        }
    }

    public var title: String {
        AppCopy.text("access.role.\(rawValue)")
    }
}

public struct WorkspaceAccessStatus: Sendable, Equatable {
    public var personID: String
    public var deviceID: String
    public var role: MemoryRole?
    public var score: Int
    public var memberCount: Int
    public var pendingDecisionCount: Int
    public var revision: Int
    public var memoryReady: Bool

    public init(
        personID: String = "",
        deviceID: String = "",
        role: MemoryRole? = nil,
        score: Int = 0,
        memberCount: Int = 0,
        pendingDecisionCount: Int = 0,
        revision: Int = 0,
        memoryReady: Bool = false
    ) {
        self.personID = personID
        self.deviceID = deviceID
        self.role = role
        self.score = score
        self.memberCount = memberCount
        self.pendingDecisionCount = pendingDecisionCount
        self.revision = revision
        self.memoryReady = memoryReady
    }
}

public struct MemorySnapshot: Sendable, Equatable {
    public var text: String
    public var revision: Int

    public init(text: String, revision: Int) {
        self.text = text
        self.revision = revision
    }
}

public enum WorkspaceMemoryError: Error, LocalizedError, Sendable {
    case noWorkspace
    case unauthorized
    case invalidManifest
    case invalidInvitation
    case wrongDevice

    public var errorDescription: String? {
        switch self {
        case .noWorkspace: return AppCopy.text("workspaceMemory.noWorkspace")
        case .unauthorized: return AppCopy.text("workspaceMemory.unauthorized")
        case .invalidManifest: return AppCopy.text("workspaceMemory.invalidManifest")
        case .invalidInvitation: return AppCopy.text("workspaceMemory.invalidInvitation")
        case .wrongDevice: return AppCopy.text("workspaceMemory.wrongDevice")
        }
    }
}

@MainActor
public final class WorkspaceMemory {
    private struct StoredIdentity: Codable {
        var personID: String
        var displayName: String
        var privateKey: String
        var publicKey: String
        var deviceID: String
        var keyID: String
    }

    private struct TaskRecord {
        var runID: String
        var promptSummary: String
        var promptHash: String
        var startedAt: String
        var provider: String
        var model: String
        var changedFiles: [[String: Any]] = []
        var tools: [String] = []
    }

    private let paths: SupportPaths
    private let fileManager: FileManager
    private var workspaceURL: URL?
    private var identity: StoredIdentity?
    private var privateKey: P256.Signing.PrivateKey?
    private var manifest: [String: Any]?
    private var state: [String: Any] = [:]
    private var events: [[String: Any]] = []
    private var tasks: [String: TaskRecord] = [:]
    private var mapText = ""

    public init(paths: SupportPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        self.state = Self.emptyState()
    }

    public var memoryDirectory: URL? { workspaceURL?.appendingPathComponent(".mem", isDirectory: true) }
    public var projectID: String? { manifest?["projectId"] as? String }
    public var revision: Int { state["revision"] as? Int ?? 0 }
    public var actorPublicKey: String? { identity?.publicKey }
    public var actor: (personID: String, deviceID: String, displayName: String)? {
        guard let identity else { return nil }
        return (identity.personID, identity.deviceID, identity.displayName)
    }

    public func setWorkspace(_ url: URL?) {
        workspaceURL = url?.standardizedFileURL
        identity = nil
        privateKey = nil
        manifest = nil
        state = Self.emptyState()
        events = []
        tasks = [:]
        mapText = ""
        guard let root = memoryDirectory,
              fileManager.fileExists(atPath: root.path) else { return }
        loadExisting()
    }

    public func reload() {
        guard memoryDirectory != nil else { return }
        loadExisting()
    }

    /// Creates memory only when the first prompt is accepted. Selecting a
    /// workspace or opening a blank chat never calls this method.
    public func prepareForPrompt(
        prompt: String,
        runID: UUID,
        provider: String,
        model: String
    ) {
        guard workspaceURL != nil else { return }
        do {
            try ensureIdentity()
            if manifest == nil {
                try initializeWorkspace()
            } else {
                loadExisting()
            }
            try updateMapIfNeeded()
            beginTask(runID: runID, prompt: prompt, provider: provider, model: model)
        } catch {
            // Memory is an audit layer. A storage failure must not prevent the
            // native agent from answering the current user request.
        }
    }

    public func snapshot(for prompt: String) -> MemorySnapshot {
        guard manifest != nil else { return MemorySnapshot(text: "", revision: 0) }
        let decisions = markdownList(state["acceptedDecisions"] as? [[String: Any]] ?? [])
        let proposals = markdownList(state["pendingProposals"] as? [[String: Any]] ?? [], prefix: "Proposal")
        let preferences = preferencesText()
        let defaults = markdownDictionary(state["projectDefaults"] as? [String: Any] ?? [:])
        let tasksText = relevantTasks(for: prompt)
        let body = [
            "Private project context. It is verified by the native host.",
            "Current user instructions are authoritative over this context.",
            "Revision: \(revision)",
            "\n## Project map\n\(mapText)",
            "\n## Accepted project decisions\n\(decisions.isEmpty ? "None" : decisions)",
            "\n## Current actor preferences\n\(preferences.isEmpty ? "None" : preferences)",
            "\n## Project defaults\n\(defaults.isEmpty ? "None" : defaults)",
            "\n## Relevant task history\n\(tasksText.isEmpty ? "None" : tasksText)",
            proposals.isEmpty ? "" : "\n## Unauthoritative proposals\n\(proposals)",
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        return MemorySnapshot(text: trimSnapshot(body), revision: revision)
    }

    public func accessStatus() -> WorkspaceAccessStatus {
        let member = currentMember()
        return WorkspaceAccessStatus(
            personID: identity?.personID ?? "",
            deviceID: identity?.deviceID ?? "",
            role: (member?["role"] as? String).flatMap(MemoryRole.init(rawValue:)),
            score: member?["score"] as? Int ?? 0,
            memberCount: (state["members"] as? [[String: Any]] ?? []).count,
            pendingDecisionCount: (state["pendingProposals"] as? [[String: Any]] ?? []).count,
            revision: revision,
            memoryReady: manifest != nil
        )
    }

    public func memberSummaries() -> [[String: String]] {
        (state["members"] as? [[String: Any]] ?? []).compactMap { member in
            guard let personID = member["personId"] as? String,
                  let deviceID = member["deviceId"] as? String else { return nil }
            return [
                "personId": personID,
                "deviceId": deviceID,
                "displayName": member["displayName"] as? String ?? "",
                "role": member["role"] as? String ?? MemoryRole.observer.rawValue,
                "score": String(member["score"] as? Int ?? 0),
                "revoked": String(member["revoked"] as? Bool ?? false),
            ]
        }
    }

    public func pendingDecisions() -> [[String: Any]] {
        state["pendingProposals"] as? [[String: Any]] ?? []
    }

    public func createInvite(
        personID: String = UUID().uuidString,
        displayName: String,
        role: MemoryRole = .contributor,
        score: Int = 50,
        publicKey: String
    ) throws -> String {
        guard canWrite(role: .owner), let identity else { throw WorkspaceMemoryError.unauthorized }
        var payload: [String: Any] = [
            "schemaVersion": 1,
            "projectId": projectID ?? "",
            "personId": personID,
            "displayName": sanitize(displayName, limit: 80),
            "role": role.rawValue,
            "score": max(0, min(100, score)),
            "publicKey": publicKey,
            "invitedBy": identity.personID,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let eventID = try writeEvent(type: "member.invited", scope: "device", payload: payload)
        payload["eventId"] = eventID
        payload["actor"] = [
            "personId": identity.personID,
            "deviceId": identity.deviceID,
            "keyId": identity.keyID,
            "publicKey": identity.publicKey,
        ]
        let signed = try signedObject(payload, key: privateKey, actor: identity)
        guard let data = try? JSONSerialization.data(withJSONObject: signed, options: [.sortedKeys]) else {
            throw WorkspaceMemoryError.invalidInvitation
        }
        return data.base64EncodedString()
    }

    public func acceptInvite(_ token: String) throws {
        try ensureIdentity()
        guard let data = Data(base64Encoded: token),
              let invitation = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projectID = invitation["projectId"] as? String,
              projectID == self.projectID,
              let publicKey = invitation["publicKey"] as? String,
              publicKey == identity?.publicKey else {
            throw WorkspaceMemoryError.invalidInvitation
        }
        guard let signed = invitation["signature"] as? [String: Any],
              let signature = signed["value"] as? String,
              let rootKey = rootPublicKey,
              verify(signature: signature, object: invitationWithoutSignature(invitation), publicKey: rootKey) else {
            throw WorkspaceMemoryError.invalidInvitation
        }
        _ = try writeEvent(
            type: "member.accepted",
            scope: "device",
            payload: [
                "personId": invitation["personId"] as Any,
                "deviceId": identity?.deviceID as Any,
                "displayName": invitation["displayName"] as Any,
                "role": invitation["role"] as Any,
                "score": invitation["score"] as Any,
                "publicKey": publicKey,
            ]
        )
    }

    public func proposeDecision(summary: String, details: [String: Any] = [:]) throws {
        guard canWrite(role: .contributor) else { throw WorkspaceMemoryError.unauthorized }
        var payload = details
        payload["summary"] = sanitize(summary, limit: 240)
        _ = try writeEvent(type: "decision.proposed", scope: "project", payload: payload)
    }

    public func revoke(deviceID: String) throws {
        guard canWrite(role: .owner) else { throw WorkspaceMemoryError.unauthorized }
        _ = try writeEvent(type: "member.revoked", scope: "device", payload: ["deviceId": deviceID])
    }

    public func updateMember(deviceID: String, role: MemoryRole, score: Int, displayName: String? = nil) throws {
        guard canWrite(role: .owner) else { throw WorkspaceMemoryError.unauthorized }
        var payload: [String: Any] = [
            "deviceId": deviceID,
            "role": role.rawValue,
            "score": max(0, min(100, score)),
        ]
        if let displayName { payload["displayName"] = sanitize(displayName, limit: 80) }
        _ = try writeEvent(type: "member.updated", scope: "device", payload: payload)
    }

    public func resolveDecision(eventID: String, accept: Bool) throws {
        guard canWrite(role: .approver) else { throw WorkspaceMemoryError.unauthorized }
        guard let proposal = (state["pendingProposals"] as? [[String: Any]])?.first(where: { $0["eventId"] as? String == eventID }) else {
            return
        }
        if accept {
            _ = try writeEvent(type: "decision.accepted", scope: "project", supersedes: proposal["supersedes"] as? [String] ?? [], payload: proposal)
        } else {
            _ = try writeEvent(type: "decision.rejected", scope: "project", payload: ["proposalEventId": eventID])
        }
    }

    public func fileHash(for call: AgentToolCall, workspace: URL) -> (path: String, hash: String?, bytes: Int)? {
        guard call.name == "write_file",
              let arguments = parseArguments(call),
              let rawPath = arguments["path"] as? String,
              let file = safeWorkspaceURL(rawPath, workspace: workspace) else { return nil }
        let data = try? Data(contentsOf: file)
        return (safePath(rawPath), data.map { digest($0) }, data?.count ?? 0)
    }

    public func changedGitPaths(workspace: URL) -> Set<String> {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "status", "--porcelain", "--untracked-files=all"]
        process.currentDirectoryURL = workspace
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            let value = String(line)
            guard value.count > 3 else { return nil }
            return safePath(String(value.dropFirst(3)))
        })
    }

    public func recordTool(
        runID: UUID,
        call: AgentToolCall,
        result: String,
        beforeFile: (path: String, hash: String?, bytes: Int)?,
        beforeGit: Set<String>,
        workspace: URL
    ) {
        guard var task = tasks[runID.uuidString] else { return }
        let arguments = parseArguments(call) ?? [:]
        let toolPayload: [String: Any] = [
            "runId": runID.uuidString,
            "name": call.name,
            "path": arguments["path"] is String ? safePath(arguments["path"] as! String) : NSNull(),
            "commandSummary": call.name == "run_command" ? sanitize(arguments["command"] as? String ?? "", limit: 160) : NSNull(),
            "resultStatus": result.lowercased().contains("error") ? "failed" : "completed",
            "resultBytes": result.utf8.count,
        ]
        _ = try? writeEvent(type: "tool.executed", scope: "task", payload: toolPayload)
        task.tools.append(call.name)

        if let beforeFile,
           let afterURL = safeWorkspaceURL((arguments["path"] as? String) ?? "", workspace: workspace) {
            let afterData = try? Data(contentsOf: afterURL)
            let change: [String: Any] = [
                "runId": runID.uuidString,
                "path": beforeFile.path,
                "operation": "modified",
                "beforeHash": beforeFile.hash ?? NSNull(),
                "afterHash": afterData.map { digest($0) } ?? NSNull(),
                "beforeBytes": beforeFile.bytes,
                "afterBytes": afterData?.count ?? 0,
                "attribution": "write_file",
            ]
            _ = try? writeEvent(type: "file.changed", scope: "task", payload: change)
            task.changedFiles.append(change)
        }

        let afterGit = changedGitPaths(workspace: workspace)
        for path in afterGit.subtracting(beforeGit) {
            let change: [String: Any] = [
                "runId": runID.uuidString,
                "path": path,
                "operation": "modified",
                "attribution": "unattributed-shell-change",
            ]
            _ = try? writeEvent(type: "file.changed", scope: "task", payload: change)
            task.changedFiles.append(change)
        }
        tasks[runID.uuidString] = task
    }

    public func recordPrompt(runID: UUID, prompt: String) {
        guard var task = tasks[runID.uuidString] else { return }
        task.promptSummary = sanitize(prompt, limit: 240)
        task.promptHash = digest(Data(prompt.utf8))
        tasks[runID.uuidString] = task
    }

    public func finishTask(runID: UUID, success: Bool, finalText: String = "") {
        guard let task = tasks.removeValue(forKey: runID.uuidString) else { return }
        let status = success ? "completed" : "failed"
        let payload: [String: Any] = [
            "runId": task.runID,
            "status": status,
            "promptSummary": task.promptSummary,
            "promptHash": task.promptHash,
            "changedFiles": task.changedFiles,
            "toolCount": task.tools.count,
            "semanticStatus": "pending",
        ]
        _ = try? writeEvent(type: "task.\(status)", scope: "task", payload: payload)
        writeTaskNote(task, status: status, finalText: finalText)
        let language = explicitLanguage(in: task.promptSummary)
        let decision = explicitDecision(in: task.promptSummary)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let language, let identity = self.identity {
                _ = try? self.writeEvent(
                    type: "preference.set",
                    scope: "person",
                    payload: [
                        "personId": identity.personID,
                        "key": "language",
                        "value": language,
                        "source": "explicit-user-instruction",
                    ]
                )
            }
            if let decision {
                _ = try? self.writeEvent(
                    type: "decision.proposed",
                    scope: "project",
                    payload: ["summary": decision, "source": "explicit-user-instruction"]
                )
            }
            _ = try? self.writeEvent(
                type: "semantic.completed",
                scope: "task",
                payload: [
                    "runId": runID.uuidString,
                    "status": "completed",
                    "preferenceUpdated": language != nil,
                    "decisionProposed": decision != nil,
                ]
            )
        }
    }

    private func loadExisting() {
        guard let root = memoryDirectory else { return }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let loaded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              loaded["schemaVersion"] as? Int == 1,
              loaded["projectId"] is String,
              loaded["rootAuthority"] is [String: Any] else { return }
        manifest = loaded
        try? ensureIdentity()
        rebuildProjection()
        mapText = (try? String(contentsOf: root.appendingPathComponent("map.md"), encoding: .utf8)) ?? ""
    }

    private func initializeWorkspace() throws {
        guard let root = memoryDirectory, let identity else { throw WorkspaceMemoryError.noWorkspace }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for folder in ["events", "tasks", "decisions"] {
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

    private func ensureIdentity() throws {
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

    private func updateMapIfNeeded() throws {
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
        try mapText.write(to: root.appendingPathComponent("map.md"), atomically: true, encoding: .utf8)
        let mapRevision = (state["lastMapRevision"] as? Int ?? 0) + 1
        _ = try? writeEvent(type: "map.updated", scope: "project", payload: ["revision": mapRevision, "fingerprint": fingerprint])
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
        default: break
        }
    }

    @discardableResult
    private func writeEvent(
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

    private func signedObject(_ object: [String: Any], key: P256.Signing.PrivateKey?, actor: StoredIdentity) throws -> [String: Any] {
        guard let key else { throw WorkspaceMemoryError.unauthorized }
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let signature = try key.signature(for: canonical).rawRepresentation.base64EncodedString()
        var result = object
        result["signature"] = ["algorithm": "P-256-SHA256", "value": signature]
        return result
    }

    private func beginTask(runID: UUID, prompt: String, provider: String, model: String) {
        let summary = sanitize(prompt, limit: 240)
        let task = TaskRecord(
            runID: runID.uuidString,
            promptSummary: summary,
            promptHash: digest(Data(prompt.utf8)),
            startedAt: isoNow(),
            provider: provider,
            model: model
        )
        tasks[runID.uuidString] = task
        _ = try? writeEvent(type: "task.started", scope: "task", payload: [
            "runId": task.runID,
            "promptSummary": task.promptSummary,
            "promptHash": task.promptHash,
            "startedAt": task.startedAt,
            "provider": sanitize(provider, limit: 80),
            "model": sanitize(model, limit: 120),
            "memoryRevision": revision,
        ])
    }

    private func writeTaskNote(_ task: TaskRecord, status: String, finalText: String) {
        guard let root = memoryDirectory else { return }
        let files = task.changedFiles.compactMap { $0["path"] as? String }.map { "- `\($0)` — modified" }
        let note = [
            "# Task: \(task.runID)",
            "",
            "- Actor: \(identity?.personID ?? "unknown")",
            "- Device: \(identity?.deviceID ?? "unknown")",
            "- Started: \(task.startedAt)",
            "- Completed: \(isoNow())",
            "- Status: \(status)",
            "",
            "## Request summary",
            "",
            task.promptSummary,
            "",
            "## Changed files",
            "",
            files.isEmpty ? "- None recorded" : files.joined(separator: "\n"),
            "",
            "## Result",
            "",
            sanitize(finalText, limit: 600),
            "",
            "## Decisions",
            "",
            "- Decisions remain event-backed and are not edited by the model.",
        ].joined(separator: "\n")
        try? fileManager.createDirectory(at: root.appendingPathComponent("tasks"), withIntermediateDirectories: true)
        try? note.write(to: root.appendingPathComponent("tasks").appendingPathComponent("\(task.runID).md"), atomically: true, encoding: .utf8)
    }

    private func writeDecisionNotes() {
        guard let root = memoryDirectory else { return }
        let decisions = state["acceptedDecisions"] as? [[String: Any]] ?? []
        try? fileManager.createDirectory(at: root.appendingPathComponent("decisions"), withIntermediateDirectories: true)
        for decision in decisions {
            guard let eventID = decision["eventId"] as? String else { continue }
            let payload = decision["payload"] as? [String: Any] ?? [:]
            let summary = payload["summary"] as? String ?? payload["value"] as? String ?? "Accepted project decision"
            let note = [
                "# Decision: \(eventID)",
                "",
                "- Status: accepted",
                "- Actor: \((decision["actor"] as? [String: Any])?["personId"] as? String ?? "unknown")",
                "- Revision: \(decision["lamport"] as? Int ?? 0)",
                "",
                "## Summary",
                "",
                sanitize(summary, limit: 600),
            ].joined(separator: "\n")
            try? note.write(to: root.appendingPathComponent("decisions").appendingPathComponent("\(eventID).md"), atomically: true, encoding: .utf8)
        }
    }

    private func relevantTasks(for prompt: String) -> String {
        guard let root = memoryDirectory,
              let files = try? fileManager.contentsOfDirectory(at: root.appendingPathComponent("tasks"), includingPropertiesForKeys: nil) else { return "" }
        let terms = prompt.split { $0 == "/" || $0 == " " || $0 == "\n" }.filter { $0.count > 2 }.map(String.init)
        let notes = files.filter { $0.pathExtension == "md" }.compactMap { url -> String? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return terms.contains(where: { text.localizedCaseInsensitiveContains($0) }) ? text : nil
        }
        if !notes.isEmpty { return notes.prefix(3).joined(separator: "\n\n") }
        return files.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(3).compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n\n")
    }

    private func preferencesText() -> String {
        guard let identity,
              let all = state["activePreferences"] as? [String: Any],
              let preferences = all[identity.personID] as? [String: Any] else { return "" }
        return markdownDictionary(preferences)
    }

    private func markdownList(_ list: [[String: Any]], prefix: String = "Decision") -> String {
        list.map { item in
            let id = item["eventId"] as? String ?? "unknown"
            let payload = item["payload"] as? [String: Any] ?? item
            let summary = payload["summary"] as? String ?? payload["key"] as? String ?? payload["value"] as? String ?? id
            return "- \(prefix) `\(id)`: \(sanitize(summary, limit: 240))"
        }.joined(separator: "\n")
    }

    private func decisionKey(_ event: [String: Any]) -> String {
        let payload = event["payload"] as? [String: Any] ?? [:]
        return payload["key"] as? String ?? payload["summary"] as? String ?? event["eventId"] as? String ?? "unknown"
    }

    private func eventWins(_ candidate: [String: Any], over current: [String: Any]) -> Bool {
        func authority(_ event: [String: Any]) -> (Int, Int, Int, String) {
            let deviceID = (event["actor"] as? [String: Any])?["deviceId"] as? String ?? ""
            let member = member(deviceID: deviceID)
            let role = MemoryRole(rawValue: member?["role"] as? String ?? "observer")?.rank ?? 0
            let score = member?["score"] as? Int ?? 0
            return (role, score, event["lamport"] as? Int ?? 0, event["eventId"] as? String ?? "")
        }
        let left = authority(candidate)
        let right = authority(current)
        if left.0 != right.0 { return left.0 > right.0 }
        if left.1 != right.1 { return left.1 > right.1 }
        if left.2 != right.2 { return left.2 > right.2 }
        return left.3 > right.3
    }

    private func markdownDictionary(_ dictionary: [String: Any]) -> String {
        dictionary.keys.sorted().map { key in
            "- `\(key)`: \(sanitize(String(describing: dictionary[key] ?? ""), limit: 240))"
        }.joined(separator: "\n")
    }

    private func trimSnapshot(_ text: String) -> String {
        let limit = 32_000
        guard text.utf8.count > limit else { return text }
        return String(text.prefix(limit)) + "\n[older memory trimmed]"
    }

    private func explicitLanguage(in text: String) -> String? {
        let lower = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let explicit = lower.contains("artık") || lower.contains("bundan sonra") || lower.contains("from now")
            || lower.contains("i want") || lower.contains("istiyorum") || lower.contains("tercih")
            || lower.contains("cevap ver") || lower.contains("konuş") || lower.contains("output")
        if explicit,
           lower.contains("ingilizce") || lower.contains("english") { return "English" }
        if explicit,
           lower.contains("türkçe") || lower.contains("turkish") { return "Turkish" }
        return nil
    }

    private func explicitDecision(in text: String) -> String? {
        let lower = text.lowercased()
        let markers = ["karar:", "decision:", "kullanalım", "we will use", "let's use"]
        guard markers.contains(where: { lower.contains($0) }) else { return nil }
        let value = text.replacingOccurrences(of: "\n", with: " ")
        return sanitize(value, limit: 240)
    }

    private func currentMember() -> [String: Any]? {
        guard let deviceID = identity?.deviceID else { return nil }
        return member(deviceID: deviceID)
    }

    private func member(deviceID: String) -> [String: Any]? {
        (state["members"] as? [[String: Any]] ?? []).first { $0["deviceId"] as? String == deviceID }
    }

    private func upsertMember(_ payload: [String: Any]) {
        guard let deviceID = payload["deviceId"] as? String else { return }
        var members = state["members"] as? [[String: Any]] ?? []
        members.removeAll { $0["deviceId"] as? String == deviceID }
        members.append(payload)
        state["members"] = members
    }

    private func setMember(deviceID: String, key: String, value: Any) {
        var members = state["members"] as? [[String: Any]] ?? []
        guard let index = members.firstIndex(where: { $0["deviceId"] as? String == deviceID }) else { return }
        members[index][key] = value
        state["members"] = members
    }

    private func canWrite(role required: MemoryRole) -> Bool {
        guard let member = currentMember(),
              member["revoked"] as? Bool != true,
              let role = member["role"] as? String,
              let actual = MemoryRole(rawValue: role) else { return false }
        return actual.rank >= required.rank
    }

    private func canWrite(for type: String) -> Bool {
        switch type {
        case "workspace.initialized": return true
        case "member.accepted": return true
        case "member.invited", "member.revoked", "member.updated": return canWrite(role: .owner)
        case "decision.accepted", "decision.rejected", "project.default.set": return canWrite(role: .approver)
        case "preference.set": return canWrite(role: .observer)
        default: return canWrite(role: .contributor)
        }
    }

    private var rootPublicKeyString: String? { (manifest?["rootAuthority"] as? [String: Any])?["publicKey"] as? String }
    private var rootDeviceID: String? { (manifest?["rootAuthority"] as? [String: Any])?["deviceId"] as? String }
    private var rootPublicKey: P256.Signing.PublicKey? {
        guard let value = rootPublicKeyString, let data = Data(base64Encoded: value) else { return nil }
        return try? P256.Signing.PublicKey(rawRepresentation: data)
    }

    private func verify(signature: String, object: [String: Any], publicKey: P256.Signing.PublicKey) -> Bool {
        guard let signatureData = Data(base64Encoded: signature),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return false }
        return publicKey.isValidSignature(signature, for: data)
    }

    private func invitationWithoutSignature(_ object: [String: Any]) -> [String: Any] {
        object.filter { $0.key != "signature" }
    }

    private func parseArguments(_ call: AgentToolCall) -> [String: Any]? {
        guard let data = call.arguments.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func safeWorkspaceURL(_ path: String, workspace: URL) -> URL? {
        let url = URL(fileURLWithPath: path.isEmpty ? "." : path, relativeTo: workspace).standardizedFileURL
        let root = workspace.standardizedFileURL.path
        let memory = root + "/.mem"
        guard (url.path == root || url.path.hasPrefix(root + "/")), url.path != memory, !url.path.hasPrefix(memory + "/") else { return nil }
        return url
    }

    private func safePath(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.split(separator: "/").contains(where: { $0 == ".env" || $0.lowercased().contains("secret") || $0.lowercased().contains("token") }) { return "<redacted>" }
        return String(normalized.prefix(300))
    }

    private func sanitize(_ text: String, limit: Int) -> String {
        var result = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let patterns = [
            #"(?i)(api[_-]?key|token|password|secret)\s*[:=]\s*[^\s,;]+"#,
            #"(?i)bearer\s+[A-Za-z0-9._\-]+"#,
            #"(?i)authorization\s*:\s*[^\s,;]+"#,
        ]
        for pattern in patterns { result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression) }
        return String(result.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func emptyState() -> [String: Any] {
        [
            "revision": 0,
            "members": [[String: Any]](),
            "projectDefaults": [String: Any](),
            "activePreferences": [String: Any](),
            "acceptedDecisions": [[String: Any]](),
            "pendingProposals": [[String: Any]](),
            "supersededValues": [[String: Any]](),
            "lastMapRevision": 0,
        ]
    }
}
