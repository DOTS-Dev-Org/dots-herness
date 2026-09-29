// Copyright (c) 2026 DOTS
// Persistent, conflict-aware workspace snapshots used by conversation rewind.
// Port of macOS WorkspaceSnapshotStore.swift for the Windows and Linux shells.
//
// Before a turn every tracked file is hashed and copied under <support>/rewind/<conversation>/<turn>/before;
// after it, the tree is hashed again. Restoring puts back exactly the files that turn changed and refuses to
// overwrite a file the user has edited since (a conflict), unless told to restore around it.
//
// Difference from macOS: a snapshot is refused (rewind simply stays unavailable for that turn) when the tree
// is larger than MaxFiles / MaxBytes, so a huge workspace cannot silently fill the disk.

using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text.Json;
using PluginRuntime;

namespace DotsHarnessCore;

public sealed record RewindResult(IReadOnlyList<string> RestoredPaths, IReadOnlyList<string> ConflictPaths)
{
    public RewindResult() : this(Array.Empty<string>(), Array.Empty<string>()) { }
}

public sealed class WorkspaceSnapshotException : Exception
{
    public bool Unavailable { get; }
    public WorkspaceSnapshotException(string message, bool unavailable = false) : base(message) => Unavailable = unavailable;
}

public sealed class WorkspaceSnapshotStore
{
    public const int MaxFiles = 50_000;
    public const long MaxBytes = 1L << 30;

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private static readonly HashSet<string> IgnoredDirectories = new(StringComparer.Ordinal)
    {
        ".git", ".mem", ".build", "build", "bin", "obj", "dist", "node_modules", "Pods", "DerivedData",
    };

    public sealed record FileState(string Hash, long Bytes, int Permissions);

    private sealed class Snapshot
    {
        public int Version { get; set; } = 1;
        public string ConversationId { get; set; } = "";
        public string TurnId { get; set; } = "";
        public string WorkspacePath { get; set; } = "";
        public Dictionary<string, FileState> Before { get; set; } = new();
        public Dictionary<string, FileState>? After { get; set; }
        public List<ChangedFile> ChangedFiles { get; set; } = new();
        public bool Complete { get; set; }
    }

    private abstract record Observation
    {
        public sealed record Missing : Observation;
        public sealed record File(FileState State, byte[] Data) : Observation;
        public sealed record Other : Observation;
    }

    private readonly string _root;

    public WorkspaceSnapshotStore(SupportPaths paths) : this(Path.Combine(paths.Root, "rewind")) { }

    public WorkspaceSnapshotStore(string root) => _root = root;

    // MARK: Capture

    /// <summary>Snapshots the workspace before a turn. False means rewind is unavailable for this turn.</summary>
    public bool Begin(string conversationId, string turnId, string workspace)
    {
        var directory = SnapshotDirectory(conversationId, turnId);
        try
        {
            if (Directory.Exists(directory)) return false;
            var before = Path.Combine(directory, "before");
            Directory.CreateDirectory(before);
            var state = Capture(workspace, before);
            Write(new Snapshot
            {
                ConversationId = conversationId,
                TurnId = turnId,
                WorkspacePath = Canonical(workspace),
                Before = state,
            }, ManifestPath(directory));
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or WorkspaceSnapshotException or JsonException)
        {
            TryDelete(directory);
            return false;
        }
    }

    public WorkspaceChangeResult FinishResult(string conversationId, string turnId, string workspace)
    {
        var directory = SnapshotDirectory(conversationId, turnId);
        try
        {
            var snapshot = Read(ManifestPath(directory));
            if (snapshot.ConversationId != conversationId || snapshot.TurnId != turnId
                || !SamePath(snapshot.WorkspacePath, Canonical(workspace)))
                return new WorkspaceChangeResult([], "incomplete", "Snapshot identity did not match.");
            var after = Capture(workspace, null);
            var changed = ChangedFilesBetween(snapshot.Before, after);
            snapshot.After = after;
            snapshot.ChangedFiles = changed.ToList();
            snapshot.Complete = true;
            Write(snapshot, ManifestPath(directory));
            return new WorkspaceChangeResult(changed, "complete", null);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or WorkspaceSnapshotException or JsonException)
        {
            return new WorkspaceChangeResult([], "incomplete", e.Message);
        }
    }

