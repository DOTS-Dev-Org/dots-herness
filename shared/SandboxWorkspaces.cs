// Copyright (c) 2026 DOTS
// Git worktree lifecycle shared by the Windows and Linux desktop clients.

using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;

namespace DotsHarnessCore;

public sealed record SandboxWorkspace(string Name, string Path, string OriginPath, string OriginBranch)
{
    public const string BranchPrefix = "herness/sandbox-";
    public string Branch => BranchPrefix + Name;
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

public enum SandboxExitKind { Merged, Conflicted, Discarded }

public sealed record SandboxExit(SandboxExitKind Kind, int Commits = 0, SandboxConflict? Conflict = null);

/// <summary>
/// Isolates agent edits in a git worktree. The origin working tree is never
/// written during conflict resolution; changes are applied only after preview.
/// </summary>
public sealed class SandboxWorkspaces(string supportRoot)
{
    private const int PreviewLimit = 512_000;
    private const string BranchPrefix = SandboxWorkspace.BranchPrefix;
    private readonly string _root = Path.GetFullPath(Path.Combine(supportRoot, "sandboxes"));

    public static bool IsGitRepository(string path) => Git(path, "rev-parse", "--git-dir").ExitCode == 0;

    public SandboxWorkspace Enter(string originPath, string rawName)
    {
        var origin = NormalizePath(originPath);
        if (!IsGitRepository(origin)) throw new InvalidOperationException($"Sandbox needs a git repository: {origin}");
        var name = NormalizeName(rawName) ?? throw new InvalidOperationException("The sandbox name is empty after normalization.");
        var branch = CurrentBranch(origin);
        var directory = DirectoryFor(origin, name);
        var sandbox = new SandboxWorkspace(name, directory, origin, branch);
        if (Directory.Exists(directory))
        {
            _ = CreateContext(sandbox);
            return sandbox;
        }

        Directory.CreateDirectory(Path.GetDirectoryName(directory)!);
        var exists = Git(origin, "rev-parse", "--verify", "--quiet", sandbox.Branch).ExitCode == 0;
        var result = exists
            ? Git(origin, "worktree", "add", directory, sandbox.Branch)
            : Git(origin, "worktree", "add", "-b", sandbox.Branch, directory);
        EnsureSuccess(result, "worktree add");
        return sandbox;
    }

    public SandboxWorkspace Restore(string originPath, string sandboxPath, string? name = null, string? originBranch = null)
    {
        var origin = NormalizePath(originPath);
        var path = NormalizePath(sandboxPath);
        if (!IsGitRepository(origin)) throw new InvalidOperationException($"Sandbox needs a git repository: {origin}");
        var branch = CurrentBranch(origin);
        if (!string.IsNullOrWhiteSpace(originBranch) && originBranch != branch)
            throw new InvalidOperationException($"The origin branch changed from {originBranch} to {branch}.");
        var normalizedName = NormalizeName(name ?? System.IO.Path.GetFileName(path.TrimEnd(System.IO.Path.DirectorySeparatorChar, System.IO.Path.AltDirectorySeparatorChar)))
            ?? throw new InvalidOperationException("The sandbox name is invalid.");
        var sandbox = new SandboxWorkspace(normalizedName, path, origin, branch);
        _ = CreateContext(sandbox);
        return sandbox;
    }

    public IReadOnlyList<SandboxWorkspace> List(string originPath)
    {
        var origin = NormalizePath(originPath);
        if (!IsGitRepository(origin)) return [];
        var parent = Path.GetDirectoryName(DirectoryFor(origin, "placeholder"))!;
        var result = Git(origin, "worktree", "list", "--porcelain");
        if (result.ExitCode != 0) return [];
        var branch = TryCurrentBranch(origin) ?? "";
        var records = ParseWorktrees(result.Output);
        return records
            .Where(item => IsWithin(parent, item.Path) && item.Branch?.StartsWith("refs/heads/" + BranchPrefix, StringComparison.Ordinal) == true)
            .Select(item => new SandboxWorkspace(
                item.Branch![ ("refs/heads/" + BranchPrefix).Length..], item.Path, origin, branch))
            .ToArray();
    }

