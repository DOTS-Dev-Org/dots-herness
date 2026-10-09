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
        var undone: Bool?
        /// When each `before` file was last modified, and when the capture started. Later
        /// captures skip reading a file whose modification time and size still match.
        var beforeModified: [String: Double]?
        var capturedAt: Double?
        /// Files whose backup was not copied into this turn: each maps to the earlier turn's
        /// backup that already holds the same content (path relative to the rewind root).
        /// Creating a directory entry per file costs ~0.3 ms on APFS, which for a project
        /// of a thousand files is most of a snapshot; unchanged files need none.
        var beforeSources: [String: String]?
    }

    /// The last capture of one workspace, kept between turns so the next one can skip the
    /// files that did not change and link their backups instead of copying them again.
    private struct WorkspaceIndex: Codable {
        let workspacePath: String
        let capturedAt: Double
        let states: [String: FileState]
        let modified: [String: Double]
        /// Backup file holding each file's content, relative to the rewind root.
        let backups: [String: String]
    }

    /// Earlier knowledge a capture may rely on for files that have not changed.
    private struct TrustedFiles {
        let states: [String: FileState]
        let modified: [String: Double]
        /// Files modified at or after this are read again: a change in the same instant
        /// as the earlier capture cannot be told apart by time (git's "racily clean" rule).
        let cutoff: Double
        /// Existing backup files with the same content, relative to the rewind root, for a
        /// capture that keeps backups.
        let backups: [String: String]
    }

    private struct Captured {
        var states: [String: FileState]
        var modified: [String: Double]
        /// Files of this capture that reference an earlier backup instead of copying.
        var sources: [String: String] = [:]
    }

    private static let racyWindow: Double = 2

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
            let workspacePath = workspace.standardizedFileURL.path
            let capturedAt = Date().timeIntervalSince1970
            var trusted: TrustedFiles?
            if let index = readIndex(for: workspacePath) {
                trusted = TrustedFiles(
                    states: index.states,
                    modified: index.modified,
                    cutoff: index.capturedAt - Self.racyWindow,
                    backups: index.backups
                )
            }
            let before = try capture(workspace: workspace, backupDirectory: beforeDirectory, trusted: trusted)
            let snapshot = Snapshot(
                version: 1,
                conversationID: conversationID,
                turnID: turnID,
                workspacePath: workspacePath,
                before: before.states,
                after: nil,
                changedFiles: [],
                complete: false,
                beforeModified: before.modified,
                capturedAt: capturedAt,
                beforeSources: before.sources.isEmpty ? nil : before.sources
            )
            try write(snapshot, to: manifestURL(in: directory))
            let ownPrefix = "\(safeComponent(conversationID))/\(safeComponent(turnID))/before/"
            writeIndex(WorkspaceIndex(
                workspacePath: workspacePath,
                capturedAt: capturedAt,
                states: before.states,
                modified: before.modified,
                // Where each file's content physically lives: an earlier turn's copy when this
                // turn referenced it, this turn's own copy otherwise.
                backups: Dictionary(uniqueKeysWithValues: before.states.keys.map { path in
                    (path, before.sources[path] ?? ownPrefix + path)
                })
            ))
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
            // Only files whose time or size moved since the pre-turn capture are read again.
            let trusted = TrustedFiles(
                states: snapshot.before,
                modified: snapshot.beforeModified ?? [:],
                cutoff: (snapshot.capturedAt ?? 0) - Self.racyWindow,
                backups: [:]
            )
            let after = try capture(workspace: workspace, backupDirectory: nil, trusted: trusted).states
            let changedFiles = changedFiles(
                before: snapshot.before,
                after: after,
                conversationID: conversationID,
                turnID: turnID,
                workspace: workspace
            )
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

    /// The file as it was before the turn ran; nil when the turn created it.
    func beforeContent(conversationID: String, turnID: String, path: String) -> Data? {
        let directory = snapshotDirectory(conversationID: conversationID, turnID: turnID)
        guard let snapshot = try? read(from: manifestURL(in: directory)),
              snapshot.before[path] != nil,
              let url = backupURL(path: path, snapshot: snapshot) else { return nil }
        return try? Data(contentsOf: url)
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

    func hasUndoableSnapshot(
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
            && snapshot.undone != true
            && !snapshot.changedFiles.isEmpty
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
        var snapshots = try turnIDs.map { turnID in
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
        guard !changedPaths.isEmpty else {
            markUndone(&snapshots, conversationID: conversationID)
            return RewindResult()
        }

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
        markUndone(&snapshots, conversationID: conversationID)
        return RewindResult(restoredPaths: restored, conflictPaths: conflicts)
    }

    private func markUndone(_ snapshots: inout [Snapshot], conversationID: String) {
        for index in snapshots.indices {
            snapshots[index].undone = true
            let url = manifestURL(in: snapshotDirectory(
                conversationID: conversationID,
                turnID: snapshots[index].turnID
            ))
            try? write(snapshots[index], to: url)
        }
    }

    private func indexURL(for workspacePath: String) -> URL {
        let name = SHA256.hash(data: Data(workspacePath.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return root
            .appendingPathComponent("_workspace-index", isDirectory: true)
            .appendingPathComponent(name + ".json")
    }

    private func readIndex(for workspacePath: String) -> WorkspaceIndex? {
        guard let data = try? Data(contentsOf: indexURL(for: workspacePath)),
              let index = try? JSONDecoder().decode(WorkspaceIndex.self, from: data),
              index.workspacePath == workspacePath else { return nil }
        return index
    }

    /// Losing the index only costs the next capture a full read.
    private func writeIndex(_ index: WorkspaceIndex) {
        let url = indexURL(for: index.workspacePath)
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func removeConversation(_ conversationID: String) {
        let component = safeComponent(conversationID)
        materializeReferences(pointingInto: component)
        try? fileManager.removeItem(at: root.appendingPathComponent(component, isDirectory: true))
    }

    /// Other turns may reference backups stored under this conversation. Before it is deleted
    /// those files are given to the turns that use them, so their rewind keeps working.
    private func materializeReferences(pointingInto component: String) {
        let prefix = component + "/"
        guard let conversations = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        for other in conversations where other != component && !other.hasPrefix("_") {
            let otherDirectory = root.appendingPathComponent(other, isDirectory: true)
            guard let turns = try? fileManager.contentsOfDirectory(atPath: otherDirectory.path) else { continue }
            for turn in turns {
                let turnDirectory = otherDirectory.appendingPathComponent(turn, isDirectory: true)
                let manifest = manifestURL(in: turnDirectory)
                guard var snapshot = try? read(from: manifest),
                      let sources = snapshot.beforeSources,
                      sources.values.contains(where: { $0.hasPrefix(prefix) }) else { continue }
                let beforeDirectory = turnDirectory.appendingPathComponent("before", isDirectory: true)
                var remaining = sources
                for (path, reference) in sources where reference.hasPrefix(prefix) {
                    let source = root.appendingPathComponent(reference)
                    guard let destination = safeBackupURL(path: path, relativeTo: beforeDirectory) else { continue }
                    try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if link(source.path, destination.path) == 0
                        || (try? fileManager.copyItem(at: source, to: destination)) != nil {
                        remaining[path] = nil
                    }
                }
                snapshot.beforeSources = remaining.isEmpty ? nil : remaining
                try? write(snapshot, to: manifest)
            }
        }
    }

    private func capture(workspace: URL, backupDirectory: URL?, trusted: TrustedFiles? = nil) throws -> Captured {
        let rootURL = workspace.standardizedFileURL
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

        // Walk first (metadata only), then read files side by side. The read, hash and
        // backup copy of one file never depend on another, and on a slow or cold disk
        // (an external drive) most of the time is spent waiting: overlapping the files
        // makes a snapshot cost far less than the sum of every file's wait.
        var entries: [(url: URL, relative: String)] = []
        let rootPrefix = rootURL.path + "/"
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: keys)
            // Entries come back under the URL we handed in, so the relative path is a plain
            // prefix strip; standardizing every URL costs more than the rest of the walk.
            let path = url.path
            let relative = path.hasPrefix(rootPrefix)
                ? String(path.dropFirst(rootPrefix.count))
                : try relativePath(for: url, workspace: rootURL)
            let components = relative.split(separator: "/")
            if components.contains(where: { $0 == "." || $0 == ".." }) { throw WorkspaceSnapshotError.invalidPath }
            if components.contains(where: { ignoredWorkspaceDirectories.contains(String($0)) }) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            entries.append((url, relative))
        }

        // Backup directories once, up front, instead of a create call per file.
        if let backupDirectory {
            var directories = Set<String>()
            for entry in entries {
                if let slash = entry.relative.lastIndex(of: "/") { directories.insert(String(entry.relative[..<slash])) }
            }
            for directory in directories {
                try fileManager.createDirectory(
                    at: backupDirectory.appendingPathComponent(directory, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
        }

        // Only reference a backup whose turn directory still exists.
        var liveSources = Set<String>()
        if backupDirectory != nil, let trusted {
            for reference in Set(trusted.backups.values.map { $0.split(separator: "/").prefix(2).joined(separator: "/") }) {
                var isDirectory = ObjCBool(false)
                if fileManager.fileExists(atPath: root.appendingPathComponent(reference).path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    liveSources.insert(reference)
                }
            }
        }

        let liveSourceDirectories = liveSources
        let files = entries
        let outcome = CaptureOutcome(count: files.count)
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            guard !outcome.hasFailed else { return }
            let entry = files[index]
            do {
                // stat, link and chmod directly: per file, Foundation's attribute and link
                // wrappers cost more than the system calls they wrap.
                guard let facts = Self.fileFacts(at: entry.url.path) else {
                    throw WorkspaceSnapshotError.restoreFailed(entry.relative)
                }
                let destination = backupDirectory?.appendingPathComponent(entry.relative)

                // Unchanged since the earlier capture: no read, no hash, and the backup is a
                // link to the copy that already exists.
                if let trusted,
                   let known = trusted.states[entry.relative],
                   trusted.modified[entry.relative] == facts.modified,
                   facts.modified < trusted.cutoff,
                   known.bytes == facts.size,
                   known.permissions == facts.permissions {
                    if let destination {
                        if let reference = trusted.backups[entry.relative],
                           liveSourceDirectories.contains(reference.split(separator: "/").prefix(2).joined(separator: "/")) {
                            outcome.set(known, modified: facts.modified, source: reference, at: index)
                            return
                        }
                        let data = try Data(contentsOf: entry.url)
                        guard data.count == facts.size else { throw WorkspaceSnapshotError.restoreFailed(entry.relative) }
                        try data.write(to: destination)
                        _ = chmod(destination.path, mode_t(facts.permissions))
                    }
                    outcome.set(known, modified: facts.modified, at: index)
                    return
                }

                let data = try Data(contentsOf: entry.url)
                if let destination {
                    try data.write(to: destination)
                    _ = chmod(destination.path, mode_t(facts.permissions))
                }
                outcome.set(
                    FileState(hash: Self.digest(data), bytes: data.count, permissions: facts.permissions),
                    modified: facts.modified,
                    at: index
                )
            } catch {
                outcome.fail(error)
            }
        }
        if let error = outcome.error { throw error }

        var captured = Captured(states: [:], modified: [:])
        captured.states.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            guard let state = outcome.states[index] else { continue }
            captured.states[entry.relative] = state
            if let modified = outcome.modified[index] { captured.modified[entry.relative] = modified }
            if let source = outcome.sources[index] { captured.sources[entry.relative] = source }
        }
        return captured
    }

    /// Per-file results of a parallel capture; the first failure stops the rest.
    private final class CaptureOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var states: [FileState?]
        private(set) var modified: [Double?]
        private(set) var sources: [String?]
        private(set) var error: Error?

        init(count: Int) {
            states = Array(repeating: nil, count: count)
            modified = Array(repeating: nil, count: count)
            sources = Array(repeating: nil, count: count)
        }

        var hasFailed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return error != nil
        }

        func set(_ state: FileState, modified time: Double?, source: String? = nil, at index: Int) {
            lock.lock()
            states[index] = state
            modified[index] = time
            sources[index] = source
            lock.unlock()
        }

        func fail(_ failure: Error) {
            lock.lock()
            if error == nil { error = failure }
            lock.unlock()
        }
    }

    private static func fileFacts(at path: String) -> (size: Int, permissions: Int, modified: Double)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return (
            Int(info.st_size),
            Int(info.st_mode & 0o7777),
            Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        )
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private let ignoredWorkspaceDirectories: Set<String> = [
        ".git", ".mem", ".build", "build", "bin", "obj", "dist", "node_modules", "Pods", "DerivedData",
        // Regenerated by tooling, and often thousands of files.
        ".next", ".nuxt", ".turbo", ".gradle", ".dart_tool", ".venv", "venv", "__pycache__",
        ".pytest_cache", ".mypy_cache",
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
        after: [String: FileState],
        conversationID: String,
        turnID: String,
        workspace: URL
    ) -> [ChangedFile] {
        Set(before.keys).union(after.keys).compactMap { path in
            guard before[path] != after[path] else { return nil }
            let operation: ChangedFile.Operation
            switch (before[path], after[path]) {
            case (nil, .some): operation = .added
            case (.some, nil): operation = .deleted
            default: operation = .modified
            }
            let old = before[path]
            let new = after[path]
            let oldBytes = old?.bytes ?? 0
            let newBytes = new?.bytes ?? 0
            guard oldBytes <= 16 * 1024 * 1024, newBytes <= 16 * 1024 * 1024 else {
                return ChangedFile(path: path, operation: operation)
            }
            let beforeData = old == nil ? nil : beforeContent(
                conversationID: conversationID,
                turnID: turnID,
                path: path
            )
            let afterData: Data?
            if new == nil {
                afterData = nil
            } else {
                let url = try? safeURL(path, workspace: workspace)
                afterData = url.flatMap { try? Data(contentsOf: $0) }
            }
            guard (old == nil || beforeData.map(digest) == old?.hash),
                  (new == nil || afterData.map(digest) == new?.hash) else {
                return ChangedFile(path: path, operation: operation)
            }
            return measureChangedFile(path: path, operation: operation, before: beforeData, after: afterData)
        }.sorted { $0.path < $1.path }
    }

    private func measureChangedFile(
        path: String,
        operation: ChangedFile.Operation,
        before: Data?,
        after: Data?
    ) -> ChangedFile {
        let (added, deleted) = lineChanges(before: before, after: after)
        return ChangedFile(path: path, operation: operation, addedLines: added, deletedLines: deleted)
    }

    private func lineChanges(before: Data?, after: Data?) -> (Int, Int) {
        func lines(_ data: Data?) -> [String]? {
            guard let data, !data.isEmpty else { return [] }
            if data.prefix(8_192).contains(0) { return nil }
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            var result = normalized.components(separatedBy: "\n")
            if result.last == "" { result.removeLast() }
            return result
        }
        guard var oldLines = lines(before), var newLines = lines(after) else { return (-1, -1) }
        var prefix = 0
        while prefix < oldLines.count && prefix < newLines.count && oldLines[prefix] == newLines[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldLines.count - prefix && suffix < newLines.count - prefix
            && oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] { suffix += 1 }
        oldLines = Array(oldLines[prefix..<(oldLines.count - suffix)])
        newLines = Array(newLines[prefix..<(newLines.count - suffix)])
        if oldLines.count + newLines.count > 4_096 { return (-1, -1) }
        let maximum = oldLines.count + newLines.count
        let offset = maximum
        var frontier = Array(repeating: 0, count: maximum * 2 + 3)
        frontier[offset + 1] = 0
        var trace: [[Int]] = []
        for distance in 0...maximum {
            if distance > 256 { return (-1, -1) }
            trace.append(frontier)
            var diagonal = -distance
            while diagonal <= distance {
                let index = offset + diagonal
                var x = diagonal == -distance || (diagonal != distance && frontier[index - 1] < frontier[index + 1])
                    ? frontier[index + 1]
                    : frontier[index - 1] + 1
                var y = x - diagonal
                while x < oldLines.count && y < newLines.count && oldLines[x] == newLines[y] { x += 1; y += 1 }
                frontier[index] = x
                if x >= oldLines.count && y >= newLines.count {
                    return backtrackLineChanges(
                        trace,
                        distance: distance,
                        oldCount: oldLines.count,
                        newCount: newLines.count,
                        offset: offset
                    )
                }
                diagonal += 2
            }
        }
        return (-1, -1)
    }

    private func backtrackLineChanges(
        _ trace: [[Int]],
        distance: Int,
        oldCount: Int,
        newCount: Int,
        offset: Int
    ) -> (Int, Int) {
        var x = oldCount
        var y = newCount
        var added = 0
        var deleted = 0
        if distance > 0 {
            for d in stride(from: distance, through: 1, by: -1) {
                let previous = trace[d]
                let diagonal = x - y
                let previousDiagonal = diagonal == -d || (diagonal != d && previous[offset + diagonal - 1] < previous[offset + diagonal + 1])
                    ? diagonal + 1
                    : diagonal - 1
                let previousX = previous[offset + previousDiagonal]
                let previousY = previousX - previousDiagonal
                while x > previousX && y > previousY { x -= 1; y -= 1 }
                if x == previousX { added += 1; y -= 1 }
                else { deleted += 1; x -= 1 }
            }
        }
        while x > 0 && y > 0 { x -= 1; y -= 1 }
        added += y
        deleted += x
        return (added, deleted)
    }

    private func beforeBackupsExist(for snapshot: Snapshot) -> Bool {
        return snapshot.before.allSatisfy { path, state in
            guard let backup = backupURL(path: path, snapshot: snapshot) else { return false }
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: backup.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return false }
            let size = (try? fileManager.attributesOfItem(atPath: backup.path)[.size] as? NSNumber)?.intValue
            return size == state.bytes
        }
    }

    private func backupURL(path: String, snapshot: Snapshot) -> URL? {
        if let reference = snapshot.beforeSources?[path] {
            let url = root.appendingPathComponent(reference).standardizedFileURL
            return url.path.hasPrefix(root.standardizedFileURL.path + "/") ? url : nil
        }
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

// The store holds only value types and a FileManager; a capture may run on a background queue.
extension WorkspaceSnapshotStore: @unchecked Sendable {}