    public bool HasCompleteSnapshot(string conversationId, string turnId, string workspace)
    {
        try
        {
            var snapshot = Read(ManifestPath(SnapshotDirectory(conversationId, turnId)));
            return snapshot.ConversationId == conversationId
                && snapshot.TurnId == turnId
                && snapshot.Complete
                && snapshot.After is not null
                && SamePath(snapshot.WorkspacePath, Canonical(workspace))
                && BeforeBackupsExist(snapshot);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or WorkspaceSnapshotException or JsonException)
        {
            return false;
        }
    }

    // MARK: Restore

    /// <summary>
    /// Puts the workspace back to how it was before the first of <paramref name="turnIds"/> (oldest first).
    /// A file changed by the user after the turns is a conflict: with <paramref name="abortOnConflict"/> nothing
    /// is touched and the conflicts are reported; without it every other file is still restored.
    /// </summary>
    public RewindResult Restore(string conversationId, IReadOnlyList<string> turnIds, string workspace, bool abortOnConflict)
    {
        if (turnIds.Count == 0) throw new WorkspaceSnapshotException("No turns to restore.", unavailable: true);
        var snapshots = turnIds.Select(turnId =>
        {
            var snapshot = Read(ManifestPath(SnapshotDirectory(conversationId, turnId)));
            if (snapshot.ConversationId != conversationId || snapshot.TurnId != turnId)
                throw new WorkspaceSnapshotException("Snapshot does not match.", unavailable: true);
            return snapshot;
        }).ToList();
        var canonicalWorkspace = Canonical(workspace);
        if (!snapshots.All(s => s.Complete && s.After is not null && SamePath(s.WorkspacePath, canonicalWorkspace) && BeforeBackupsExist(s)))
            throw new WorkspaceSnapshotException("Snapshot is incomplete.", unavailable: true);

        var first = snapshots[0];
        var lastAfter = snapshots[^1].After!;
        var changedPaths = first.Before.Keys.Union(lastAfter.Keys)
            .Where(path => !SameState(first.Before.GetValueOrDefault(path), lastAfter.GetValueOrDefault(path)))
            .OrderBy(path => path, StringComparer.Ordinal)
            .ToList();
        if (changedPaths.Count == 0) return new RewindResult();

        var observations = new Dictionary<string, Observation>(StringComparer.Ordinal);
        var conflicts = new List<string>();
        foreach (var path in changedPaths)
        {
            var observation = Observe(path, workspace);
            observations[path] = observation;
            if (!Matches(observation, lastAfter.GetValueOrDefault(path)) && !Matches(observation, first.Before.GetValueOrDefault(path)))
                conflicts.Add(path);
        }
        conflicts.Sort(StringComparer.Ordinal);
        if (abortOnConflict && conflicts.Count > 0) return new RewindResult(Array.Empty<string>(), conflicts);

        var restored = new List<string>();
        try
        {
            foreach (var path in changedPaths.Where(p => !conflicts.Contains(p)))
            {
                // The user may already have put this path back; that is a safe no-op.
                if (Matches(observations[path], first.Before.GetValueOrDefault(path))) continue;
                RestorePath(path, first.Before.GetValueOrDefault(path), first, observations[path], workspace);
                restored.Add(path);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or WorkspaceSnapshotException)
        {
            // Undo what this call already did so a failed rewind never leaves a half-restored tree.
            foreach (var path in restored)
            {
                try { RestoreObservation(observations[path], path, workspace); }
                catch (Exception undo) when (undo is IOException or UnauthorizedAccessException) { }
            }
            throw new WorkspaceSnapshotException(restored.LastOrDefault() ?? "workspace");
        }
        return new RewindResult(restored, conflicts);
    }

    public void RemoveConversation(string conversationId) =>
        TryDelete(Path.Combine(_root, SafeComponent(conversationId)));

    // MARK: Internals

    private Dictionary<string, FileState> Capture(string workspace, string? backupDirectory)
    {
        var root = Canonical(workspace);
        var entries = new List<(string Path, string Relative)>();
        var pending = new Stack<string>();
        pending.Push(root);
        long total = 0;
        while (pending.Count > 0)
        {
            var directory = pending.Pop();
            foreach (var entry in new DirectoryInfo(directory).EnumerateFileSystemInfos())
            {
                if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint) || entry.LinkTarget is not null) continue;
                if (entry is DirectoryInfo child)
                {
                    if (!IgnoredDirectories.Contains(child.Name)) pending.Push(child.FullName);
                    continue;
                }
                entries.Add((entry.FullName, RelativePath(entry.FullName, root)));
                total += ((FileInfo)entry).Length;
                if (entries.Count > MaxFiles || total > MaxBytes)
                    throw new WorkspaceSnapshotException("The workspace is too large to snapshot.", unavailable: true);
            }
        }