    public SandboxExit Exit(SandboxWorkspace sandbox, bool merge)
    {
        var context = CreateContext(sandbox);
        if (!merge)
        {
            AbortSandboxMergeIfPresent(context);
            Remove(context, originMerged: false);
            return new SandboxExit(SandboxExitKind.Discarded);
        }

        EnsureOriginReady(context);
        if (MergeHead(context.Worktree) is not null)
            throw new InvalidOperationException("A sandbox conflict resolution is in progress. Preview and approve it before merging.");
        CommitSandboxChanges(context);
        var originHead = Revision(context.Origin, "HEAD");
        var sandboxHead = Revision(context.Origin, "refs/heads/" + sandbox.Branch);
        var count = CommitCount(context);
        if (count == 0)
        {
            Remove(context, originMerged: false);
            return new SandboxExit(SandboxExitKind.Merged, 0);
        }

        var merged = Git(context.Origin, "merge", "--no-ff", "--no-verify", "-m", "Merge sandbox " + sandbox.Name, sandbox.Branch);
        if (merged.ExitCode != 0)
        {
            var files = UnmergedFiles(context.Origin);
            if (files.Count > 0)
            {
                AbortOriginMerge(context, originHead);
                return new SandboxExit(SandboxExitKind.Conflicted, Conflict: new SandboxConflict(
                    sandbox, context.OriginBranch, originHead, sandboxHead, files));
            }
            AbortOriginMergeIfNeeded(context, originHead);
            throw new InvalidOperationException($"git merge failed: {merged.Output}");
        }

        Remove(context, originMerged: true);
        return new SandboxExit(SandboxExitKind.Merged, count);
    }

    public void PrepareResolution(SandboxConflict conflict)
    {
        var context = CreateContext(conflict.Sandbox);
        EnsureOriginReady(context);
        EnsureConflictCurrent(context, conflict);
        if (MergeHead(context.Worktree) is { } current)
        {
            if (current != conflict.OriginHead) throw new InvalidOperationException("The sandbox changed after the conflict was recorded.");
            return;
        }
        var status = Git(context.Worktree, "status", "--porcelain", "--untracked-files=all");
        if (status.ExitCode != 0 || status.Output.Length != 0)
            throw new InvalidOperationException("The sandbox must be clean before preparing conflict resolution.");
        var merge = Git(context.Worktree, "merge", "--no-ff", "--no-commit", "--no-verify", conflict.OriginHead);
        if (merge.ExitCode != 0 && UnmergedFiles(context.Worktree).Count == 0)
        {
            AbortSandboxMergeIfPresent(context);
            throw new InvalidOperationException($"Could not prepare conflict resolution: {merge.Output}");
        }
    }

