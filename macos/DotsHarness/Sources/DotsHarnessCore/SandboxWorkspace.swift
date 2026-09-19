// Copyright (c) 2026 DOTS
// Git worktree lifecycle for isolated agent workspaces.

import CryptoKit
import Foundation

public struct SandboxWorkspace: Sendable, Equatable {
    public let name: String
    public let path: String
    public let originPath: String
    public let originBranch: String

    public init(
        name: String,
        path: String,
        originPath: String,
        originBranch: String = ""
    ) {
        self.name = name
        self.path = path
        self.originPath = originPath
        self.originBranch = originBranch
    }

    public var branch: String { SandboxWorkspaces.branchPrefix + name }
}

public struct SandboxConflict: Sendable, Equatable {
    public let sandbox: SandboxWorkspace
    public let originBranch: String
    public let originHead: String
    public let sandboxHead: String
    public let files: [String]

    public init(
        sandbox: SandboxWorkspace,
        originBranch: String,
        originHead: String,
        sandboxHead: String,
        files: [String]
    ) {
        self.sandbox = sandbox
        self.originBranch = originBranch
        self.originHead = originHead
        self.sandboxHead = sandboxHead
        self.files = files
    }
}

public struct SandboxResolutionPreview: Sendable, Equatable {
    public let files: [String]
    public let unresolvedFiles: [String]
    public let diff: String
    public let fingerprint: String
    public let isTruncated: Bool

    public init(
        files: [String],
        unresolvedFiles: [String],
        diff: String,
        fingerprint: String,
        isTruncated: Bool
    ) {
        self.files = files
        self.unresolvedFiles = unresolvedFiles
        self.diff = diff
        self.fingerprint = fingerprint
        self.isTruncated = isTruncated
    }
}

public enum SandboxExit: Sendable, Equatable {
    case merged(commits: Int)
    case conflicted(SandboxConflict)
    case discarded
}

public enum SandboxWorkspaceError: LocalizedError, Equatable {
    case invalidRepository(String)
    case detachedOrigin
    case originDirty
    case originOperationInProgress
    case activeOperationInProgress
    case invalidSandbox(String)
    case originBranchChanged(expected: String, actual: String)
    case gitFailed(operation: String, output: String)
    case mergeAbortFailed(output: String)
    case cleanupFailed(path: String, output: String, originMerged: Bool)
    case staleResolution
    case resolutionInProgress
    case resolutionNotInProgress
    case unresolvedFiles([String])
    case unexpectedResolutionFiles([String])

    public var errorDescription: String? {
        switch self {
        case .invalidRepository(let path):
            return "Sandbox needs a git repository: \(path)"
        case .detachedOrigin:
            return "The origin checkout must be on a local branch before a sandbox can start."
        case .originDirty:
            return "Commit or stash the origin checkout's tracked and untracked changes before merging."
        case .originOperationInProgress:
            return "The origin checkout already has a merge, rebase, cherry-pick, or revert in progress."
        case .activeOperationInProgress:
            return "The sandbox cannot change state while an agent operation is still running."
        case .invalidSandbox(let message):
            return "The sandbox is no longer valid: \(message)"
        case .originBranchChanged(let expected, let actual):
            return "The origin branch changed from \(expected) to \(actual)."
        case .gitFailed(let operation, let output):
            return "git \(operation) failed\(output.isEmpty ? "" : ": \(output)")"
        case .mergeAbortFailed(let output):
            return "git merge --abort failed. The origin was not declared safe\(output.isEmpty ? "" : ": \(output)")"
        case .cleanupFailed(let path, let output, let originMerged):
            let state = originMerged ? "The merge was applied, but cleanup is still pending" : "The sandbox was not removed"
            return "\(state) at \(path)\(output.isEmpty ? "" : ": \(output)")"
        case .staleResolution:
            return "The sandbox or origin changed after the resolution preview. Create a new preview."
        case .resolutionInProgress:
            return "A sandbox conflict resolution is in progress. Preview and approve it before merging."
        case .resolutionNotInProgress:
            return "There is no sandbox merge resolution in progress."
        case .unresolvedFiles(let files):
            return "Unresolved conflict files remain: \(files.joined(separator: ", "))"
        case .unexpectedResolutionFiles(let files):
            return "The resolution changed files outside the conflict: \(files.joined(separator: ", "))"
        }
    }
}

