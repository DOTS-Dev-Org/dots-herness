// Copyright (c) 2026 DOTS
// Persistent, conflict-aware workspace snapshots used by conversation rewind.

import CryptoKit
import Foundation
import PluginRuntime

enum WorkspaceSnapshotError: Error {
    case unavailable
    case unsupportedEntry
    case invalidPath
    case restoreFailed(String)
}

struct WorkspaceChangeResult: Sendable, Equatable {
    let changedFiles: [ChangedFile]
    let trackingStatus: String
    let failureReason: String?
}

struct WorkspaceSnapshotStore {
    private struct FileState: Codable, Equatable {
        let hash: String
        let bytes: Int
        let permissions: Int
    }

    private struct Snapshot: Codable {
        let version: Int
        let conversationID: String
        let turnID: String
        let workspacePath: String
        let before: [String: FileState]
        var after: [String: FileState]?
        var changedFiles: [ChangedFile]
        var complete: Bool
    }

    private enum Observation {
        case missing
        case file(FileState, Data)
        case other
    }

    private let root: URL
    private let fileManager: FileManager

    init(paths: SupportPaths, fileManager: FileManager = .default) {
        self.root = paths.root.appendingPathComponent("rewind", isDirectory: true)
        self.fileManager = fileManager
    }

    func begin(conversationID: String, turnID: String, workspace: URL) -> Bool {
        // ponytail: synchronous full-tree snapshots keep ordering exact; move
        // capture off the main actor only if measured workspace size makes it
        // visible, then gate the turn on the completed snapshot.
        let directory = snapshotDirectory(conversationID: conversationID, turnID: turnID)
        do {
            guard !fileManager.fileExists(atPath: directory.path) else { return false }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let beforeDirectory = directory.appendingPathComponent("before", isDirectory: true)
            try fileManager.createDirectory(at: beforeDirectory, withIntermediateDirectories: true)
            let before = try capture(workspace: workspace, backupDirectory: beforeDirectory)
            let snapshot = Snapshot(
                version: 1,
                conversationID: conversationID,
                turnID: turnID,
                workspacePath: workspace.standardizedFileURL.path,
                before: before,
                after: nil,
                changedFiles: [],
                complete: false
            )
            try write(snapshot, to: manifestURL(in: directory))
            return true
        } catch {
            try? fileManager.removeItem(at: directory)
            return false
        }
    }

    func finishResult(conversationID: String, turnID: String, workspace: URL) -> WorkspaceChangeResult {
        let directory = snapshotDirectory(conversationID: conversationID, turnID: turnID)
        do {
            var snapshot = try read(from: manifestURL(in: directory))
            guard snapshot.conversationID == conversationID,
                  snapshot.turnID == turnID,
                  snapshot.workspacePath == workspace.standardizedFileURL.path else {
                return WorkspaceChangeResult(changedFiles: [], trackingStatus: "incomplete", failureReason: "Snapshot identity did not match.")
            }
            let after = try capture(workspace: workspace, backupDirectory: nil)
            let changedFiles = changedFiles(before: snapshot.before, after: after)
            snapshot.after = after
            snapshot.changedFiles = changedFiles
            snapshot.complete = true
            try write(snapshot, to: manifestURL(in: directory))
            return WorkspaceChangeResult(changedFiles: changedFiles, trackingStatus: "complete", failureReason: nil)
        } catch {
            return WorkspaceChangeResult(changedFiles: [], trackingStatus: "incomplete", failureReason: error.localizedDescription)
        }
    }

    func finish(conversationID: String, turnID: String, workspace: URL) -> [ChangedFile] {
        finishResult(conversationID: conversationID, turnID: turnID, workspace: workspace).changedFiles
    }

    func hasCompleteSnapshot(
        conversationID: String,
        turnID: String,
        workspace: URL
    ) -> Bool {
        guard let snapshot = try? read(from: manifestURL(in: snapshotDirectory(conversationID: conversationID, turnID: turnID))) else {
            return false
        }
        return snapshot.conversationID == conversationID
            && snapshot.turnID == turnID
            && snapshot.complete
            && snapshot.after != nil
            && snapshot.workspacePath == workspace.standardizedFileURL.path
            && beforeBackupsExist(for: snapshot)
    }