    public SandboxResolutionPreview PreviewResolution(SandboxConflict conflict)
    {
        var context = CreateContext(conflict.Sandbox);
        EnsureResolutionCurrent(context, conflict);
        EnsureSuccess(Git(context.Worktree, "add", "-A"), "add resolution");
        var files = SplitNull(GitRequired(context.Worktree, "diff", "--cached", "--name-only", "-z"));
        var unresolved = new HashSet<string>(UnmergedFiles(context.Worktree), StringComparer.Ordinal);
        foreach (var file in files)
        {
            var fullPath = Path.GetFullPath(Path.Combine(context.Worktree, file.Replace('/', Path.DirectorySeparatorChar)));
            if (!IsWithin(context.Worktree, fullPath) || !File.Exists(fullPath)) continue;
            try
            {
                var text = File.ReadAllText(fullPath);
                if (text.Contains("<<<<<<<", StringComparison.Ordinal)
                    || text.Contains("=======", StringComparison.Ordinal)
                    || text.Contains(">>>>>>>", StringComparison.Ordinal)) unresolved.Add(file);
            }
            catch (DecoderFallbackException) { }
            catch (IOException) { }
        }
        var diff = GitRequired(context.Worktree, "diff", "--cached", "--binary", "--no-color");
        var fingerprintSource = string.Join("\n", Revision(context.Worktree, "HEAD"),
            GitRequired(context.Worktree, "status", "--porcelain", "--untracked-files=all"), diff);
        var fingerprint = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(fingerprintSource))).ToLowerInvariant();
        return new SandboxResolutionPreview(
            files, unresolved.Order(StringComparer.Ordinal).ToArray(), diff[..Math.Min(diff.Length, PreviewLimit)],
            fingerprint, Encoding.UTF8.GetByteCount(diff) > PreviewLimit);
    }

    public void CancelResolution(SandboxConflict conflict)
    {
        var context = CreateContext(conflict.Sandbox);
        EnsureOriginReady(context);
        EnsureConflictCurrent(context, conflict);
        if (MergeHead(context.Worktree) is null)
            throw new InvalidOperationException("There is no sandbox merge resolution in progress.");
        AbortSandboxMerge(context);
    }

    public SandboxExit ApplyResolution(SandboxConflict conflict, string expectedFingerprint)
    {
        var context = CreateContext(conflict.Sandbox);
        EnsureResolutionCurrent(context, conflict);
        var preview = PreviewResolution(conflict);
        if (preview.Fingerprint != expectedFingerprint) throw new InvalidOperationException("The sandbox changed after the resolution preview. Create a new preview.");
        if (preview.IsTruncated || preview.UnresolvedFiles.Count > 0)
            throw new InvalidOperationException("Approval requires a complete preview with no unresolved files.");
        var unexpected = preview.Files.Where(file => !conflict.Files.Contains(file, StringComparer.Ordinal)).ToArray();
        if (unexpected.Length > 0) throw new InvalidOperationException("The resolution changed files outside the conflict: " + string.Join(", ", unexpected));
        EnsureSuccess(Git(context.Worktree, "commit", "--no-verify", "-m", "Resolve sandbox merge " + conflict.Sandbox.Name), "commit resolution");
        return Exit(conflict.Sandbox, merge: true);
    }

    public void ValidateReady(SandboxWorkspace sandbox) => EnsureOriginReady(CreateContext(sandbox));

    public void RetryCleanup(SandboxWorkspace sandbox, bool originMerged)
    {
        var origin = NormalizePath(sandbox.OriginPath);
        if (!IsGitRepository(origin)) throw new InvalidOperationException($"Sandbox origin is unavailable: {origin}");
        var currentBranch = CurrentBranch(origin);
        if (!string.IsNullOrWhiteSpace(sandbox.OriginBranch) && sandbox.OriginBranch != currentBranch)
            throw new InvalidOperationException($"The origin branch changed from {sandbox.OriginBranch} to {currentBranch}.");
        if (Directory.Exists(sandbox.Path))
        {
            Remove(CreateContext(sandbox), originMerged);
            return;
        }

        var records = ParseWorktrees(GitRequired(origin, "worktree", "list", "--porcelain"));
        var staleRecord = records.FirstOrDefault(item => PathEquals(item.Path, sandbox.Path));
        if (staleRecord is not null && staleRecord.Branch != "refs/heads/" + sandbox.Branch)
            throw new InvalidOperationException("The registered worktree branch does not match the sandbox branch.");
        EnsureSuccess(Git(origin, "worktree", "prune"), "worktree prune");
        if (ParseWorktrees(GitRequired(origin, "worktree", "list", "--porcelain"))
            .Any(item => PathEquals(item.Path, sandbox.Path)))
            throw new InvalidOperationException("Git still registers the sandbox worktree after prune.");
    }

    public static IReadOnlyList<string> AgentWritableRoots(SandboxWorkspace sandbox)
    {
        var roots = new HashSet<string>(PathComparer);
        foreach (var directory in new[] { sandbox.OriginPath, sandbox.Path })
        {
            foreach (var flag in new[] { "--git-dir", "--git-common-dir" })
            {
                var result = Git(directory, "rev-parse", flag);
                if (result.ExitCode != 0 || string.IsNullOrWhiteSpace(result.Output))
                    throw new InvalidOperationException($"git rev-parse {flag} failed: {result.Output}");
                var value = result.Output.Trim();
                roots.Add(Path.GetFullPath(Path.IsPathRooted(value) ? value : Path.Combine(directory, value)));
            }
        }
        return roots.ToArray();
    }

    private string DirectoryFor(string origin, string name)
    {
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(origin))).ToLowerInvariant()[..16];
        var project = new string(Path.GetFileName(origin.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar))
            .Select(character => char.IsLetterOrDigit(character) || character is '-' or '_' ? character : '-')
            .ToArray());
        return Path.GetFullPath(Path.Combine(_root, $"{project}-{digest}", name));
    }

    private static string? NormalizeName(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        var result = new StringBuilder();
        var dash = false;
        foreach (var character in raw.Trim().ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(character)) { result.Append(character); dash = false; }
            else if (result.Length > 0 && !dash) { result.Append('-'); dash = true; }
        }
        var value = result.ToString().Trim('-');
        return value.Length == 0 ? null : value[..Math.Min(value.Length, 40)];
    }

    private sealed record Context(SandboxWorkspace Sandbox, string Origin, string Worktree, string OriginBranch);

    private Context CreateContext(SandboxWorkspace sandbox)
    {
        var origin = NormalizePath(sandbox.OriginPath);
        var worktree = NormalizePath(sandbox.Path);
        if (!IsGitRepository(origin)) throw new InvalidOperationException($"Sandbox origin is unavailable: {origin}");
        if (!Directory.Exists(worktree)) throw new InvalidOperationException("The sandbox worktree path no longer exists.");
        if (!IsWithin(_root, worktree)) throw new InvalidOperationException("The sandbox path is outside the managed sandbox folder.");
        var originBranch = CurrentBranch(origin);
        if (!string.IsNullOrWhiteSpace(sandbox.OriginBranch) && sandbox.OriginBranch != originBranch)
            throw new InvalidOperationException($"The origin branch changed from {sandbox.OriginBranch} to {originBranch}.");
        var record = ParseWorktrees(GitRequired(origin, "worktree", "list", "--porcelain"))
            .FirstOrDefault(item => PathEquals(item.Path, worktree));
        if (record is null) throw new InvalidOperationException("The path is not registered by git worktree.");
        if (record.Branch != "refs/heads/" + sandbox.Branch || CurrentBranch(worktree) != sandbox.Branch)
            throw new InvalidOperationException("The sandbox worktree is checked out on a different branch.");
        return new Context(sandbox, origin, worktree, originBranch);
    }

    private static void EnsureOriginReady(Context context)
    {
        if (CurrentBranch(context.Origin) != context.OriginBranch)
            throw new InvalidOperationException("The origin branch changed while the sandbox was active.");
        if (Git(context.Origin, "status", "--porcelain", "--untracked-files=all") is { ExitCode: 0, Output.Length: 0 }) { }
        else throw new InvalidOperationException("Commit or stash the origin checkout's tracked and untracked changes before merging.");
        if (HasOperation(context.Origin)) throw new InvalidOperationException("The origin checkout already has a merge, rebase, cherry-pick, or revert in progress.");
    }

    private static bool HasOperation(string directory)
    {
        foreach (var flag in new[] { "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply" })
        {
            var result = Git(directory, "rev-parse", "--git-path", flag);
            if (result.ExitCode == 0)
            {
                var path = Path.Combine(directory, result.Output.Trim());
                if (File.Exists(path) || Directory.Exists(path)) return true;
            }
        }
        return false;
    }

    private static void CommitSandboxChanges(Context context)
    {
        if (MergeHead(context.Worktree) is not null) throw new InvalidOperationException("A sandbox conflict resolution is in progress.");
        var status = Git(context.Worktree, "status", "--porcelain", "--untracked-files=all");
        EnsureSuccess(status, "status");
        if (status.Output.Length == 0) return;
        EnsureSuccess(Git(context.Worktree, "add", "-A"), "add");
        EnsureSuccess(Git(context.Worktree, "commit", "--no-verify", "-m", "herness sandbox: " + context.Sandbox.Name), "commit");
    }

    private static void EnsureConflictCurrent(Context context, SandboxConflict conflict)
    {
        if (context.OriginBranch != conflict.OriginBranch
            || Revision(context.Origin, "HEAD") != conflict.OriginHead
            || Revision(context.Worktree, "HEAD") != conflict.SandboxHead)
            throw new InvalidOperationException("The sandbox or origin changed after the conflict preview. Create a new preview.");
    }

    private static void EnsureResolutionCurrent(Context context, SandboxConflict conflict)
    {
        EnsureOriginReady(context);
        EnsureConflictCurrent(context, conflict);
        if (MergeHead(context.Worktree) != conflict.OriginHead)
            throw new InvalidOperationException("There is no matching sandbox merge resolution in progress.");
    }

    private static void AbortSandboxMergeIfPresent(Context context)
    {
        if (MergeHead(context.Worktree) is not null) AbortSandboxMerge(context);
    }

    private static void AbortSandboxMerge(Context context)
    {
        var result = Git(context.Worktree, "merge", "--abort");
        if (result.ExitCode != 0) throw new InvalidOperationException("git merge --abort failed in the sandbox: " + result.Output);
    }

    private static void AbortOriginMergeIfNeeded(Context context, string expectedHead)
    {
        if (MergeHead(context.Origin) is not null) AbortOriginMerge(context, expectedHead);
    }

    private static void AbortOriginMerge(Context context, string expectedHead)
    {
        var result = Git(context.Origin, "merge", "--abort");
        if (result.ExitCode != 0 || Revision(context.Origin, "HEAD") != expectedHead || MergeHead(context.Origin) is not null)
            throw new InvalidOperationException("git merge --abort could not restore the origin checkout: " + result.Output);
    }

    private static IReadOnlyList<string> UnmergedFiles(string directory) =>
        SplitNull(GitRequired(directory, "diff", "--name-only", "--diff-filter=U", "-z"));

    private static string? MergeHead(string directory)
    {
        var result = Git(directory, "rev-parse", "--git-path", "MERGE_HEAD");
        if (result.ExitCode != 0) return null;
        var path = Path.Combine(directory, result.Output.Trim());
        return File.Exists(path) ? File.ReadAllText(path).Trim() : null;
    }

    private static int CommitCount(Context context)
    {
        var value = GitRequired(context.Origin, "rev-list", "--count", context.OriginBranch + ".." + context.Sandbox.Branch).Trim();
        return int.TryParse(value, out var count) ? count : throw new InvalidOperationException("git rev-list returned an invalid commit count.");
    }

    private static string Revision(string directory, string name) => GitRequired(directory, "rev-parse", name).Trim();
    private static string CurrentBranch(string directory)
    {
        var branch = GitRequired(directory, "branch", "--show-current").Trim();
        return branch.Length == 0 ? throw new InvalidOperationException("The origin checkout must be on a local branch before a sandbox can start.") : branch;
    }
    private static string? TryCurrentBranch(string directory) => (Git(directory, "branch", "--show-current") is { ExitCode: 0 } result ? result.Output.Trim() : null);

    private static void Remove(Context context, bool originMerged)
    {
        var result = Git(context.Origin, "worktree", "remove", "--force", context.Worktree);
        if (result.ExitCode != 0) throw new InvalidOperationException((originMerged ? "The merge was applied, but cleanup is still pending" : "The sandbox was not removed") + $" at {context.Worktree}: {result.Output}");
        var prune = Git(context.Origin, "worktree", "prune");
        if (prune.ExitCode != 0) throw new InvalidOperationException((originMerged ? "The merge was applied, but cleanup is still pending" : "The sandbox was not removed") + $" at {context.Worktree}: {prune.Output}");
    }

    private static IReadOnlyList<WorktreeRecord> ParseWorktrees(string output)
    {
        var records = new List<WorktreeRecord>();
        string? path = null;
        string? branch = null;
        void Flush()
        {
            if (!string.IsNullOrWhiteSpace(path)) records.Add(new WorktreeRecord(NormalizePath(path), branch));
            path = null; branch = null;
        }
        foreach (var line in output.Split('\n'))
        {
            if (line.StartsWith("worktree ", StringComparison.Ordinal)) { Flush(); path = line[9..].TrimEnd('\r'); }
            else if (line.StartsWith("branch ", StringComparison.Ordinal)) branch = line[7..].TrimEnd('\r');
            else if (line.Length == 0) Flush();
        }
        Flush();
        return records;
    }

    private sealed record WorktreeRecord(string Path, string? Branch);
    private static string NormalizePath(string path) => Path.GetFullPath(path);
    private static StringComparer PathComparer => OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;
    private static bool PathEquals(string left, string right) => PathComparer.Equals(NormalizePath(left), NormalizePath(right));
    private static bool IsWithin(string root, string path)
    {
        var fullRoot = NormalizePath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var fullPath = NormalizePath(path);
        return PathComparer.Equals(fullPath, fullRoot.TrimEnd(Path.DirectorySeparatorChar))
            || fullPath.StartsWith(fullRoot, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
    }
    private static IReadOnlyList<string> SplitNull(string output) => output.Split('\0', StringSplitOptions.RemoveEmptyEntries);

    private sealed record GitResult(int ExitCode, string Output);
    private static string GitRequired(string directory, params string[] arguments)
    {
        var result = Git(directory, arguments);
        EnsureSuccess(result, arguments.FirstOrDefault() ?? "git");
        return result.Output;
    }
    private static void EnsureSuccess(GitResult result, string operation)
    {
        if (result.ExitCode != 0) throw new InvalidOperationException($"git {operation} failed: {result.Output}");
    }
    private static GitResult Git(string directory, params string[] arguments)
    {
        try
        {
            var info = new ProcessStartInfo("git") { WorkingDirectory = directory, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
            foreach (var argument in arguments) info.ArgumentList.Add(argument);
            using var process = Process.Start(info);
            if (process is null) return new GitResult(-1, "git could not start.");
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(120_000)) { try { process.Kill(entireProcessTree: true); } catch { } return new GitResult(-1, "git timed out after 120 seconds."); }
            return new GitResult(process.ExitCode, (stdout.GetAwaiter().GetResult() + stderr.GetAwaiter().GetResult()).TrimEnd('\r', '\n'));
        }
        catch (Exception error) { return new GitResult(-1, error.Message); }
    }
}
