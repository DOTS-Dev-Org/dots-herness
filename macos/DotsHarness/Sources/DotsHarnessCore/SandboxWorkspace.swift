// Copyright (c) 2026 DOTS
// Sandbox workspaces: the agent works in a git worktree instead of the user's
// checkout, so the main working tree is never touched until the user merges.
//
// Isolation is git's, not ours: the worktree is a real checkout of a real
// branch, so `exit(merge:)` is a real `git merge` and conflicts are reported by
// git rather than guessed at here.

import Foundation

public struct SandboxWorkspace: Sendable, Equatable {
    /// User-facing name; also the branch and directory suffix.
    public let name: String
    /// The worktree the agent runs in.
    public let path: String
    /// The user's own checkout, restored on exit.
    public let originPath: String

    public var branch: String { SandboxWorkspaces.branchPrefix + name }
}

public enum SandboxExit: Sendable, Equatable {
    /// Merged into the origin checkout and cleaned up.
    case merged(commits: Int)
    /// Merge aborted; the sandbox is untouched and still usable.
    case conflicted(files: [String])
    /// Removed without merging.
    case discarded
}

public enum SandboxWorkspaces {
    public static let branchPrefix = "herness/sandbox-"

    /// Worktrees live outside the repository so they never show up as untracked
    /// files, never land in a `git clean`, and survive the repo being moved.
    static func root() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DotsHarness/sandboxes", isDirectory: true)
    }

    static func directory(origin: URL, name: String) -> URL {
        // The origin path is part of the key: two repos may both have "try-a".
        let key = String(format: "%08x", UInt32(truncatingIfNeeded: origin.standardizedFileURL.path.hashValue))
        return root()
            .appendingPathComponent("\(origin.lastPathComponent)-\(key)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Names are branch and directory components, so keep them boring.
    public static func normalized(name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(value).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? nil : String(collapsed.prefix(40))
    }

    // MARK: - Lifecycle

    /// Creates `<branch>` at the origin's HEAD and checks it out into its own
    /// worktree. Uncommitted changes in the origin checkout are NOT carried
    /// over — the sandbox starts from the last commit. The caller tells the
    /// user; guessing (stashing, copying) would touch the tree we promised not
    /// to touch.
    public static func enter(origin originPath: String, name rawName: String) throws -> SandboxWorkspace {
        let origin = URL(fileURLWithPath: originPath, isDirectory: true)
        guard let name = normalized(name: rawName) else {
            throw NativeAgentError("Sandbox name is empty after normalization.")
        }
        guard isGitRepository(origin) else {
            throw NativeAgentError("Sandbox needs a git repository: \(origin.path) is not one.")
        }
        let directory = directory(origin: origin, name: name)
        let branch = branchPrefix + name

        if FileManager.default.fileExists(atPath: directory.path) {
            // Re-entering an existing sandbox is the common case after a relaunch.
            guard worktrees(origin: origin).contains(directory.standardizedFileURL.path) else {
                throw NativeAgentError("\(directory.path) exists but is not a registered worktree. Remove it and retry.")
            }
            return SandboxWorkspace(name: name, path: directory.path, originPath: origin.path)
        }

        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existingBranch = git(["rev-parse", "--verify", "--quiet", branch], in: origin).status == 0
        let arguments = existingBranch
            ? ["worktree", "add", directory.path, branch]
            : ["worktree", "add", "-b", branch, directory.path]
        let result = git(arguments, in: origin)
        guard result.status == 0 else {
            throw NativeAgentError("git worktree add failed: \(result.text)")
        }
        return SandboxWorkspace(name: name, path: directory.path, originPath: origin.path)
    }

    /// Commits whatever the agent left behind, merges it into the origin
    /// checkout's current branch, and removes the worktree. Anything git
    /// refuses is reported, never worked around.
    public static func exit(_ sandbox: SandboxWorkspace, merge: Bool) throws -> SandboxExit {
        let origin = URL(fileURLWithPath: sandbox.originPath, isDirectory: true)
        let worktree = URL(fileURLWithPath: sandbox.path, isDirectory: true)

        guard merge else {
            try remove(sandbox)
            return .discarded
        }

        // A dirty origin checkout would mix the user's own edits into the merge
        // and, on conflict, leave them half-resolved. Refuse instead.
        let dirty = git(["status", "--porcelain", "--untracked-files=no"], in: origin)
        guard dirty.status == 0 else { throw NativeAgentError("git status failed: \(dirty.text)") }
        guard dirty.text.isEmpty else {
            throw NativeAgentError("Commit or stash your own changes first — merging into a dirty checkout is refused.")
        }

        commitAll(in: worktree, message: "herness sandbox: \(sandbox.name)")
        let commits = git(["rev-list", "--count", "HEAD..\(sandbox.branch)"], in: origin)
        let count = Int(commits.text) ?? 0
        guard count > 0 else {
            try remove(sandbox)
            return .merged(commits: 0)
        }

        let merged = git(["merge", "--no-ff", "-m", "Merge sandbox \(sandbox.name)", sandbox.branch], in: origin)
        if merged.status != 0 {
            let conflicted = git(["diff", "--name-only", "--diff-filter=U"], in: origin)
                .text.split(whereSeparator: \.isNewline).map(String.init)
            _ = git(["merge", "--abort"], in: origin)
            return .conflicted(files: conflicted)
        }
        try remove(sandbox)
        return .merged(commits: count)
    }

    /// Sandboxes that still exist for this origin, newest git order.
    public static func list(origin originPath: String) -> [SandboxWorkspace] {
        let origin = URL(fileURLWithPath: originPath, isDirectory: true)
        guard isGitRepository(origin) else { return [] }
        let prefix = directory(origin: origin, name: "").deletingLastPathComponent().standardizedFileURL.path
        return worktrees(origin: origin)
            .filter { $0.hasPrefix(prefix + "/") }
            .map { SandboxWorkspace(name: URL(fileURLWithPath: $0).lastPathComponent, path: $0, originPath: origin.path) }
    }

    private static func remove(_ sandbox: SandboxWorkspace) throws {
        let origin = URL(fileURLWithPath: sandbox.originPath, isDirectory: true)
        let removed = git(["worktree", "remove", "--force", sandbox.path], in: origin)
        guard removed.status == 0 else {
            throw NativeAgentError("git worktree remove failed: \(removed.text)")
        }
        // The branch is deliberately kept: it is the only record of discarded
        // work, and `git branch -D` on it would be unrecoverable.
        _ = git(["worktree", "prune"], in: origin)
    }

    private static func commitAll(in worktree: URL, message: String) {
        _ = git(["add", "--all"], in: worktree)
        let staged = git(["diff", "--cached", "--quiet"], in: worktree)
        guard staged.status != 0 else { return } // nothing staged
        _ = git(["commit", "--no-verify", "-m", message], in: worktree)
    }

    static func isGitRepository(_ url: URL) -> Bool {
        git(["rev-parse", "--git-dir"], in: url).status == 0
    }

    private static func worktrees(origin: URL) -> [String] {
        git(["worktree", "list", "--porcelain"], in: origin)
            .text.split(whereSeparator: \.isNewline)
            .compactMap { $0.hasPrefix("worktree ") ? String($0.dropFirst("worktree ".count)) : nil }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: URL) -> (status: Int32, text: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