public enum SandboxWorkspaces {
    public static let branchPrefix = "herness/sandbox-"

    private static let previewLimit = 512_000

    private struct GitResult {
        let status: Int32
        let text: String
        let data: Data
    }

    private struct WorktreeRecord {
        let path: String
        let branch: String?
    }

    private struct Context {
        let sandbox: SandboxWorkspace
        let origin: URL
        let worktree: URL
        let originBranch: String
        let gitMetadataRoots: [URL]
    }

    /// Keep worktrees outside the checkout so an agent cannot accidentally add
    /// them to the user's repository and they survive the repository moving.
    static func root() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DotsHarness/sandboxes", isDirectory: true)
    }

    static func directory(origin: URL, name: String) -> URL {
        let normalized = normalize(origin)
        let digest = SHA256.hash(data: Data(normalized.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
        return root()
            .appendingPathComponent("\(normalized.lastPathComponent)-\(digest)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    public static func normalized(name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(value).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? nil : String(collapsed.prefix(40))
    }

    // MARK: Lifecycle

    public static func enter(origin originPath: String, name rawName: String) throws -> SandboxWorkspace {
        guard SandboxProfile.isAvailable else { throw SandboxProfileError.unavailable }
        let origin = normalize(URL(fileURLWithPath: originPath, isDirectory: true))
        guard let name = normalized(name: rawName) else {
            throw SandboxWorkspaceError.invalidSandbox("The name is empty after normalization.")
        }
        guard isGitRepository(origin) else {
            throw SandboxWorkspaceError.invalidRepository(origin.path)
        }
        let originBranch = try currentBranch(in: origin)
        let directory = directory(origin: origin, name: name)
        let sandbox = SandboxWorkspace(
            name: name,
            path: directory.path,
            originPath: origin.path,
            originBranch: originBranch
        )

        if FileManager.default.fileExists(atPath: directory.path) {
            _ = try context(for: sandbox)
            return sandbox
        }

        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let branchExists = git(["rev-parse", "--verify", "--quiet", sandbox.branch], in: origin).status == 0
        let arguments = branchExists
            ? ["worktree", "add", directory.path, sandbox.branch]
            : ["worktree", "add", "-b", sandbox.branch, directory.path]
        let result = try runGit(
            arguments,
            in: origin,
            writableRoots: [
                origin,
                directory,
                origin.appendingPathComponent(".git", isDirectory: true),
            ]
        )
        guard result.status == 0 else {
            throw SandboxWorkspaceError.gitFailed(operation: "worktree add", output: result.text)
        }
        return sandbox
    }

    public static func restore(
        origin originPath: String,
        path sandboxPath: String,
        name rawName: String? = nil,
        originBranch storedOriginBranch: String? = nil
    ) throws -> SandboxWorkspace {
        guard SandboxProfile.isAvailable else { throw SandboxProfileError.unavailable }
        let origin = normalize(URL(fileURLWithPath: originPath, isDirectory: true))
        let path = normalize(URL(fileURLWithPath: sandboxPath, isDirectory: true))
        guard isGitRepository(origin) else {
            throw SandboxWorkspaceError.invalidRepository(origin.path)
        }
        let name = normalized(name: rawName ?? path.lastPathComponent) ?? path.lastPathComponent
        let originBranch = try currentBranch(in: origin)
        if let storedOriginBranch, !storedOriginBranch.isEmpty, storedOriginBranch != originBranch {
            throw SandboxWorkspaceError.originBranchChanged(expected: storedOriginBranch, actual: originBranch)
        }
        let sandbox = SandboxWorkspace(
            name: name,
            path: path.path,
            originPath: origin.path,
            originBranch: originBranch
        )
        _ = try context(for: sandbox)
        return sandbox
    }

    public static func exit(_ sandbox: SandboxWorkspace, merge: Bool) throws -> SandboxExit {
        let context = try context(for: sandbox)
        if !merge {
            try discardResolutionIfNeeded(context)
            try remove(context, originMerged: false)
            return .discarded
        }

        try ensureOriginReady(context)
        guard try mergeHead(in: context.worktree) == nil else {
            throw SandboxWorkspaceError.resolutionInProgress
        }
        try commitAll(context, message: "herness sandbox: \(sandbox.name)")

        let originHead = try revision("HEAD", in: context.origin)
        let sandboxHead = try revision("refs/heads/\(sandbox.branch)", in: context.origin)
        let commits = try commitCount(context)
        guard commits > 0 else {
            try remove(context, originMerged: false)
            return .merged(commits: 0)
        }

        let merged = try runGit(
            ["merge", "--no-ff", "--no-verify", "-m", "Merge sandbox \(sandbox.name)", sandbox.branch],
            in: context.origin,
            writableRoots: context.gitMetadataRoots + [context.origin, context.worktree]
        )
        guard merged.status == 0 else {
            let files = try unmergedFiles(in: context.origin)
            if !files.isEmpty {
                try abortOriginMerge(context, expectedHead: originHead)
                return .conflicted(SandboxConflict(
                    sandbox: sandbox,
                    originBranch: context.originBranch,
                    originHead: originHead,
                    sandboxHead: sandboxHead,
                    files: files
                ))
            }
            try abortOriginMergeIfNeeded(context, expectedHead: originHead)
            throw SandboxWorkspaceError.gitFailed(operation: "merge", output: merged.text)
        }

        try remove(context, originMerged: true)
        return .merged(commits: commits)
    }

    /// Prepares the same merge in the sandbox, leaving its conflict state there
    /// for a user or the agent to resolve. The origin is read-only in this path.
    public static func prepareResolution(_ conflict: SandboxConflict) throws {
        let context = try context(for: conflict.sandbox)
        try ensureOriginReady(context)
        if !conflict.originBranch.isEmpty, conflict.originBranch != context.originBranch {
            throw SandboxWorkspaceError.staleResolution
        }
        guard try revision("HEAD", in: context.origin) == conflict.originHead else {
            throw SandboxWorkspaceError.staleResolution
        }
        guard try revision("HEAD", in: context.worktree) == conflict.sandboxHead else {
            throw SandboxWorkspaceError.staleResolution
        }

        if let mergeHead = try mergeHead(in: context.worktree) {
            guard mergeHead == conflict.originHead else { throw SandboxWorkspaceError.staleResolution }
            return
        }

        let status = try runGit(["status", "--porcelain", "--untracked-files=all"], in: context.worktree)
        guard status.status == 0, status.text.isEmpty else {
            throw SandboxWorkspaceError.invalidSandbox("The sandbox must be clean before preparing conflict resolution.")
        }

        let result = try runGit(
            ["merge", "--no-ff", "--no-commit", "--no-verify", conflict.originHead],
            in: context.worktree,
            writableRoots: context.gitMetadataRoots + [context.worktree]
        )
        if result.status != 0 {
            let files = try unmergedFiles(in: context.worktree)
            guard !files.isEmpty else {
                try abortSandboxMerge(context)
                throw SandboxWorkspaceError.gitFailed(operation: "prepare resolution", output: result.text)
            }
        }
    }

    public static func previewResolution(_ conflict: SandboxConflict) throws -> SandboxResolutionPreview {
        let context = try context(for: conflict.sandbox)
        try ensureResolutionIsCurrent(context, conflict: conflict)
        try stageAll(context)

        var unresolved = Set(try unmergedFiles(in: context.worktree))
        let files = try stagedFiles(in: context.worktree)
        for file in files where try containsConflictMarkers(file, in: context.worktree) {
            unresolved.insert(file)
        }
        let diff = try runGit(
            ["diff", "--cached", "--binary", "--no-color"],
            in: context.worktree,
            writableRoots: context.gitMetadataRoots + [context.worktree]
        )
        guard diff.status == 0 else {
            throw SandboxWorkspaceError.gitFailed(operation: "diff", output: diff.text)
        }

        let fingerprint = try resolutionFingerprint(context)
        let diffText = String(decoding: diff.data.prefix(previewLimit), as: UTF8.self)
        return SandboxResolutionPreview(
            files: files,
            unresolvedFiles: unresolved.sorted(),
            diff: diffText,
            fingerprint: fingerprint,
            isTruncated: diff.data.count > previewLimit
        )
    }

    public static func cancelResolution(_ conflict: SandboxConflict) throws {
        let context = try context(for: conflict.sandbox)
        try ensureOriginReady(context)
        if !conflict.originBranch.isEmpty, conflict.originBranch != context.originBranch {
            throw SandboxWorkspaceError.staleResolution
        }
        guard try revision("HEAD", in: context.origin) == conflict.originHead else {
            throw SandboxWorkspaceError.staleResolution
        }
        guard try revision("HEAD", in: context.worktree) == conflict.sandboxHead else {
            throw SandboxWorkspaceError.staleResolution
        }
        guard try mergeHead(in: context.worktree) != nil else {
            throw SandboxWorkspaceError.resolutionNotInProgress
        }
        try abortSandboxMerge(context)
    }

    public static func applyResolution(
        _ conflict: SandboxConflict,
        expectedFingerprint: String
    ) throws -> SandboxExit {
        let context = try context(for: conflict.sandbox)
        try ensureResolutionIsCurrent(context, conflict: conflict)
        let preview = try previewResolution(conflict)
        guard preview.fingerprint == expectedFingerprint else {
            throw SandboxWorkspaceError.staleResolution
        }
        guard preview.unresolvedFiles.isEmpty else {
            throw SandboxWorkspaceError.unresolvedFiles(preview.unresolvedFiles)
        }
        let unexpected = preview.files.filter { !conflict.files.contains($0) }
        guard unexpected.isEmpty else {
            throw SandboxWorkspaceError.unexpectedResolutionFiles(unexpected)
        }

        let committed = try runGit(
            ["commit", "--no-verify", "-m", "Resolve sandbox merge \(conflict.sandbox.name)"],
            in: context.worktree,
            writableRoots: context.gitMetadataRoots + [context.worktree]
        )
        guard committed.status == 0 else {
            throw SandboxWorkspaceError.gitFailed(operation: "commit resolution", output: committed.text)
        }
        return try exit(conflict.sandbox, merge: true)
    }

    /// Sandboxes that still exist for this origin.
    public static func list(origin originPath: String) -> [SandboxWorkspace] {
        let origin = normalize(URL(fileURLWithPath: originPath, isDirectory: true))
        guard isGitRepository(origin) else { return [] }
        let parent = directory(origin: origin, name: "").deletingLastPathComponent().standardizedFileURL.path
        let originBranch = (try? currentBranch(in: origin)) ?? ""
        return (try? worktreeRecords(in: origin))?
            .filter { $0.path.hasPrefix(parent + "/") }
            .compactMap { record in
                guard let branch = record.branch,
                      branch.hasPrefix("refs/heads/\(branchPrefix)") else { return nil }
                let name = String(branch.dropFirst("refs/heads/\(branchPrefix)".count))
                return SandboxWorkspace(
                    name: name,
                    path: record.path,
                    originPath: origin.path,
                    originBranch: originBranch
                )
            } ?? []
    }

    public static func isGitRepository(_ url: URL) -> Bool {
        guard let result = try? runGit(["rev-parse", "--git-dir"], in: normalize(url)) else {
            return false
        }
        return result.status == 0
    }

    /// Re-checks the origin before clearing a recovery-required state. This is
    /// intentionally read-only; the user must repair any interrupted git
    /// operation manually before normal sandbox actions become available.
    public static func validateReady(_ sandbox: SandboxWorkspace) throws {
        let context = try context(for: sandbox)
        try ensureOriginReady(context)
    }

    /// Retries only the cleanup step. This remains safe when `worktree remove`
    /// already succeeded but its following prune failed.
    public static func retryCleanup(_ sandbox: SandboxWorkspace, originMerged: Bool) throws {
        let origin = normalize(URL(fileURLWithPath: sandbox.originPath, isDirectory: true))
        guard isGitRepository(origin) else {
            throw SandboxWorkspaceError.invalidRepository(origin.path)
        }
        let originBranch = try currentBranch(in: origin)
        if !sandbox.originBranch.isEmpty, sandbox.originBranch != originBranch {
            throw SandboxWorkspaceError.originBranchChanged(expected: sandbox.originBranch, actual: originBranch)
        }
        let worktree = normalize(URL(fileURLWithPath: sandbox.path, isDirectory: true))
        if FileManager.default.fileExists(atPath: worktree.path) {
            try remove(try context(for: sandbox), originMerged: originMerged)
            return
        }

        let records = try worktreeRecords(in: origin)
        if let record = records.first(where: { $0.path == worktree.path }),
           record.branch != "refs/heads/\(sandbox.branch)" {
            throw SandboxWorkspaceError.cleanupFailed(
                path: worktree.path,
                output: "The registered worktree branch does not match the sandbox branch.",
                originMerged: originMerged
            )
        }
        let prune = try runGit(
            ["worktree", "prune"],
            in: origin,
            writableRoots: try gitMetadataRoots(origin: origin, worktree: origin)
        )
        guard prune.status == 0 else {
            throw SandboxWorkspaceError.cleanupFailed(
                path: worktree.path,
                output: prune.text,
                originMerged: originMerged
            )
        }
        guard !(try worktreeRecords(in: origin)).contains(where: { $0.path == worktree.path }) else {
            throw SandboxWorkspaceError.cleanupFailed(
                path: worktree.path,
                output: "Git still registers the sandbox worktree after prune.",
                originMerged: originMerged
            )
        }
    }

    // MARK: Git validation

    private static func context(for sandbox: SandboxWorkspace) throws -> Context {
        let origin = normalize(URL(fileURLWithPath: sandbox.originPath, isDirectory: true))
        let worktree = normalize(URL(fileURLWithPath: sandbox.path, isDirectory: true))
        guard isGitRepository(origin) else {
            throw SandboxWorkspaceError.invalidRepository(origin.path)
        }
        guard FileManager.default.fileExists(atPath: worktree.path) else {
            throw SandboxWorkspaceError.invalidSandbox("The worktree path no longer exists.")
        }

        let originBranch = try currentBranch(in: origin)
        if !sandbox.originBranch.isEmpty, sandbox.originBranch != originBranch {
            throw SandboxWorkspaceError.originBranchChanged(expected: sandbox.originBranch, actual: originBranch)
        }

        let records = try worktreeRecords(in: origin)
        guard let record = records.first(where: { $0.path == worktree.path }) else {
            throw SandboxWorkspaceError.invalidSandbox("The path is not registered by git worktree.")
        }
        guard record.branch == "refs/heads/\(sandbox.branch)" else {
            let checkedOut = record.branch ?? "no branch"
            throw SandboxWorkspaceError.invalidSandbox("The worktree is checked out on \(checkedOut), not \(sandbox.branch).")
        }
        guard try currentBranch(in: worktree) == sandbox.branch else {
            throw SandboxWorkspaceError.invalidSandbox("The sandbox branch does not match its worktree.")
        }

        return Context(
            sandbox: sandbox,
            origin: origin,
            worktree: worktree,
            originBranch: originBranch,
            gitMetadataRoots: try gitMetadataRoots(origin: origin, worktree: worktree)
        )
    }

    private static func ensureOriginReady(_ context: Context) throws {
        guard try currentBranch(in: context.origin) == context.originBranch else {
            throw SandboxWorkspaceError.originBranchChanged(
                expected: context.originBranch,
                actual: (try? currentBranch(in: context.origin)) ?? "<unknown>"
            )
        }
        guard !hasGitOperation(in: context.origin) else {
            throw SandboxWorkspaceError.originOperationInProgress
        }
        let status = try runGit(
            ["status", "--porcelain", "--untracked-files=all"],
            in: context.origin
        )
        guard status.status == 0 else {
            throw SandboxWorkspaceError.gitFailed(operation: "status", output: status.text)
        }
        guard status.text.isEmpty else { throw SandboxWorkspaceError.originDirty }
    }

    private static func commitAll(_ context: Context, message: String) throws {
        let add = try runGit(
            ["add", "--all", "--", ".", ":(exclude).mem", ":(exclude).mem/**"],
            in: context.worktree,
            writableRoots: context.gitMetadataRoots + [context.worktree]
        )
        guard add.status == 0 else {
            throw SandboxWorkspaceError.gitFailed(operation: "add", output: add.text)
        }

        let staged = try runGit(
            ["diff", "--cached", "--quiet"],
            in: context.worktree,
            writableRoots: context.gitMetadataRoots + [context.worktree]
        )
        guard staged.status == 0 || staged.status == 1 else {
            throw SandboxWorkspaceError.gitFailed(operation: "diff --cached", output: staged.text)
        }
        guard staged.status == 1 else { return }

        let commit = try runGit(
            ["commit", "--no-verify", "-m", message],
            in: context.worktree,
            writableRoots: context.gitMetadataRoots + [context.worktree]
        )
        guard commit.status == 0 else {
            throw SandboxWorkspaceError.gitFailed(operation: "commit", output: commit.text)
        }
    }

    private static func stageAll(_ context: Context) throws {
        let result = try runGit(
            ["add", "--all", "--", ".", ":(exclude).mem", ":(exclude).mem/**"],
            in: context.worktree,
            writableRoots: context.gitMetadataRoots + [context.worktree]
        )
        guard result.status == 0 else {
            throw SandboxWorkspaceError.gitFailed(operation: "add resolution", output: result.text)
        }
    }

    private static func commitCount(_ context: Context) throws -> Int {
        let result = try runGit(
            ["rev-list", "--count", "HEAD..refs/heads/\(context.sandbox.branch)"],
            in: context.origin
        )
        guard result.status == 0, let count = Int(result.text.trimmingCharacters(in: .whitespacesAndNewlines)), count >= 0 else {
            throw SandboxWorkspaceError.gitFailed(operation: "rev-list", output: result.text)
        }
        return count
    }

    private static func remove(_ context: Context, originMerged: Bool) throws {
        let result = try runGit(
            ["worktree", "remove", "--force", context.worktree.path],
            in: context.origin,
            writableRoots: context.gitMetadataRoots + [context.worktree]
        )
        guard result.status == 0 else {
            throw SandboxWorkspaceError.cleanupFailed(
                path: context.worktree.path,
                output: result.text,
                originMerged: originMerged
            )
        }

        let prune = try runGit(
            ["worktree", "prune"],
            in: context.origin,
            writableRoots: context.gitMetadataRoots
        )
        guard prune.status == 0 else {
            throw SandboxWorkspaceError.cleanupFailed(
                path: context.worktree.path,
                output: prune.text,
                originMerged: originMerged
            )
        }
    }

    private static func abortOriginMerge(_ context: Context, expectedHead: String) throws {
        let result = try runGit(
            ["merge", "--abort"],
            in: context.origin,
            writableRoots: context.gitMetadataRoots + [context.origin, context.worktree]
        )
        guard result.status == 0 else { throw SandboxWorkspaceError.mergeAbortFailed(output: result.text) }
        try verifyOriginRestored(context, expectedHead: expectedHead)
    }

    private static func abortOriginMergeIfNeeded(_ context: Context, expectedHead: String) throws {
        guard hasGitOperation(in: context.origin) else { return }
        try abortOriginMerge(context, expectedHead: expectedHead)
    }

    private static func abortSandboxMerge(_ context: Context) throws {
        let result = try runGit(
            ["merge", "--abort"],
            in: context.worktree,
            writableRoots: context.gitMetadataRoots + [context.worktree]
        )
        guard result.status == 0 else { throw SandboxWorkspaceError.mergeAbortFailed(output: result.text) }
        let status = try runGit(["status", "--porcelain", "--untracked-files=all"], in: context.worktree)
        guard status.status == 0, status.text.isEmpty else {
            throw SandboxWorkspaceError.gitFailed(operation: "verify sandbox abort", output: status.text)
        }
    }

    private static func discardResolutionIfNeeded(_ context: Context) throws {
        if try mergeHead(in: context.worktree) != nil {
            try abortSandboxMerge(context)
        }
    }

    private static func verifyOriginRestored(_ context: Context, expectedHead: String) throws {
        guard try revision("HEAD", in: context.origin) == expectedHead else {
            throw SandboxWorkspaceError.mergeAbortFailed(output: "HEAD changed during merge abort.")
        }
        guard !hasGitOperation(in: context.origin) else {
            throw SandboxWorkspaceError.mergeAbortFailed(output: "MERGE_HEAD or another git operation remains.")
        }
        let status = try runGit(["status", "--porcelain", "--untracked-files=all"], in: context.origin)
        guard status.status == 0, status.text.isEmpty else {
            throw SandboxWorkspaceError.mergeAbortFailed(output: status.text)
        }
    }

    private static func ensureResolutionIsCurrent(_ context: Context, conflict: SandboxConflict) throws {
        try ensureOriginReady(context)
        if !conflict.originBranch.isEmpty, conflict.originBranch != context.originBranch {
            throw SandboxWorkspaceError.staleResolution
        }
        guard try revision("HEAD", in: context.origin) == conflict.originHead else {
            throw SandboxWorkspaceError.staleResolution
        }
        guard try revision("HEAD", in: context.worktree) == conflict.sandboxHead else {
            throw SandboxWorkspaceError.staleResolution
        }
        guard try mergeHead(in: context.worktree) == conflict.originHead else {
            throw SandboxWorkspaceError.resolutionNotInProgress
        }
    }

    private static func resolutionFingerprint(_ context: Context) throws -> String {
        let originHead = try revision("HEAD", in: context.origin)
        let head = try revision("HEAD", in: context.worktree)
        let status = try runGit(
            ["status", "--porcelain", "--untracked-files=all"],
            in: context.worktree
        )
        guard status.status == 0 else {
            throw SandboxWorkspaceError.gitFailed(operation: "status resolution", output: status.text)
        }
        let diff = try runGit(
            ["diff", "--cached", "--binary", "--no-color"],
            in: context.worktree,
            writableRoots: context.gitMetadataRoots + [context.worktree]
        )
        guard diff.status == 0 else {
            throw SandboxWorkspaceError.gitFailed(operation: "fingerprint", output: diff.text)
        }
        var data = Data("origin:\(originHead)\n".utf8)
        data.append(Data("sandbox:\(head)\n".utf8))
        data.append(Data("status:\(status.text)\n".utf8))
        data.append(0)
        data.append(diff.data)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func unmergedFiles(in directory: URL) throws -> [String] {
        let result = try runGit(["diff", "--name-only", "--diff-filter=U", "-z"], in: directory)
        guard result.status == 0 else {
            throw SandboxWorkspaceError.gitFailed(operation: "diff unmerged", output: result.text)
        }
        return String(decoding: result.data, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
            .sorted()
    }

    private static func containsConflictMarkers(_ path: String, in directory: URL) throws -> Bool {
        let root = normalize(directory).path
        let file = URL(fileURLWithPath: path, relativeTo: directory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard file.path.hasPrefix(root + "/") else {
            return true
        }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return false
        }
        let markers = ["<<<<<<<", "=======", ">>>>>>>"]
        let lines = text.split(whereSeparator: \.isNewline)
        return markers.allSatisfy { marker in
            lines.contains { $0.hasPrefix(marker) }
        }
    }

    private static func stagedFiles(in directory: URL) throws -> [String] {
        let result = try runGit(["diff", "--cached", "--name-only", "-z"], in: directory)
        guard result.status == 0 else {
            throw SandboxWorkspaceError.gitFailed(operation: "diff --cached names", output: result.text)
        }
        return String(decoding: result.data, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
            .sorted()
    }

    private static func revision(_ name: String, in directory: URL) throws -> String {
        let result = try runGit(["rev-parse", "--verify", name], in: directory)
        guard result.status == 0, !result.text.isEmpty else {
            throw SandboxWorkspaceError.gitFailed(operation: "rev-parse \(name)", output: result.text)
        }
        return result.text
    }

    private static func currentBranch(in directory: URL) throws -> String {
        let result = try runGit(["branch", "--show-current"], in: directory)
        guard result.status == 0 else {
            throw SandboxWorkspaceError.gitFailed(operation: "branch --show-current", output: result.text)
        }
        let branch = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { throw SandboxWorkspaceError.detachedOrigin }
        return branch
    }

    private static func mergeHead(in directory: URL) throws -> String? {
        let result = try runGit(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], in: directory)
        return result.status == 0 ? result.text : nil
    }

    private static func hasGitOperation(in directory: URL) -> Bool {
        if let merge = try? mergeHead(in: directory), !merge.isEmpty { return true }
        for name in ["rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD"] {
            guard let result = try? runGit(["rev-parse", "--git-path", name], in: directory), result.status == 0 else { continue }
            let path = URL(fileURLWithPath: result.text, relativeTo: directory)
                .standardizedFileURL
                .path
            if FileManager.default.fileExists(atPath: path) { return true }
        }
        return false
    }

    private static func worktreeRecords(in origin: URL) throws -> [WorktreeRecord] {
        let result = try runGit(["worktree", "list", "--porcelain"], in: origin)
        guard result.status == 0 else {
            throw SandboxWorkspaceError.gitFailed(operation: "worktree list", output: result.text)
        }

        var records: [WorktreeRecord] = []
        var path: String?
        var branch: String?
        func appendRecord() {
            guard let path else { return }
            records.append(WorktreeRecord(
                path: normalize(URL(fileURLWithPath: path, isDirectory: true)).path,
                branch: branch
            ))
        }

        for line in result.text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("worktree ") {
                appendRecord()
                path = String(line.dropFirst("worktree ".count))
                branch = nil
            } else if line.hasPrefix("branch ") {
                branch = String(line.dropFirst("branch ".count))
            }
        }
        appendRecord()
        return records
    }

    /// Writable roots an agent process needs alongside the worktree itself:
    /// the worktree's own `.git/worktrees/<name>` metadata plus the shared
    /// object database in the origin's `.git`. `git commit` inside the
    /// worktree writes both. This never includes the origin's working-tree
    /// files — only its `.git` directory — so the origin checkout the user
    /// sees stays untouched by anything the sandboxed process does.
    public static func agentWritableRoots(for sandbox: SandboxWorkspace) throws -> [URL] {
        try gitMetadataRoots(
            origin: URL(fileURLWithPath: sandbox.originPath, isDirectory: true),
            worktree: URL(fileURLWithPath: sandbox.path, isDirectory: true)
        )
    }

    private static func gitMetadataRoots(origin: URL, worktree: URL) throws -> [URL] {
        var roots: [URL] = []
        for directory in [origin, worktree] {
            for flag in ["--git-dir", "--git-common-dir"] {
                let result = try runGit(["rev-parse", flag], in: directory)
                guard result.status == 0, !result.text.isEmpty else {
                    throw SandboxWorkspaceError.gitFailed(operation: "rev-parse \(flag)", output: result.text)
                }
                roots.append(URL(fileURLWithPath: result.text, relativeTo: directory))
            }
        }

        var seen = Set<String>()
        return roots.map { normalize($0) }.filter { seen.insert($0.path).inserted }
    }

    private static func normalize(_ url: URL) -> URL {
        SandboxProfile.canonicalURL(url)
    }

    // MARK: Process execution

    private static func runGit(
        _ arguments: [String],
        in directory: URL,
        writableRoots: [URL]? = nil
    ) throws -> GitResult {
        let process = Process()
        let output = Pipe()
        if let writableRoots {
            process.executableURL = SandboxProfile.executableURL
            process.arguments = try SandboxProfile.lifecycleArguments(
                executable: "/usr/bin/env",
                arguments: ["git"] + arguments,
                workspaceURL: directory,
                writableRoots: writableRoots
            )
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
        }
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw SandboxWorkspaceError.gitFailed(operation: arguments.first ?? "command", output: error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GitResult(status: process.terminationStatus, text: text, data: data)
    }

    @discardableResult
    public static func git(_ arguments: [String], in directory: URL) -> (status: Int32, text: String) {
        guard let result = try? runGit(arguments, in: directory) else {
            return (-1, "git could not be started")
        }
        return (result.status, result.text)
    }
}
