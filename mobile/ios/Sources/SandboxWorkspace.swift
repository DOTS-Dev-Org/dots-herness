import Foundation

// iOS soft sandbox — mirrors `macos/DotsHarness/Sources/DotsHarnessCore/SandboxWorkspace.swift`
// but uses file-copy instead of `git worktree`. The agent works in an isolated
// directory; `exit(merge:)` copies the sandbox back to the origin checkout.
// Git branch is kept as metadata only; real merge is file-level.

public struct SandboxWorkspace: Sendable, Equatable {
    public let name: String
    public let path: String
    public let originPath: String
    public var branch: String { SandboxWorkspaces.branchPrefix + name }
}

public enum SandboxExit: Sendable, Equatable {
    case merged(commits: Int)
    case conflicted(files: [String])
    case discarded
}

public enum SandboxWorkspaces {
    public static let branchPrefix = "herness/sandbox-"

    static func root() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerNess/sandboxes", isDirectory: true)
    }

    static func directory(origin: URL, name: String) -> URL {
        // Origin hash so two repos with same sandbox name don't collide.
        let key = String(format: "%08x", UInt32(truncatingIfNeeded: origin.standardizedFileURL.path.hashValue))
        return root()
            .appendingPathComponent("\(origin.lastPathComponent)-\(key)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    static func metaFile(origin: URL, name: String) -> URL {
        root()
            .appendingPathComponent("\(origin.lastPathComponent)-\(String(format: "%08x", UInt32(truncatingIfNeeded: origin.standardizedFileURL.path.hashValue)))", isDirectory: true)
            .appendingPathComponent(".\(name).origin.json")
    }

    public static func normalized(name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(value).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? nil : String(collapsed.prefix(40))
    }

    // MARK: - Lifecycle

    public static func enter(origin originPath: String, name rawName: String) throws -> SandboxWorkspace {
        let origin = URL(fileURLWithPath: originPath, isDirectory: true)
        guard let name = normalized(name: rawName) else {
            throw SandboxError("Sandbox name is empty after normalization.")
        }
        guard FileManager.default.fileExists(atPath: origin.path) else {
            throw SandboxError("Workspace not found: \(origin.path)")
        }
        let directory = directory(origin: origin, name: name)

        if FileManager.default.fileExists(atPath: directory.path) {
            // Re-entering existing sandbox — must be a valid prior sandbox
            let marker = directory.appendingPathComponent(".herness-sandbox-marker")
            guard FileManager.default.fileExists(atPath: marker.path) else {
                throw SandboxError("\(directory.path) exists but is not a registered sandbox. Remove it and retry.")
            }
            return SandboxWorkspace(name: name, path: directory.path, originPath: origin.path)
        }

        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Snapshot origin file list before copying (for deletion tracking on merge)
        let originSnapshot = try fileList(at: origin)

        // Copy workspace to sandbox
        try copyWorkspace(from: origin, to: directory)

        // Persist origin snapshot + marker
        let marker = directory.appendingPathComponent(".herness-sandbox-marker")
        try "herness sandbox \(name)".data(using: .utf8)?.write(to: marker, options: .atomic)
        let meta = metaFile(origin: origin, name: name)
        try FileManager.default.createDirectory(at: meta.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(originSnapshot) {
            try data.write(to: meta, options: .atomic)
        }

        return SandboxWorkspace(name: name, path: directory.path, originPath: origin.path)
    }

    public static func exit(_ sandbox: SandboxWorkspace, merge: Bool) throws -> SandboxExit {
        let origin = URL(fileURLWithPath: sandbox.originPath, isDirectory: true)
        let worktree = URL(fileURLWithPath: sandbox.path, isDirectory: true)
        let meta = metaFile(origin: origin, name: sandbox.name)

        guard merge else {
            try remove(sandbox)
            try? FileManager.default.removeItem(at: meta)
            return .discarded
        }

        // Merge: copy sandbox -> origin, deleting files that were deleted in sandbox
        let originSnapshot: [String]
        if let data = try? Data(contentsOf: meta),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            originSnapshot = decoded
        } else {
            originSnapshot = (try? fileList(at: origin)) ?? []
        }

        let sandboxFiles = try fileList(at: worktree)
        let sandboxSet = Set(sandboxFiles)

        // Count commits as number of changed files for display parity
        var changed = 0

        // Copy / overwrite sandbox files to origin
        for relative in sandboxFiles {
            let src = worktree.appendingPathComponent(relative)
            let dst = origin.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dst.path) {
                // Only count as changed if content differs
                let srcData = try? Data(contentsOf: src)
                let dstData = try? Data(contentsOf: dst)
                if srcData != dstData { changed += 1 }
                try? FileManager.default.removeItem(at: dst)
            } else {
                changed += 1
            }
            try FileManager.default.copyItem(at: src, to: dst)
        }

        // Delete from origin files that existed at enter time but missing in sandbox
        for relative in originSnapshot where !sandboxSet.contains(relative) {
            let target = origin.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
                changed += 1
                // Clean up empty parent dirs (but not origin itself)
                var parent = target.deletingLastPathComponent()
                while parent.path != origin.path && parent.path.hasPrefix(origin.path) {
                    if let contents = try? FileManager.default.contentsOfDirectory(atPath: parent.path), contents.isEmpty {
                        try? FileManager.default.removeItem(at: parent)
                        parent.deleteLastPathComponent()
                    } else { break }
                }
            }
        }

        try remove(sandbox)
        try? FileManager.default.removeItem(at: meta)

        // No real git conflicts in file-copy mode — always succeeds
        return .merged(commits: changed)
    }

    public static func list(origin originPath: String) -> [SandboxWorkspace] {
        let origin = URL(fileURLWithPath: originPath, isDirectory: true)
        var result: [SandboxWorkspace] = []
        let hashDir = directory(origin: origin, name: "").deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(at: hashDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let name = entry.lastPathComponent
            if name.hasPrefix(".") { continue }
            let marker = entry.appendingPathComponent(".herness-sandbox-marker")
            guard FileManager.default.fileExists(atPath: marker.path) else { continue }
            result.append(SandboxWorkspace(name: name, path: entry.path, originPath: origin.path))
        }
        return result.sorted { $0.name < $1.name }
    }

    private static func remove(_ sandbox: SandboxWorkspace) throws {
        let worktree = URL(fileURLWithPath: sandbox.path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: worktree.path) else { return }
        try FileManager.default.removeItem(at: worktree)
        // Prune empty hash dir
        let hashDir = worktree.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: hashDir.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: hashDir)
        }
        // Also try to prune root if empty
        let rootDir = root()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: rootDir.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: rootDir)
        }
    }

    // MARK: - Helpers

    private static func copyWorkspace(from origin: URL, to destination: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: origin, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values?.isDirectory == true {
                let name = url.lastPathComponent
                if name == ".git" || name == ".mem" || name == "DerivedData" || name == "build" || name == ".build" {
                    enumerator.skipDescendants()
                    continue
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let relative = String(url.path.dropFirst(origin.path.count + 1))
            let dest = destination.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
        }
    }

    private static func fileList(at root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        var result: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values?.isDirectory == true {
                let name = url.lastPathComponent
                if name == ".git" || name.hasPrefix(".mem") || name == ".herness-sandbox-marker" {
                    enumerator.skipDescendants()
                    continue
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if url.lastPathComponent == ".herness-sandbox-marker" { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            result.append(relative)
        }
        return result.sorted()
    }
}

struct SandboxError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
