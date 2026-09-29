// Copyright (c) 2026 DOTS
// Git worktree lifecycle for isolated agent workspaces. Port of the macOS
// SandboxWorkspace.swift for the Windows and Linux shells.
//
// Difference from macOS: git lifecycle commands run as ordinary child processes.
// macOS wraps them in a sandbox-exec profile; there is no equivalent seatbelt
// here, and these commands are invoked by the app itself, never by the agent.

using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using PluginRuntime;

namespace DotsHarnessCore;

public sealed record SandboxWorkspace(string Name, string Path, string OriginPath, string OriginBranch = "")
{
    public string Branch => SandboxWorkspaces.BranchPrefix + Name;
}

public sealed record SandboxConflict(
    SandboxWorkspace Sandbox,
    string OriginBranch,
    string OriginHead,
    string SandboxHead,
    IReadOnlyList<string> Files);

public sealed record SandboxResolutionPreview(
    IReadOnlyList<string> Files,
    IReadOnlyList<string> UnresolvedFiles,
    string Diff,
    string Fingerprint,
    bool IsTruncated);

public abstract record SandboxExit
{
    public sealed record Merged(int Commits) : SandboxExit;
    public sealed record Conflicted(SandboxConflict Conflict) : SandboxExit;
    public sealed record Discarded : SandboxExit;
}

public enum SandboxWorkspaceErrorKind
{
    InvalidRepository,
    DetachedOrigin,
    OriginDirty,
    OriginOperationInProgress,
    ActiveOperationInProgress,
    InvalidSandbox,
    OriginBranchChanged,
    GitFailed,
    MergeAbortFailed,
    CleanupFailed,
    StaleResolution,
    ResolutionInProgress,
    ResolutionNotInProgress,
    UnresolvedFiles,
    UnexpectedResolutionFiles,
}

public sealed class SandboxWorkspaceException : Exception
{
    public SandboxWorkspaceErrorKind Kind { get; }

    /// <summary>For <see cref="SandboxWorkspaceErrorKind.CleanupFailed"/>: whether the merge already landed.</summary>
    public bool OriginMerged { get; }

    public SandboxWorkspaceException(SandboxWorkspaceErrorKind kind, string message, bool originMerged = false)
        : base(message)
    {
        Kind = kind;
        OriginMerged = originMerged;
    }

    internal static SandboxWorkspaceException InvalidRepository(string path) =>
        new(SandboxWorkspaceErrorKind.InvalidRepository, $"Sandbox needs a git repository: {path}");

    internal static SandboxWorkspaceException InvalidSandbox(string message) =>
        new(SandboxWorkspaceErrorKind.InvalidSandbox, $"The sandbox is no longer valid: {message}");

    internal static SandboxWorkspaceException GitFailed(string operation, string output) =>
        new(SandboxWorkspaceErrorKind.GitFailed, $"git {operation} failed{(output.Length == 0 ? "" : ": " + output)}");

    internal static SandboxWorkspaceException BranchChanged(string expected, string actual) =>
        new(SandboxWorkspaceErrorKind.OriginBranchChanged, $"The origin branch changed from {expected} to {actual}.");

    internal static SandboxWorkspaceException MergeAbortFailed(string output) =>
        new(SandboxWorkspaceErrorKind.MergeAbortFailed,
            $"git merge --abort failed. The origin was not declared safe{(output.Length == 0 ? "" : ": " + output)}");

    internal static SandboxWorkspaceException CleanupFailed(string path, string output, bool originMerged) =>
        new(SandboxWorkspaceErrorKind.CleanupFailed,
            $"{(originMerged ? "The merge was applied, but cleanup is still pending" : "The sandbox was not removed")} at {path}{(output.Length == 0 ? "" : ": " + output)}",
            originMerged);

    internal static SandboxWorkspaceException Stale() =>
        new(SandboxWorkspaceErrorKind.StaleResolution,
            "The sandbox or origin changed after the resolution preview. Create a new preview.");
}

public static class SandboxWorkspaces
{
    public const string BranchPrefix = "herness/sandbox-";

    private const int PreviewLimit = 512_000;