    func restore(
        conversationID: String,
        turnIDs: [String],
        workspace: URL,
        abortOnConflict: Bool
    ) throws -> RewindResult {
        guard !turnIDs.isEmpty else { throw WorkspaceSnapshotError.unavailable }
        let snapshots = try turnIDs.map { turnID in
            let snapshot = try read(from: manifestURL(in: snapshotDirectory(conversationID: conversationID, turnID: turnID)))
            guard snapshot.conversationID == conversationID, snapshot.turnID == turnID else {
                throw WorkspaceSnapshotError.unavailable
            }
            return snapshot
        }
        guard snapshots.allSatisfy({
            $0.complete
                && $0.after != nil
                && $0.workspacePath == workspace.standardizedFileURL.path
                && beforeBackupsExist(for: $0)
        }) else {
            throw WorkspaceSnapshotError.unavailable
        }

        let first = snapshots[0]
        guard let lastAfter = snapshots.last?.after else { throw WorkspaceSnapshotError.unavailable }
        let changedPaths = Set(first.before.keys).union(lastAfter.keys)
            .filter { first.before[$0] != lastAfter[$0] }
            .sorted()
        guard !changedPaths.isEmpty else { return RewindResult() }

        var observations: [String: Observation] = [:]
        var conflicts: [String] = []
        for path in changedPaths {
            let observation = try observe(path: path, workspace: workspace)
            observations[path] = observation
            let expected = lastAfter[path]
            if !matches(observation, expected: expected) {
                let initial = first.before[path]
                if !matches(observation, expected: initial) {
                    conflicts.append(path)
                }
            }
        }
        conflicts.sort()
        if abortOnConflict, !conflicts.isEmpty {
            return RewindResult(conflictPaths: conflicts)
        }

        let restorablePaths = changedPaths.filter { !conflicts.contains($0) }
        var restored: [String] = []
        do {
            for path in restorablePaths {
                guard let observation = observations[path] else { throw WorkspaceSnapshotError.invalidPath }
                // The user may already have put this path back at the pre-turn
                // state. Treat that as a safe no-op, especially for files that
                // were added by the agent and then removed by the user.
                if matches(observation, expected: first.before[path]) { continue }
                try restore(
                    path: path,
                    to: first.before[path],
                    from: first,
                    observation: observation,
                    workspace: workspace
                )
                restored.append(path)
            }
        } catch let error as WorkspaceSnapshotError {
            for path in restored {
                if let observation = observations[path] {
                    try? restoreObservation(observation, path: path, workspace: workspace)
                }
            }
            if case .restoreFailed = error { throw error }
            throw WorkspaceSnapshotError.restoreFailed(restored.last ?? "workspace")
        } catch {
            for path in restored {
                if let observation = observations[path] {
                    try? restoreObservation(observation, path: path, workspace: workspace)
                }
            }
            throw WorkspaceSnapshotError.restoreFailed(restored.last ?? "workspace")
        }
        return RewindResult(restoredPaths: restored, conflictPaths: conflicts)
    }

    func removeConversation(_ conversationID: String) {
        try? fileManager.removeItem(at: root.appendingPathComponent(safeComponent(conversationID), isDirectory: true))
    }

