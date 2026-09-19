// Copyright (c) 2026 DOTS
// Bounded before/after tracker for the visible changed-files summary.

using System.Collections.Generic;
using System.Security.Cryptography;

namespace DotsHarnessCore;

public sealed class WorkspaceChangeTracker
{
    private const int MaximumEntries = 5_000;
    private const int MaximumDepth = 12;

    private readonly string _root;
    private readonly Dictionary<string, Signature> _before;
    private readonly bool _beforeComplete;
    private readonly string? _beforeFailure;

    private readonly record struct Signature(long Length, long LastWriteUtcTicks, string Hash);
    private sealed record SnapshotState(Dictionary<string, Signature> Files, bool Complete, string? Failure);

    private WorkspaceChangeTracker(string root, SnapshotState before)
    {
        _root = root;
        _before = before.Files;
        _beforeComplete = before.Complete;
        _beforeFailure = before.Failure;
    }

    public static WorkspaceChangeTracker? Start(string workspace)
    {
        try
        {
            var root = Path.GetFullPath(workspace);
            if (!Directory.Exists(root) || IsSymlink(root)) return null;
            return new WorkspaceChangeTracker(root, Snapshot(root));
        }
        catch
        {
            return null;
        }
    }

    public WorkspaceChangeResult FinishResult()
    {
        SnapshotState? after = null;
        try
        {
            after = Snapshot(_root);
            var changed = new List<ChangedFile>();
            foreach (var path in _before.Keys.Union(after.Files.Keys).OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
            {
                if (!_before.ContainsKey(path)) changed.Add(new ChangedFile(path, ChangedFileOperation.Added));
                else if (!after.Files.ContainsKey(path)) changed.Add(new ChangedFile(path, ChangedFileOperation.Deleted));
                else if (_before[path] != after.Files[path]) changed.Add(new ChangedFile(path, ChangedFileOperation.Modified));
            }
            var complete = _beforeComplete && after.Complete;
            var failure = _beforeFailure ?? after.Failure;
            return new WorkspaceChangeResult(changed, complete ? "complete" : "incomplete", failure);
        }
        catch (Exception ex)
        {
            // File tracking is diagnostic only; never fail an agent turn. Keep a
            // visible incomplete status instead of claiming there were no changes.
            return new WorkspaceChangeResult([], "incomplete", ex.Message);
        }
    }

    public IReadOnlyList<ChangedFile> Finish() => FinishResult().ChangedFiles;

    private static SnapshotState Snapshot(string root)
    {
        var result = new Dictionary<string, Signature>(StringComparer.OrdinalIgnoreCase);
        var pending = new Stack<(string Path, int Depth)>();
        pending.Push((root, 0));
        var complete = true;
        string? failure = null;
        while (pending.Count > 0 && result.Count < MaximumEntries)
        {
            var (directory, depth) = pending.Pop();
            if (depth > MaximumDepth) continue;
            if (IsSymlink(directory))
            {
                complete = false;
                failure ??= "A symbolic-link directory could not be inspected.";
                continue;
            }
            if (depth == MaximumDepth && HasChildDirectory(directory))
            {
                complete = false;
                failure ??= "Workspace depth limit reached.";
            }

            IEnumerable<string> files;
            try { files = Directory.EnumerateFiles(directory); }
            catch (Exception ex)
            {
                complete = false;
                failure ??= ex.Message;
                continue;
            }
            foreach (var file in files)
            {
                if (result.Count >= MaximumEntries || IsIgnored(file)) continue;
                if (IsSymlink(file))
                {
                    complete = false;
                    failure ??= "A symbolic-link file could not be inspected.";
                    continue;
                }
                try
                {
                    var info = new FileInfo(file);
                    result[Relative(root, file)] = new Signature(info.Length, info.LastWriteTimeUtc.Ticks, Hash(file));
                }
                catch (Exception ex)
                {
                    complete = false;
                    failure ??= ex.Message;
                }
            }

            if (depth == MaximumDepth) continue;
            IEnumerable<string> directories;
            try { directories = Directory.EnumerateDirectories(directory); }
            catch (Exception ex)
            {
                complete = false;
                failure ??= ex.Message;
                continue;
            }
            foreach (var child in directories)
            {
                if (IsIgnored(child)) continue;
                if (IsSymlink(child))
                {
                    complete = false;
                    failure ??= "A symbolic-link directory could not be inspected.";
                    continue;
                }
                pending.Push((child, depth + 1));
            }
        }
        if (pending.Count > 0)
        {
            complete = false;
            failure ??= "Workspace entry limit reached.";
        }
        return new SnapshotState(result, complete, failure);
    }

    private static string Hash(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static bool HasChildDirectory(string path)
    {
        try { return Directory.EnumerateDirectories(path).Any(child => !IsIgnored(child)); }
        catch { return true; }
    }

    private static string Relative(string root, string path) =>
        Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/');

    private static bool IsIgnored(string path)
    {
        var name = Path.GetFileName(path);
        return name.Equals(".git", StringComparison.OrdinalIgnoreCase)
            || name.Equals(".mem", StringComparison.OrdinalIgnoreCase)
            || name.Equals("build", StringComparison.OrdinalIgnoreCase)
            || name.Equals(".build", StringComparison.OrdinalIgnoreCase)
            || name.Equals("bin", StringComparison.OrdinalIgnoreCase)
            || name.Equals("obj", StringComparison.OrdinalIgnoreCase)
            || name.Equals("dist", StringComparison.OrdinalIgnoreCase)
            || name.Equals("node_modules", StringComparison.OrdinalIgnoreCase)
            || name.Equals("Pods", StringComparison.OrdinalIgnoreCase)
            || name.Equals("DerivedData", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsSymlink(string path)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            return attributes.HasFlag(FileAttributes.ReparsePoint)
                || (File.Exists(path) ? new FileInfo(path).LinkTarget is not null : new DirectoryInfo(path).LinkTarget is not null);
        }
        catch { return true; }
    }
}

public sealed record WorkspaceChangeResult(
    IReadOnlyList<ChangedFile> ChangedFiles,
    string TrackingStatus,
    string? FailureReason);
