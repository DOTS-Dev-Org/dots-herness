// Copyright (c) 2026 DOTS
// Bounded before/after tracker for the visible changed-files summary.

using System.Collections.Generic;

namespace DotsHarnessCore;

public sealed class WorkspaceChangeTracker
{
    private const int MaximumEntries = 5_000;
    private const int MaximumDepth = 12;

    private readonly string _root;
    private readonly Dictionary<string, Signature> _before;

    private readonly record struct Signature(long Length, long LastWriteUtcTicks);

    private WorkspaceChangeTracker(string root, Dictionary<string, Signature> before)
    {
        _root = root;
        _before = before;
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

    public IReadOnlyList<ChangedFile> Finish()
    {
        try
        {
            var after = Snapshot(_root);
            var changed = new List<ChangedFile>();
            foreach (var path in _before.Keys.Union(after.Keys).OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
            {
                if (!_before.ContainsKey(path)) changed.Add(new ChangedFile(path, ChangedFileOperation.Added));
                else if (!after.ContainsKey(path)) changed.Add(new ChangedFile(path, ChangedFileOperation.Deleted));
                else if (_before[path] != after[path]) changed.Add(new ChangedFile(path, ChangedFileOperation.Modified));
            }
            return changed;
        }
        catch
        {
            // File tracking is diagnostic only; never fail an agent turn.
            return Array.Empty<ChangedFile>();
        }
    }

    private static Dictionary<string, Signature> Snapshot(string root)
    {
        var result = new Dictionary<string, Signature>(StringComparer.OrdinalIgnoreCase);
        var pending = new Stack<(string Path, int Depth)>();
        pending.Push((root, 0));
        while (pending.Count > 0 && result.Count < MaximumEntries)
        {
            var (directory, depth) = pending.Pop();
            if (depth > MaximumDepth || IsSymlink(directory)) continue;

            IEnumerable<string> files;
            try { files = Directory.EnumerateFiles(directory); } catch { continue; }
            foreach (var file in files)
            {
                if (result.Count >= MaximumEntries || IsIgnored(file) || IsSymlink(file)) continue;
                try
                {
                    var info = new FileInfo(file);
                    result[Relative(root, file)] = new Signature(info.Length, info.LastWriteTimeUtc.Ticks);
                }
                catch { }
            }

            if (depth == MaximumDepth) continue;
            IEnumerable<string> directories;
            try { directories = Directory.EnumerateDirectories(directory); } catch { continue; }
            foreach (var child in directories)
            {
                if (!IsIgnored(child) && !IsSymlink(child)) pending.Push((child, depth + 1));
            }
        }
        return result;
    }

    private static string Relative(string root, string path) =>
        Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/');

    private static bool IsIgnored(string path)
    {
        var name = Path.GetFileName(path);
        return name.Equals(".git", StringComparison.OrdinalIgnoreCase)
            || name.Equals(".mem", StringComparison.OrdinalIgnoreCase);
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