        // Files are independent; on a slow or cold disk overlapping them costs far less than their sum.
        var states = new ConcurrentDictionary<string, FileState>(StringComparer.Ordinal);
        var failure = (Exception?)null;
        Parallel.ForEach(entries, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(2, Environment.ProcessorCount) }, (entry, loop) =>
        {
            try
            {
                var data = File.ReadAllBytes(entry.Path);
                var permissions = PermissionsOf(entry.Path);
                if (backupDirectory is not null)
                {
                    var destination = Path.Combine(backupDirectory, entry.Relative.Replace('/', Path.DirectorySeparatorChar));
                    Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                    File.WriteAllBytes(destination, data);
                    SetPermissions(destination, permissions);
                }
                states[entry.Relative] = new FileState(Digest(data), data.LongLength, permissions);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Interlocked.CompareExchange(ref failure, e, null);
                loop.Stop();
            }
        });
        if (failure is not null) throw failure;
        return new Dictionary<string, FileState>(states, StringComparer.Ordinal);
    }

    private static IReadOnlyList<ChangedFile> ChangedFilesBetween(
        Dictionary<string, FileState> before, Dictionary<string, FileState> after) =>
        before.Keys.Union(after.Keys)
            .Where(path => !SameState(before.GetValueOrDefault(path), after.GetValueOrDefault(path)))
            .Select(path => new ChangedFile(path, (before.ContainsKey(path), after.ContainsKey(path)) switch
            {
                (false, true) => ChangedFileOperation.Added,
                (true, false) => ChangedFileOperation.Deleted,
                _ => ChangedFileOperation.Modified,
            }))
            .OrderBy(file => file.Path, StringComparer.Ordinal)
            .ToList();

    private Observation Observe(string path, string workspace)
    {
        var file = SafePath(path, workspace);
        if (Directory.Exists(file)) return new Observation.Other();
        if (!File.Exists(file)) return new Observation.Missing();
        var info = new FileInfo(file);
        if (info.LinkTarget is not null || info.Attributes.HasFlag(FileAttributes.ReparsePoint)) return new Observation.Other();
        var data = File.ReadAllBytes(file);
        return new Observation.File(new FileState(Digest(data), data.LongLength, PermissionsOf(file)), data);
    }

    private static bool Matches(Observation observation, FileState? expected) => (observation, expected) switch
    {
        (Observation.Missing, null) => true,
        (Observation.File actual, { } state) => SameState(actual.State, state),
        _ => false,
    };

    /// <summary>Content identity; permissions only count where the platform records them.</summary>
    private static bool SameState(FileState? left, FileState? right)
    {
        if (left is null || right is null) return left is null && right is null;
        return left.Hash == right.Hash && left.Bytes == right.Bytes
            && (OperatingSystem.IsWindows() || left.Permissions == right.Permissions);
    }

    private void RestorePath(string path, FileState? initial, Snapshot snapshot, Observation observation, string workspace)
    {
        var file = SafePath(path, workspace);
        if (initial is null)
        {
            if (observation is not Observation.File) throw new WorkspaceSnapshotException(path);
            File.Delete(file);
            return;
        }
        var backup = BackupPath(path, snapshot) ?? throw new WorkspaceSnapshotException(path);
        var data = File.ReadAllBytes(backup);
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllBytes(file, data);
        SetPermissions(file, initial.Permissions);
    }

    private void RestoreObservation(Observation observation, string path, string workspace)
    {
        var file = SafePath(path, workspace);
        switch (observation)
        {
            case Observation.Missing:
                if (File.Exists(file)) File.Delete(file);
                break;
            case Observation.File current:
                Directory.CreateDirectory(Path.GetDirectoryName(file)!);
                File.WriteAllBytes(file, current.Data);
                SetPermissions(file, current.State.Permissions);
                break;
        }
    }

    private bool BeforeBackupsExist(Snapshot snapshot)
    {
        var before = Path.Combine(SnapshotDirectory(snapshot.ConversationId, snapshot.TurnId), "before");
        foreach (var (path, state) in snapshot.Before)
        {
            var backup = SafeBackupPath(path, before);
            if (backup is null || !File.Exists(backup) || new FileInfo(backup).Length != state.Bytes) return false;
        }
        return true;
    }

    private string? BackupPath(string path, Snapshot snapshot) =>
        SafeBackupPath(path, Path.Combine(SnapshotDirectory(snapshot.ConversationId, snapshot.TurnId), "before"));

    private static string? SafeBackupPath(string path, string directory)
    {
        if (path.Length == 0) return null;
        var root = Path.GetFullPath(directory);
        var full = Path.GetFullPath(Path.Combine(root, path.Replace('/', Path.DirectorySeparatorChar)));
        return full.StartsWith(root + Path.DirectorySeparatorChar, PathComparison) ? full : null;
    }

    private static string SafePath(string path, string workspace)
    {
        if (path.Length == 0) throw new WorkspaceSnapshotException("Invalid path.");
        var root = Canonical(workspace);
        var full = Path.GetFullPath(Path.Combine(root, path.Replace('/', Path.DirectorySeparatorChar)));
        if (!full.StartsWith(root + Path.DirectorySeparatorChar, PathComparison))
            throw new WorkspaceSnapshotException("Invalid path.");
        return full;
    }

    private static string RelativePath(string file, string root)
    {
        var relative = Path.GetRelativePath(root, file).Replace(Path.DirectorySeparatorChar, '/');
        if (relative.Length == 0 || relative.Split('/').Any(part => part is "." or ".."))
            throw new WorkspaceSnapshotException("Invalid path.");
        return relative;
    }

    private static readonly StringComparison PathComparison =
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    private static bool SamePath(string left, string right) => string.Equals(left, right, PathComparison);

    private static string Canonical(string path) => SandboxWorkspaces.Normalize(path);

    private string SnapshotDirectory(string conversationId, string turnId) =>
        Path.Combine(_root, SafeComponent(conversationId), SafeComponent(turnId));

    private static string ManifestPath(string directory) => Path.Combine(directory, "manifest.json");

    private static string SafeComponent(string value)
    {
        var component = new string(value.Select(c => char.IsLetterOrDigit(c) || c is '-' or '_' ? c : '_').ToArray());
        return component[..Math.Min(100, component.Length)];
    }

    private static Snapshot Read(string path)
    {
        var snapshot = JsonSerializer.Deserialize<Snapshot>(File.ReadAllText(path), Json)
            ?? throw new WorkspaceSnapshotException("Snapshot is unreadable.", unavailable: true);
        if (snapshot.Version != 1) throw new WorkspaceSnapshotException("Unsupported snapshot version.", unavailable: true);
        return snapshot;
    }

    private static void Write(Snapshot snapshot, string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(snapshot, Json));
        File.Move(temporary, path, overwrite: true);
    }

    private static string Digest(byte[] data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    private static int PermissionsOf(string path)
    {
        if (OperatingSystem.IsWindows()) return 0;
        try { return (int)File.GetUnixFileMode(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return 0; }
    }

    private static void SetPermissions(string path, int permissions)
    {
        if (OperatingSystem.IsWindows() || permissions == 0) return;
        try { File.SetUnixFileMode(path, (UnixFileMode)permissions); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private static void TryDelete(string directory)
    {
        try { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