    private sealed record GitResult(int Status, string Text, byte[] Data);

    private sealed record WorktreeRecord(string Path, string? Branch);

    private sealed record Context(
        SandboxWorkspace Sandbox,
        string Origin,
        string Worktree,
        string OriginBranch,
        IReadOnlyList<string> GitMetadataRoots);

    private static readonly StringComparison PathComparison =
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    /// <summary>Worktrees live outside the checkout so an agent cannot add them to the user's repository.</summary>
    internal static string Root(string? supportRoot = null) =>
        System.IO.Path.Combine(supportRoot ?? SupportPaths.Default().Root, "sandboxes");

    internal static string Directory(string origin, string name, string? supportRoot = null)
    {
        var normalized = Normalize(origin);
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(normalized))).ToLowerInvariant()[..16];
        return System.IO.Path.Combine(
            Root(supportRoot),
            $"{System.IO.Path.GetFileName(normalized)}-{digest}",
            name);
    }

    public static string? Normalized(string name)
    {
        var mapped = new string(name.Trim().ToLowerInvariant().Select(c => char.IsLetterOrDigit(c) ? c : '-').ToArray());
        var collapsed = string.Join("-", mapped.Split('-', StringSplitOptions.RemoveEmptyEntries));
        return collapsed.Length == 0 ? null : collapsed[..Math.Min(40, collapsed.Length)];
    }

    // MARK: Lifecycle

    public static SandboxWorkspace Enter(string originPath, string rawName, string? supportRoot = null)
    {
        var origin = Normalize(originPath);
        var name = Normalized(rawName)
            ?? throw SandboxWorkspaceException.InvalidSandbox("The name is empty after normalization.");
        if (!IsGitRepository(origin)) throw SandboxWorkspaceException.InvalidRepository(origin);
        var originBranch = CurrentBranch(origin);
        var directory = Directory(origin, name, supportRoot);
        var sandbox = new SandboxWorkspace(name, directory, origin, originBranch);

        if (System.IO.Directory.Exists(directory))
        {
            _ = ContextFor(sandbox);
            return sandbox;
        }

        System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(directory)!);
        var branchExists = RunGit(new[] { "rev-parse", "--verify", "--quiet", sandbox.Branch }, origin).Status == 0;
        var arguments = branchExists
            ? new[] { "worktree", "add", directory, sandbox.Branch }
            : new[] { "worktree", "add", "-b", sandbox.Branch, directory };
        var result = RunGit(arguments, origin);
        if (result.Status != 0) throw SandboxWorkspaceException.GitFailed("worktree add", result.Text);
        return sandbox;
    }

    public static SandboxWorkspace Restore(
        string originPath, string sandboxPath, string? rawName = null, string? storedOriginBranch = null)
    {
        var origin = Normalize(originPath);
        var path = Normalize(sandboxPath);
        if (!IsGitRepository(origin)) throw SandboxWorkspaceException.InvalidRepository(origin);
        var name = Normalized(rawName ?? System.IO.Path.GetFileName(path)) ?? System.IO.Path.GetFileName(path);
        var originBranch = CurrentBranch(origin);
        if (!string.IsNullOrEmpty(storedOriginBranch) && storedOriginBranch != originBranch)
            throw SandboxWorkspaceException.BranchChanged(storedOriginBranch, originBranch);
        var sandbox = new SandboxWorkspace(name, path, origin, originBranch);
        _ = ContextFor(sandbox);
        return sandbox;
    }

    public static SandboxExit Exit(SandboxWorkspace sandbox, bool merge)
    {
        var context = ContextFor(sandbox);
        if (!merge)
        {
            DiscardResolutionIfNeeded(context);
            Remove(context, originMerged: false);
            return new SandboxExit.Discarded();
        }

        EnsureOriginReady(context);
        if (MergeHead(context.Worktree) is not null)
            throw new SandboxWorkspaceException(SandboxWorkspaceErrorKind.ResolutionInProgress,
                "A sandbox conflict resolution is in progress. Preview and approve it before merging.");
        CommitAll(context, $"herness sandbox: {sandbox.Name}");

        var originHead = Revision("HEAD", context.Origin);
        var sandboxHead = Revision($"refs/heads/{sandbox.Branch}", context.Origin);
        var commits = CommitCount(context);
        if (commits == 0)
        {
            Remove(context, originMerged: false);
            return new SandboxExit.Merged(0);
        }

        var merged = RunGit(
            new[] { "merge", "--no-ff", "--no-verify", "-m", $"Merge sandbox {sandbox.Name}", sandbox.Branch },
            context.Origin);
        if (merged.Status != 0)
        {
            var files = UnmergedFiles(context.Origin);
            if (files.Count > 0)
            {
                AbortOriginMerge(context, originHead);
                return new SandboxExit.Conflicted(new SandboxConflict(
                    sandbox, context.OriginBranch, originHead, sandboxHead, files));
            }
            AbortOriginMergeIfNeeded(context, originHead);
            throw SandboxWorkspaceException.GitFailed("merge", merged.Text);
        }

        Remove(context, originMerged: true);
        return new SandboxExit.Merged(commits);
    }

    /// <summary>
    /// Prepares the same merge in the sandbox, leaving its conflict state there for a
    /// user or the agent to resolve. The origin is read-only in this path.
    /// </summary>
    public static void PrepareResolution(SandboxConflict conflict)
    {
        var context = ContextFor(conflict.Sandbox);
        EnsureOriginReady(context);
        EnsureUnchanged(context, conflict);

        if (MergeHead(context.Worktree) is { } existing)
        {
            if (existing != conflict.OriginHead) throw SandboxWorkspaceException.Stale();
            return;
        }

        var status = RunGit(new[] { "status", "--porcelain", "--untracked-files=all" }, context.Worktree);
        if (status.Status != 0 || status.Text.Length != 0)
            throw SandboxWorkspaceException.InvalidSandbox("The sandbox must be clean before preparing conflict resolution.");

        var result = RunGit(new[] { "merge", "--no-ff", "--no-commit", "--no-verify", conflict.OriginHead }, context.Worktree);
        if (result.Status != 0 && UnmergedFiles(context.Worktree).Count == 0)
        {
            AbortSandboxMerge(context);
            throw SandboxWorkspaceException.GitFailed("prepare resolution", result.Text);
        }
    }

    public static SandboxResolutionPreview PreviewResolution(SandboxConflict conflict)
    {
        var context = ContextFor(conflict.Sandbox);
        EnsureResolutionIsCurrent(context, conflict);
        StageAll(context);

        var unresolved = new SortedSet<string>(UnmergedFiles(context.Worktree), StringComparer.Ordinal);
        var files = StagedFiles(context.Worktree);
        foreach (var file in files.Where(file => ContainsConflictMarkers(file, context.Worktree))) unresolved.Add(file);

        var diff = RunGit(new[] { "diff", "--cached", "--binary", "--no-color" }, context.Worktree);
        if (diff.Status != 0) throw SandboxWorkspaceException.GitFailed("diff", diff.Text);

        var fingerprint = ResolutionFingerprint(context);
        var shown = diff.Data.Length > PreviewLimit ? diff.Data[..PreviewLimit] : diff.Data;
        return new SandboxResolutionPreview(
            files, unresolved.ToList(), Encoding.UTF8.GetString(shown), fingerprint, diff.Data.Length > PreviewLimit);
    }

    public static void CancelResolution(SandboxConflict conflict)
    {
        var context = ContextFor(conflict.Sandbox);
        EnsureOriginReady(context);
        EnsureUnchanged(context, conflict);
        if (MergeHead(context.Worktree) is null)
            throw new SandboxWorkspaceException(SandboxWorkspaceErrorKind.ResolutionNotInProgress,
                "There is no sandbox merge resolution in progress.");
        AbortSandboxMerge(context);
    }

    public static SandboxExit ApplyResolution(SandboxConflict conflict, string expectedFingerprint)
    {
        var context = ContextFor(conflict.Sandbox);
        EnsureResolutionIsCurrent(context, conflict);
        var preview = PreviewResolution(conflict);
        if (preview.Fingerprint != expectedFingerprint) throw SandboxWorkspaceException.Stale();
        if (preview.UnresolvedFiles.Count > 0)
            throw new SandboxWorkspaceException(SandboxWorkspaceErrorKind.UnresolvedFiles,
                $"Unresolved conflict files remain: {string.Join(", ", preview.UnresolvedFiles)}");
        var unexpected = preview.Files.Where(file => !conflict.Files.Contains(file)).ToList();
        if (unexpected.Count > 0)
            throw new SandboxWorkspaceException(SandboxWorkspaceErrorKind.UnexpectedResolutionFiles,
                $"The resolution changed files outside the conflict: {string.Join(", ", unexpected)}");

        var committed = RunGit(
            new[] { "commit", "--no-verify", "-m", $"Resolve sandbox merge {conflict.Sandbox.Name}" }, context.Worktree);
        if (committed.Status != 0) throw SandboxWorkspaceException.GitFailed("commit resolution", committed.Text);
        return Exit(conflict.Sandbox, merge: true);
    }

    /// <summary>Sandboxes that still exist for this origin.</summary>
    public static IReadOnlyList<SandboxWorkspace> List(string originPath, string? supportRoot = null)
    {
        var origin = Normalize(originPath);
        if (!IsGitRepository(origin)) return Array.Empty<SandboxWorkspace>();
        var parent = System.IO.Path.GetDirectoryName(Directory(origin, "x", supportRoot))!;
        string originBranch;
        try { originBranch = CurrentBranch(origin); } catch (SandboxWorkspaceException) { originBranch = ""; }
        try
        {
            var prefix = $"refs/heads/{BranchPrefix}";
            return WorktreeRecords(origin)
                .Where(r => r.Path.StartsWith(parent + System.IO.Path.DirectorySeparatorChar, PathComparison))
                .Where(r => r.Branch is not null && r.Branch.StartsWith(prefix, StringComparison.Ordinal))
                .Select(r => new SandboxWorkspace(r.Branch![prefix.Length..], r.Path, origin, originBranch))
                .ToList();
        }
        catch (SandboxWorkspaceException) { return Array.Empty<SandboxWorkspace>(); }
    }

    public static bool IsGitRepository(string path)
    {
        try { return RunGit(new[] { "rev-parse", "--git-dir" }, Normalize(path)).Status == 0; }
        catch (SandboxWorkspaceException) { return false; }
    }

    /// <summary>
    /// Re-checks the origin before clearing a recovery-required state. Read-only; the
    /// user repairs any interrupted git operation manually.
    /// </summary>
    public static void ValidateReady(SandboxWorkspace sandbox) => EnsureOriginReady(ContextFor(sandbox));

    /// <summary>Retries only the cleanup step; safe when worktree remove succeeded but prune failed.</summary>
    public static void RetryCleanup(SandboxWorkspace sandbox, bool originMerged)
    {
        var origin = Normalize(sandbox.OriginPath);
        if (!IsGitRepository(origin)) throw SandboxWorkspaceException.InvalidRepository(origin);
        var originBranch = CurrentBranch(origin);
        if (sandbox.OriginBranch.Length > 0 && sandbox.OriginBranch != originBranch)
            throw SandboxWorkspaceException.BranchChanged(sandbox.OriginBranch, originBranch);
        var worktree = Normalize(sandbox.Path);
        if (System.IO.Directory.Exists(worktree))
        {
            Remove(ContextFor(sandbox), originMerged);
            return;
        }

        var record = WorktreeRecords(origin).FirstOrDefault(r => SamePath(r.Path, worktree));
        if (record is not null && record.Branch != $"refs/heads/{sandbox.Branch}")
            throw SandboxWorkspaceException.CleanupFailed(
                worktree, "The registered worktree branch does not match the sandbox branch.", originMerged);
        var prune = RunGit(new[] { "worktree", "prune" }, origin);
        if (prune.Status != 0) throw SandboxWorkspaceException.CleanupFailed(worktree, prune.Text, originMerged);
        if (WorktreeRecords(origin).Any(r => SamePath(r.Path, worktree)))
            throw SandboxWorkspaceException.CleanupFailed(
                worktree, "Git still registers the sandbox worktree after prune.", originMerged);
    }

    /// <summary>
    /// Writable roots an agent process needs alongside the worktree: the worktree's own
    /// git metadata plus the shared object database. Never the origin's working tree.
    /// </summary>
    public static IReadOnlyList<string> AgentWritableRoots(SandboxWorkspace sandbox) =>
        GitMetadataRoots(sandbox.OriginPath, sandbox.Path);

    public static (int Status, string Text) Git(IReadOnlyList<string> arguments, string directory)
    {
        try
        {
            var result = RunGit(arguments, directory);
            return (result.Status, result.Text);
        }
        catch (SandboxWorkspaceException) { return (-1, "git could not be started"); }
    }

    // MARK: Git validation

    private static Context ContextFor(SandboxWorkspace sandbox)
    {
        var origin = Normalize(sandbox.OriginPath);
        var worktree = Normalize(sandbox.Path);
        if (!IsGitRepository(origin)) throw SandboxWorkspaceException.InvalidRepository(origin);
        if (!System.IO.Directory.Exists(worktree))
            throw SandboxWorkspaceException.InvalidSandbox("The worktree path no longer exists.");

        var originBranch = CurrentBranch(origin);
        if (sandbox.OriginBranch.Length > 0 && sandbox.OriginBranch != originBranch)
            throw SandboxWorkspaceException.BranchChanged(sandbox.OriginBranch, originBranch);

        var record = WorktreeRecords(origin).FirstOrDefault(r => SamePath(r.Path, worktree))
            ?? throw SandboxWorkspaceException.InvalidSandbox("The path is not registered by git worktree.");
        if (record.Branch != $"refs/heads/{sandbox.Branch}")
            throw SandboxWorkspaceException.InvalidSandbox(
                $"The worktree is checked out on {record.Branch ?? "no branch"}, not {sandbox.Branch}.");
        if (CurrentBranch(worktree) != sandbox.Branch)
            throw SandboxWorkspaceException.InvalidSandbox("The sandbox branch does not match its worktree.");

        return new Context(sandbox, origin, worktree, originBranch, GitMetadataRoots(origin, worktree));
    }

    private static void EnsureOriginReady(Context context)
    {
        string current;
        try { current = CurrentBranch(context.Origin); }
        catch (SandboxWorkspaceException) { throw SandboxWorkspaceException.BranchChanged(context.OriginBranch, "<unknown>"); }
        if (current != context.OriginBranch) throw SandboxWorkspaceException.BranchChanged(context.OriginBranch, current);
        if (HasGitOperation(context.Origin))
            throw new SandboxWorkspaceException(SandboxWorkspaceErrorKind.OriginOperationInProgress,
                "The origin checkout already has a merge, rebase, cherry-pick, or revert in progress.");
        var status = RunGit(new[] { "status", "--porcelain", "--untracked-files=all" }, context.Origin);
        if (status.Status != 0) throw SandboxWorkspaceException.GitFailed("status", status.Text);
        if (status.Text.Length != 0)
            throw new SandboxWorkspaceException(SandboxWorkspaceErrorKind.OriginDirty,
                "Commit or stash the origin checkout's tracked and untracked changes before merging.");
    }

    private static readonly string[] ExcludeMem = { ".", ":(exclude).mem", ":(exclude).mem/**" };

    private static void CommitAll(Context context, string message)
    {
        var add = RunGit(new[] { "add", "--all", "--" }.Concat(ExcludeMem).ToArray(), context.Worktree);
        if (add.Status != 0) throw SandboxWorkspaceException.GitFailed("add", add.Text);

        var staged = RunGit(new[] { "diff", "--cached", "--quiet" }, context.Worktree);
        if (staged.Status is not (0 or 1)) throw SandboxWorkspaceException.GitFailed("diff --cached", staged.Text);
        if (staged.Status != 1) return;

        var commit = RunGit(new[] { "commit", "--no-verify", "-m", message }, context.Worktree);
        if (commit.Status != 0) throw SandboxWorkspaceException.GitFailed("commit", commit.Text);
    }

    private static void StageAll(Context context)
    {
        var result = RunGit(new[] { "add", "--all", "--" }.Concat(ExcludeMem).ToArray(), context.Worktree);
        if (result.Status != 0) throw SandboxWorkspaceException.GitFailed("add resolution", result.Text);
    }

    private static int CommitCount(Context context)
    {
        var result = RunGit(new[] { "rev-list", "--count", $"HEAD..refs/heads/{context.Sandbox.Branch}" }, context.Origin);
        if (result.Status != 0 || !int.TryParse(result.Text.Trim(), out var count) || count < 0)
            throw SandboxWorkspaceException.GitFailed("rev-list", result.Text);
        return count;
    }

    private static void Remove(Context context, bool originMerged)
    {
        var result = RunGit(new[] { "worktree", "remove", "--force", context.Worktree }, context.Origin);
        if (result.Status != 0) throw SandboxWorkspaceException.CleanupFailed(context.Worktree, result.Text, originMerged);
        var prune = RunGit(new[] { "worktree", "prune" }, context.Origin);
        if (prune.Status != 0) throw SandboxWorkspaceException.CleanupFailed(context.Worktree, prune.Text, originMerged);
    }

    private static void AbortOriginMerge(Context context, string expectedHead)
    {
        var result = RunGit(new[] { "merge", "--abort" }, context.Origin);
        if (result.Status != 0) throw SandboxWorkspaceException.MergeAbortFailed(result.Text);
        VerifyOriginRestored(context, expectedHead);
    }

    private static void AbortOriginMergeIfNeeded(Context context, string expectedHead)
    {
        if (HasGitOperation(context.Origin)) AbortOriginMerge(context, expectedHead);
    }

    private static void AbortSandboxMerge(Context context)
    {
        var result = RunGit(new[] { "merge", "--abort" }, context.Worktree);
        if (result.Status != 0) throw SandboxWorkspaceException.MergeAbortFailed(result.Text);
        var status = RunGit(new[] { "status", "--porcelain", "--untracked-files=all" }, context.Worktree);
        if (status.Status != 0 || status.Text.Length != 0)
            throw SandboxWorkspaceException.GitFailed("verify sandbox abort", status.Text);
    }

    private static void DiscardResolutionIfNeeded(Context context)
    {
        if (MergeHead(context.Worktree) is not null) AbortSandboxMerge(context);
    }

    private static void VerifyOriginRestored(Context context, string expectedHead)
    {
        if (Revision("HEAD", context.Origin) != expectedHead)
            throw SandboxWorkspaceException.MergeAbortFailed("HEAD changed during merge abort.");
        if (HasGitOperation(context.Origin))
            throw SandboxWorkspaceException.MergeAbortFailed("MERGE_HEAD or another git operation remains.");
        var status = RunGit(new[] { "status", "--porcelain", "--untracked-files=all" }, context.Origin);
        if (status.Status != 0 || status.Text.Length != 0) throw SandboxWorkspaceException.MergeAbortFailed(status.Text);
    }

    private static void EnsureUnchanged(Context context, SandboxConflict conflict)
    {
        if (conflict.OriginBranch.Length > 0 && conflict.OriginBranch != context.OriginBranch)
            throw SandboxWorkspaceException.Stale();
        if (Revision("HEAD", context.Origin) != conflict.OriginHead) throw SandboxWorkspaceException.Stale();
        if (Revision("HEAD", context.Worktree) != conflict.SandboxHead) throw SandboxWorkspaceException.Stale();
    }

    private static void EnsureResolutionIsCurrent(Context context, SandboxConflict conflict)
    {
        EnsureOriginReady(context);
        EnsureUnchanged(context, conflict);
        if (MergeHead(context.Worktree) != conflict.OriginHead)
            throw new SandboxWorkspaceException(SandboxWorkspaceErrorKind.ResolutionNotInProgress,
                "There is no sandbox merge resolution in progress.");
    }

    private static string ResolutionFingerprint(Context context)
    {
        var originHead = Revision("HEAD", context.Origin);
        var head = Revision("HEAD", context.Worktree);
        var status = RunGit(new[] { "status", "--porcelain", "--untracked-files=all" }, context.Worktree);
        if (status.Status != 0) throw SandboxWorkspaceException.GitFailed("status resolution", status.Text);
        var diff = RunGit(new[] { "diff", "--cached", "--binary", "--no-color" }, context.Worktree);
        if (diff.Status != 0) throw SandboxWorkspaceException.GitFailed("fingerprint", diff.Text);

        using var stream = new MemoryStream();
        void Write(byte[] bytes) => stream.Write(bytes, 0, bytes.Length);
        Write(Encoding.UTF8.GetBytes($"origin:{originHead}\n"));
        Write(Encoding.UTF8.GetBytes($"sandbox:{head}\n"));
        Write(Encoding.UTF8.GetBytes($"status:{status.Text}\n"));
        stream.WriteByte(0);
        Write(diff.Data);
        return Convert.ToHexString(SHA256.HashData(stream.ToArray())).ToLowerInvariant();
    }

    private static IReadOnlyList<string> NulSeparatedNames(GitResult result, string operation)
    {
        if (result.Status != 0) throw SandboxWorkspaceException.GitFailed(operation, result.Text);
        return Encoding.UTF8.GetString(result.Data)
            .Split('\0', StringSplitOptions.RemoveEmptyEntries)
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToList();
    }

    private static IReadOnlyList<string> UnmergedFiles(string directory) =>
        NulSeparatedNames(RunGit(new[] { "diff", "--name-only", "--diff-filter=U", "-z" }, directory), "diff unmerged");

    private static IReadOnlyList<string> StagedFiles(string directory) =>
        NulSeparatedNames(RunGit(new[] { "diff", "--cached", "--name-only", "-z" }, directory), "diff --cached names");

    private static bool ContainsConflictMarkers(string path, string directory)
    {
        var root = Normalize(directory);
        var file = Normalize(System.IO.Path.GetFullPath(path, root));
        if (!file.StartsWith(root + System.IO.Path.DirectorySeparatorChar, PathComparison)) return true;
        string text;
        try { text = File.ReadAllText(file, new UTF8Encoding(false, throwOnInvalidBytes: true)); }
        catch (Exception e) when (e is IOException or DecoderFallbackException or UnauthorizedAccessException) { return false; }
        var lines = text.Split('\n');
        return new[] { "<<<<<<<", "=======", ">>>>>>>" }.All(marker => lines.Any(l => l.StartsWith(marker, StringComparison.Ordinal)));
    }

    private static string Revision(string name, string directory)
    {
        var result = RunGit(new[] { "rev-parse", "--verify", name }, directory);
        if (result.Status != 0 || result.Text.Length == 0) throw SandboxWorkspaceException.GitFailed($"rev-parse {name}", result.Text);
        return result.Text;
    }

    private static string CurrentBranch(string directory)
    {
        var result = RunGit(new[] { "branch", "--show-current" }, directory);
        if (result.Status != 0) throw SandboxWorkspaceException.GitFailed("branch --show-current", result.Text);
        var branch = result.Text.Trim();
        if (branch.Length == 0)
            throw new SandboxWorkspaceException(SandboxWorkspaceErrorKind.DetachedOrigin,
                "The origin checkout must be on a local branch before a sandbox can start.");
        return branch;
    }

    private static string? MergeHead(string directory)
    {
        var result = RunGit(new[] { "rev-parse", "--verify", "--quiet", "MERGE_HEAD" }, directory);
        return result.Status == 0 ? result.Text : null;
    }

    private static bool HasGitOperation(string directory)
    {
        if (MergeHead(directory) is { Length: > 0 }) return true;
        foreach (var name in new[] { "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD" })
        {
            var result = RunGit(new[] { "rev-parse", "--git-path", name }, directory);
            if (result.Status != 0) continue;
            var path = System.IO.Path.GetFullPath(result.Text, directory);
            if (File.Exists(path) || System.IO.Directory.Exists(path)) return true;
        }
        return false;
    }

    private static List<WorktreeRecord> WorktreeRecords(string origin)
    {
        var result = RunGit(new[] { "worktree", "list", "--porcelain" }, origin);
        if (result.Status != 0) throw SandboxWorkspaceException.GitFailed("worktree list", result.Text);

        var records = new List<WorktreeRecord>();
        string? path = null;
        string? branch = null;
        void Append()
        {
            if (path is not null) records.Add(new WorktreeRecord(Normalize(path), branch));
        }
        foreach (var line in result.Text.Split('\n').Select(l => l.TrimEnd('\r')))
        {
            if (line.StartsWith("worktree ", StringComparison.Ordinal))
            {
                Append();
                path = line["worktree ".Length..];
                branch = null;
            }
            else if (line.StartsWith("branch ", StringComparison.Ordinal))
            {
                branch = line["branch ".Length..];
            }
        }
        Append();
        return records;
    }

    private static IReadOnlyList<string> GitMetadataRoots(string origin, string worktree)
    {
        var roots = new List<string>();
        foreach (var directory in new[] { origin, worktree })
        {
            foreach (var flag in new[] { "--git-dir", "--git-common-dir" })
            {
                var result = RunGit(new[] { "rev-parse", flag }, directory);
                if (result.Status != 0 || result.Text.Length == 0)
                    throw SandboxWorkspaceException.GitFailed($"rev-parse {flag}", result.Text);
                roots.Add(System.IO.Path.GetFullPath(result.Text, directory));
            }
        }
        var seen = new HashSet<string>(PathComparison == StringComparison.Ordinal ? StringComparer.Ordinal : StringComparer.OrdinalIgnoreCase);
        return roots.Select(Normalize).Where(seen.Add).ToList();
    }

    private static bool SamePath(string left, string right) => string.Equals(left, right, PathComparison);

    /// <summary>Absolute path with symlinks resolved, so the same directory always compares equal.</summary>
    internal static string Normalize(string path)
    {
        var full = System.IO.Path.GetFullPath(path);
        var root = System.IO.Path.GetPathRoot(full) ?? "";
        var trimmed = full.Length > root.Length ? full.TrimEnd(System.IO.Path.DirectorySeparatorChar) : full;
        try
        {
            var resolved = root;
            foreach (var part in trimmed[root.Length..].Split(System.IO.Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
            {
                resolved = System.IO.Path.Combine(resolved, part);
                FileSystemInfo info = System.IO.Directory.Exists(resolved) ? new DirectoryInfo(resolved) : new FileInfo(resolved);
                if (info.Exists && info.LinkTarget is not null && info.ResolveLinkTarget(returnFinalTarget: true) is { } target)
                    resolved = target.FullName;
            }
            return resolved.Length > root.Length ? resolved.TrimEnd(System.IO.Path.DirectorySeparatorChar) : resolved;
        }
        catch (IOException) { return trimmed; }
        catch (UnauthorizedAccessException) { return trimmed; }
    }

    // MARK: Process execution

    private static GitResult RunGit(IReadOnlyList<string> arguments, string directory)
    {
        var start = new ProcessStartInfo("git")
        {
            WorkingDirectory = directory,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        // A credential or editor prompt has nobody to answer it.
        start.Environment["GIT_TERMINAL_PROMPT"] = "0";
        start.Environment["GIT_EDITOR"] = "true";
        try
        {
            using var process = Process.Start(start)
                ?? throw SandboxWorkspaceException.GitFailed(arguments.FirstOrDefault() ?? "command", "process did not start");
            process.StandardInput.Close();
            var errors = process.StandardError.ReadToEndAsync();
            using var buffer = new MemoryStream();
            process.StandardOutput.BaseStream.CopyTo(buffer);
            process.WaitForExit();
            var data = buffer.ToArray();
            var output = Encoding.UTF8.GetString(data);
            var text = process.ExitCode == 0 ? output : output + errors.GetAwaiter().GetResult();
            return new GitResult(process.ExitCode, text.Trim(), data);
        }
        catch (System.ComponentModel.Win32Exception e)
        {
            throw SandboxWorkspaceException.GitFailed(arguments.FirstOrDefault() ?? "command", e.Message);
        }
    }
}