    private func capture(workspace: URL, backupDirectory: URL?) throws -> [String: FileState] {
        let rootURL = workspace.standardizedFileURL
        var result: [String: FileState] = [:]
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { throw WorkspaceSnapshotError.unavailable }

        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: keys)
            let relative = try relativePath(for: url, workspace: rootURL)
            let components = relative.split(separator: "/").map(String.init)
            if components.contains(where: { ignoredWorkspaceDirectories.contains($0) }) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let data = try Data(contentsOf: url)
            let state = FileState(
                hash: digest(data),
                bytes: data.count,
                permissions: posixPermissions(for: url)
            )
            result[relative] = state
            if let backupDirectory {
                let destination = backupDirectory.appendingPathComponent(relative)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                try? fileManager.setAttributes(
                    [.posixPermissions: state.permissions],
                    ofItemAtPath: destination.path
                )
            }
        }
        return result
    }

    private let ignoredWorkspaceDirectories: Set<String> = [
        ".git", ".mem", ".build", "build", "bin", "obj", "dist", "node_modules", "Pods", "DerivedData",
    ]

    private func observe(path: String, workspace: URL) throws -> Observation {
        let url = try safeURL(path, workspace: workspace)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .missing }
        guard !isDirectory.boolValue else { return .other }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { return .other }
        let data = try Data(contentsOf: url)
        return .file(
            FileState(
                hash: digest(data),
                bytes: data.count,
                permissions: posixPermissions(for: url)
            ),
            data
        )
    }

    private func posixPermissions(for url: URL) -> Int {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    private func matches(_ observation: Observation, expected: FileState?) -> Bool {
        switch (observation, expected) {
        case (.missing, nil): return true
        case let (.file(actual, _), expected?): return actual == expected
        default: return false
        }
    }

    private func restore(
        path: String,
        to initial: FileState?,
        from snapshot: Snapshot,
        observation: Observation,
        workspace: URL
    ) throws {
        let url = try safeURL(path, workspace: workspace)
        guard let initial else {
            guard case .file = observation else { throw WorkspaceSnapshotError.restoreFailed(path) }
            try fileManager.removeItem(at: url)
            return
        }
        guard let backup = backupURL(path: path, snapshot: snapshot) else {
            throw WorkspaceSnapshotError.invalidPath
        }
        let data = try Data(contentsOf: backup)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: initial.permissions], ofItemAtPath: url.path)
    }

    private func restoreObservation(_ observation: Observation, path: String, workspace: URL) throws {
        let url = try safeURL(path, workspace: workspace)
        switch observation {
        case .missing:
            try? fileManager.removeItem(at: url)
        case let .file(state, data):
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: state.permissions], ofItemAtPath: url.path)
        case .other:
            break
        }
    }

    private func changedFiles(
        before: [String: FileState],
        after: [String: FileState]
    ) -> [ChangedFile] {
        Set(before.keys).union(after.keys).compactMap { path in
            guard before[path] != after[path] else { return nil }
            let operation: ChangedFile.Operation
            switch (before[path], after[path]) {
            case (nil, .some): operation = .added
            case (.some, nil): operation = .deleted
            default: operation = .modified
            }
            return ChangedFile(path: path, operation: operation)
        }.sorted { $0.path < $1.path }
    }

    private func beforeBackupsExist(for snapshot: Snapshot) -> Bool {
        let beforeDirectory = snapshotDirectory(
            conversationID: snapshot.conversationID,
            turnID: snapshot.turnID
        ).appendingPathComponent("before", isDirectory: true)
        return snapshot.before.allSatisfy { path, state in
            guard let backup = safeBackupURL(path: path, relativeTo: beforeDirectory) else { return false }
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: backup.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return false }
            let size = (try? fileManager.attributesOfItem(atPath: backup.path)[.size] as? NSNumber)?.intValue
            return size == state.bytes
        }
    }

    private func backupURL(path: String, snapshot: Snapshot) -> URL? {
        let beforeDirectory = snapshotDirectory(
            conversationID: snapshot.conversationID,
            turnID: snapshot.turnID
        ).appendingPathComponent("before", isDirectory: true)
        return safeBackupURL(path: path, relativeTo: beforeDirectory)
    }

    private func safeBackupURL(path: String, relativeTo directory: URL) -> URL? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
        let root = directory.standardizedFileURL.path
        return url.path.hasPrefix(root + "/") ? url : nil
    }

    private func relativePath(for url: URL, workspace: URL) throws -> String {
        let root = workspace.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { throw WorkspaceSnapshotError.invalidPath }
        let relative = String(path.dropFirst(root.count + 1))
        guard !relative.isEmpty,
              !relative.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw WorkspaceSnapshotError.invalidPath
        }
        return relative
    }

    private func safeURL(_ path: String, workspace: URL) throws -> URL {
        let url = URL(fileURLWithPath: path, relativeTo: workspace).standardizedFileURL
        let root = workspace.standardizedFileURL.path
        guard url.path.hasPrefix(root + "/"), !path.isEmpty else { throw WorkspaceSnapshotError.invalidPath }
        return url
    }

    private func snapshotDirectory(conversationID: String, turnID: String) -> URL {
        root
            .appendingPathComponent(safeComponent(conversationID), isDirectory: true)
            .appendingPathComponent(safeComponent(turnID), isDirectory: true)
    }

    private func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("manifest.json")
    }

    private func safeComponent(_ value: String) -> String {
        let component = value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
        }
        return String(component.prefix(100))
    }

    private func read(from url: URL) throws -> Snapshot {
        let data = try Data(contentsOf: url)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version == 1 else { throw WorkspaceSnapshotError.unavailable }
        return snapshot
    }

    private func write(_ snapshot: Snapshot, to url: URL) throws {
        let data = try JSONEncoder().encode(snapshot)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
