// Copyright (c) 2026 DOTS
// Git-independent, content-addressed snapshots for agent workspace turns.

using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace DotsHarnessCore;

public sealed class WorkspaceVersionStore
{
    private const int MaximumEntries = 5_000;
    private const int MaximumDepth = 12;
    private const long MaximumFileBytes = 64L * 1024 * 1024;
    private const long MaximumCaptureBytes = 1024L * 1024 * 1024;
    private const int MaximumDiffLines = 4_096;
    private const int MaximumEditDistance = 256;

    private readonly string _root;
    private readonly string _blobRoot;
    private readonly string _manifestRoot;
    private readonly object _gate = new();
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = false };

    internal sealed record FileVersion(string Hash, long Bytes, int UnixMode, bool ReadOnly);

    private sealed class Manifest
    {
        public int Version { get; set; } = 1;
        public string ConversationId { get; set; } = "";
        public string TurnId { get; set; } = "";
        public string WorkspacePath { get; set; } = "";
        public Dictionary<string, FileVersion> Before { get; set; } = new(StringComparer.Ordinal);
        public Dictionary<string, FileVersion> After { get; set; } = new(StringComparer.Ordinal);
        public List<ChangedFile> ChangedFiles { get; set; } = [];
        public bool Complete { get; set; }
        public bool Undone { get; set; }
        public string? Failure { get; set; }
    }

    internal sealed record CaptureState(
        Dictionary<string, FileVersion> Files,
        bool Complete,
        string? Failure);

    private sealed record RestorePlan(
        string RelativePath,
        string Destination,
        FileVersion? Before,
        string? StagedPath,
        string? BackupPath);

    public WorkspaceVersionStore(string applicationRuntimeDirectory)
    {
        _root = Path.Combine(applicationRuntimeDirectory, "workspace-versions");
        _blobRoot = Path.Combine(_root, "blobs");
        _manifestRoot = Path.Combine(_root, "turns");
    }

    public WorkspaceVersionCapture? Begin(string conversationId, string turnId, string workspace)
    {
        try
        {
            var root = Path.GetFullPath(workspace);
            if (!Directory.Exists(root) || IsLink(root)) return null;
            var before = Capture(root, storeBlobs: true);
            return new WorkspaceVersionCapture(this, conversationId, turnId, root, before);
        }
        catch
        {
            return null;
        }
    }

    public WorkspaceRestoreResult RestoreTurn(
        string conversationId,
        string turnId,
        string workspace) => RestoreRange(conversationId, [turnId], workspace);

    public WorkspaceRestoreResult RestoreRange(
        string conversationId,
        IReadOnlyList<string> turnIds,
        string workspace)
    {
        if (turnIds.Count == 0) return WorkspaceRestoreResult.Unavailable;
        lock (_gate)
        {
            try
            {
                var manifests = turnIds.Select(turnId => ReadManifest(conversationId, turnId)).ToList();
                if (manifests.Any(manifest => manifest is null)) return WorkspaceRestoreResult.Unavailable;
                var versions = manifests.Cast<Manifest>().ToList();
                var workspacePath = Path.GetFullPath(workspace);
                if (versions.Any(manifest => !manifest.Complete
                    || !SameWorkspace(manifest.WorkspacePath, workspacePath)
                    || !manifest.Undone && !BeforeBlobsExist(manifest)))
                {
                    return WorkspaceRestoreResult.Unavailable;
                }

                var first = versions[0];
                var last = versions[^1];
                var changedPaths = first.Before.Keys.Union(last.After.Keys, PathComparer())
                    .Where(path => !SameVersion(GetVersion(first.Before, path), GetVersion(last.After, path)))
                    .OrderBy(path => path, PathComparer())
                    .ToList();
                if (changedPaths.Count == 0)
                {
                    foreach (var manifest in versions) manifest.Undone = true;
                    PersistManifests(versions);
                    return new WorkspaceRestoreResult(true, [], []);
                }

                var conflicts = new List<string>();
                foreach (var path in changedPaths)
                {
                    var expected = GetVersion(last.After, path);
                    var initial = GetVersion(first.Before, path);
                    var current = Observe(path, workspacePath);
                    if (!SameVersion(current, expected) && !SameVersion(current, initial)) conflicts.Add(path);
                }
                if (conflicts.Count > 0) return new WorkspaceRestoreResult(false, [], conflicts);

                var applied = ApplyRestore(changedPaths, first.Before, workspacePath);
                if (!applied.Succeeded) return applied;
                foreach (var manifest in versions) manifest.Undone = true;
                PersistManifests(versions);
                return applied;
            }
            catch (Exception ex)
            {
                return new WorkspaceRestoreResult(false, [], [], ex.Message);
            }
        }
    }

    private WorkspaceChangeResult Finish(
        WorkspaceVersionCapture capture,
        CaptureState before)
    {
        try
        {
            var after = Capture(capture.WorkspacePath, storeBlobs: true);
            var changedFiles = before.Files.Keys.Union(after.Files.Keys, PathComparer())
                .Select(path => (Path: path, Before: GetVersion(before.Files, path), After: GetVersion(after.Files, path)))
                .Where(change => !SameVersion(change.Before, change.After))
                .Select(change => MakeChangedFile(change.Path, change.Before, change.After))
                .OrderBy(file => file.Path, PathComparer())
                .ToList();
            var complete = before.Complete && after.Complete;
            var manifest = new Manifest
            {
                ConversationId = capture.ConversationId,
                TurnId = capture.TurnId,
                WorkspacePath = capture.WorkspacePath,
                Before = before.Files,
                After = after.Files,
                ChangedFiles = changedFiles,
                Complete = complete,
                Failure = before.Failure ?? after.Failure,
            };
            lock (_gate) WriteManifest(manifest);
            return new WorkspaceChangeResult(
                changedFiles,
                complete ? "complete" : "incomplete",
                manifest.Failure);
        }
        catch (Exception ex)
        {
            return new WorkspaceChangeResult([], "incomplete", ex.Message);
        }
    }

    private CaptureState Capture(string workspace, bool storeBlobs)
    {
        var files = new Dictionary<string, FileVersion>(PathComparer());
        var pending = new Stack<(string Path, int Depth)>();
        pending.Push((workspace, 0));
        var complete = true;
        string? failure = null;
        long totalBytes = 0;

        while (pending.Count > 0 && files.Count < MaximumEntries)
        {
            var (directory, depth) = pending.Pop();
            if (IsLink(directory))
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

            IEnumerable<string> entries;
            try { entries = Directory.EnumerateFiles(directory).ToArray(); }
            catch (Exception ex)
            {
                complete = false;
                failure ??= ex.Message;
                continue;
            }

            foreach (var path in entries)
            {
                if (files.Count >= MaximumEntries) break;
                if (WorkspaceChangeTracker.IsIgnored(path)) continue;
                if (IsLink(path))
                {
                    complete = false;
                    failure ??= "A symbolic-link file could not be inspected.";
                    continue;
                }

                try
                {
                    var info = new FileInfo(path);
                    if (info.Length > MaximumFileBytes || totalBytes + info.Length > MaximumCaptureBytes)
                    {
                        complete = false;
                        failure ??= "Workspace snapshot size limit reached.";
                        continue;
                    }
                    totalBytes += info.Length;
                    var version = CaptureFile(path, storeBlobs);
                    files[Relative(workspace, path)] = version;
                }
                catch (Exception ex)
                {
                    complete = false;
                    failure ??= ex.Message;
                }
            }

            if (depth >= MaximumDepth) continue;
            IEnumerable<string> children;
            try { children = Directory.EnumerateDirectories(directory).ToArray(); }
            catch (Exception ex)
            {
                complete = false;
                failure ??= ex.Message;
                continue;
            }

            foreach (var child in children)
            {
                if (WorkspaceChangeTracker.IsIgnored(child)) continue;
                if (IsLink(child))
                {
                    complete = false;
                    failure ??= "A symbolic-link directory could not be inspected.";
                    continue;
                }
                pending.Push((child, depth + 1));
            }
        }

        if (pending.Count > 0 || files.Count >= MaximumEntries)
        {
            complete = false;
            failure ??= "Workspace entry limit reached.";
        }
        return new CaptureState(files, complete, failure);
    }

    private FileVersion CaptureFile(string path, bool storeBlob)
    {
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var before = new FileInfo(path);
            var length = before.Length;
            var modified = before.LastWriteTimeUtc.Ticks;
            string hash;
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                hash = Convert.ToHexString(SHA256.HashData(stream));
            var after = new FileInfo(path);
            if (length != after.Length || modified != after.LastWriteTimeUtc.Ticks) continue;

            if (storeBlob) StoreBlob(path, hash, length, modified);
            var attributes = File.GetAttributes(path);
            var mode = OperatingSystem.IsWindows() ? -1 : (int)File.GetUnixFileMode(path);
            return new FileVersion(hash, length, mode, attributes.HasFlag(FileAttributes.ReadOnly));
        }
        throw new IOException("The file changed while its version was being captured.");
    }

    private void StoreBlob(string source, string hash, long length, long modified)
    {
        var destination = BlobPath(hash);
        if (File.Exists(destination)) return;
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        var temporary = Path.Combine(_blobRoot, "." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            File.Copy(source, temporary);
            var info = new FileInfo(source);
            if (info.Length != length || info.LastWriteTimeUtc.Ticks != modified || HashFile(temporary) != hash)
                throw new IOException("The file changed while its version copy was being saved.");
            try { File.Move(temporary, destination); }
            catch (IOException) when (File.Exists(destination) && HashFile(destination) == hash) { }
        }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); } catch { }
        }
    }

    private ChangedFile MakeChangedFile(string path, FileVersion? before, FileVersion? after)
    {
        var oldBytes = before is null ? null : ReadBlob(before.Hash);
        var newBytes = after is null ? null : ReadBlob(after.Hash);
        var diff = TextLineChanges(oldBytes, newBytes);
        var operation = before is null ? ChangedFileOperation.Added
            : after is null ? ChangedFileOperation.Deleted
            : ChangedFileOperation.Modified;
        return new ChangedFile(path, operation)
        {
            AddedLines = diff.Added,
            DeletedLines = diff.Deleted,
            Preview = diff.Preview,
        };
    }

    private readonly record struct LineEdit(char Kind, string Text);

    private static (int Added, int Deleted, string? Preview) TextLineChanges(byte[]? before, byte[]? after)
    {
        var oldLines = DecodeLines(before);
        var newLines = DecodeLines(after);
        if (oldLines is null || newLines is null) return (-1, -1, null);
        var prefix = 0;
        while (prefix < oldLines.Length && prefix < newLines.Length && oldLines[prefix] == newLines[prefix]) prefix++;
        var suffix = 0;
        while (suffix < oldLines.Length - prefix && suffix < newLines.Length - prefix
            && oldLines[oldLines.Length - 1 - suffix] == newLines[newLines.Length - 1 - suffix]) suffix++;
        var allOldLines = oldLines;
        var allNewLines = newLines;
        oldLines = oldLines[prefix..(oldLines.Length - suffix)];
        newLines = newLines[prefix..(newLines.Length - suffix)];
        if (oldLines.Length + newLines.Length > MaximumDiffLines) return (-1, -1, null);

        var max = oldLines.Length + newLines.Length;
        var offset = max;
        var v = new int[2 * max + 3];
        v[offset + 1] = 0;
        var trace = new List<int[]>();
        for (var distance = 0; distance <= max; distance++)
        {
            if (distance > MaximumEditDistance) return (-1, -1, null);
            trace.Add((int[])v.Clone());
            for (var diagonal = -distance; diagonal <= distance; diagonal += 2)
            {
                var index = offset + diagonal;
                var x = diagonal == -distance || diagonal != distance && v[index - 1] < v[index + 1]
                    ? v[index + 1]
                    : v[index - 1] + 1;
                var y = x - diagonal;
                while (x < oldLines.Length && y < newLines.Length && oldLines[x] == newLines[y]) { x++; y++; }
                v[index] = x;
                if (x >= oldLines.Length && y >= newLines.Length)
                {
                    var edits = BacktrackLineEdits(trace, distance, oldLines, newLines, offset);
                    var added = edits.Count(edit => edit.Kind == '+');
                    var deleted = edits.Count(edit => edit.Kind == '-');
                    return (added, deleted, BuildPreview(edits, allOldLines, allNewLines, prefix, suffix));
                }
            }
        }
        return (-1, -1, null);
    }

    private static List<LineEdit> BacktrackLineEdits(
        IReadOnlyList<int[]> trace,
        int distance,
        string[] oldLines,
        string[] newLines,
        int offset)
    {
        var x = oldLines.Length;
        var y = newLines.Length;
        var edits = new List<LineEdit>(x + y);
        for (var d = distance; d > 0; d--)
        {
            var previous = trace[d];
            var diagonal = x - y;
            var previousDiagonal = diagonal == -d || diagonal != d
                && previous[offset + diagonal - 1] < previous[offset + diagonal + 1]
                    ? diagonal + 1
                    : diagonal - 1;
            var previousX = previous[offset + previousDiagonal];
            var previousY = previousX - previousDiagonal;
            while (x > previousX && y > previousY)
            {
                edits.Add(new LineEdit(' ', oldLines[--x]));
                y--;
            }
            if (x == previousX) edits.Add(new LineEdit('+', newLines[--y]));
            else edits.Add(new LineEdit('-', oldLines[--x]));
        }
        while (x > 0 && y > 0)
        {
            edits.Add(new LineEdit(' ', oldLines[--x]));
            y--;
        }
        while (x > 0) edits.Add(new LineEdit('-', oldLines[--x]));
        while (y > 0) edits.Add(new LineEdit('+', newLines[--y]));
        edits.Reverse();
        return edits;
    }

    private static string? BuildPreview(
        IReadOnlyList<LineEdit> edits,
        string[] oldLines,
        string[] newLines,
        int commonPrefix,
        int commonSuffix)
    {
        const int maximumRows = 42;
        const int contextRows = 3;
        var firstChange = -1;
        for (var index = 0; index < edits.Count; index++)
        {
            if (edits[index].Kind is '+' or '-') { firstChange = index; break; }
        }
        if (firstChange < 0) return null;

        var rows = new List<string>(maximumRows);
        for (var index = Math.Max(0, commonPrefix - contextRows); index < commonPrefix; index++)
            rows.Add($"  {index + 1,4} │ {oldLines[index]}");

        var operationStart = Math.Max(0, firstChange - contextRows);
        var oldLine = commonPrefix + 1 + edits.Take(operationStart).Count(edit => edit.Kind != '+');
        var newLine = commonPrefix + 1 + edits.Take(operationStart).Count(edit => edit.Kind != '-');
        var operationCapacity = Math.Max(1, maximumRows - rows.Count - 1);
        var operationCount = Math.Min(edits.Count - operationStart, operationCapacity);
        for (var index = operationStart; index < operationStart + operationCount; index++)
        {
            var edit = edits[index];
            switch (edit.Kind)
            {
                case ' ':
                    rows.Add($"  {newLine++,4} │ {edit.Text}");
                    oldLine++;
                    break;
                case '-': rows.Add($"− {oldLine++,4} │ {edit.Text}"); break;
                case '+': rows.Add($"+ {newLine++,4} │ {edit.Text}"); break;
            }
        }

        if (operationStart + operationCount < edits.Count)
        {
            if (rows.Count < maximumRows) rows.Add("  …");
        }
        else
        {
            var suffixRows = Math.Min(contextRows, commonSuffix);
            for (var index = 0; index < suffixRows && rows.Count < maximumRows; index++)
            {
                var lineNumber = newLines.Length - commonSuffix + index + 1;
                rows.Add($"  {lineNumber,4} │ {newLines[newLines.Length - commonSuffix + index]}");
            }
        }

        var preview = string.Join('\n', rows);
        return preview.Length <= 12_000 ? preview : preview[..12_000];
    }

    private static string[]? DecodeLines(byte[]? bytes)
    {
        if (bytes is null || bytes.Length == 0) return [];
        if (bytes.AsSpan(0, Math.Min(bytes.Length, 8192)).Contains((byte)0)) return null;
        try
        {
            var text = new UTF8Encoding(false, true).GetString(bytes).Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
            var lines = text.Split('\n');
            return lines.Length > 1 && lines[^1].Length == 0 ? lines[..^1] : lines;
        }
        catch (DecoderFallbackException) { return null; }
    }

    private WorkspaceRestoreResult ApplyRestore(
        IReadOnlyList<string> paths,
        IReadOnlyDictionary<string, FileVersion> before,
        string workspace)
    {
        var plans = new List<RestorePlan>();
        try
        {
            foreach (var relative in paths)
            {
                var destination = ResolvePath(workspace, relative);
                var target = GetVersion(before, relative);
                string? staged = null;
                if (target is not null)
                {
                    VerifyBlob(target.Hash);
                    Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                    staged = Path.Combine(Path.GetDirectoryName(destination)!, ".dots-harness-restore-" + Guid.NewGuid().ToString("N"));
                    try { File.Copy(BlobPath(target.Hash), staged); }
                    catch
                    {
                        try { if (File.Exists(staged)) File.Delete(staged); } catch { }
                        throw;
                    }
                }
                plans.Add(new RestorePlan(relative, destination, target, staged, null));
            }

            var applied = new List<RestorePlan>();
            try
            {
                foreach (var plan in plans)
                {
                    string? backup = null;
                    if (File.Exists(plan.Destination))
                    {
                        backup = Path.Combine(Path.GetDirectoryName(plan.Destination)!, ".dots-harness-backup-" + Guid.NewGuid().ToString("N"));
                        File.Move(plan.Destination, backup);
                    }
                    var appliedPlan = plan with { BackupPath = backup };
                    applied.Add(appliedPlan);
                    if (plan.StagedPath is not null) File.Move(plan.StagedPath, plan.Destination);
                    if (plan.Before is { } target)
                    {
                        if (!OperatingSystem.IsWindows() && target.UnixMode >= 0)
                            File.SetUnixFileMode(plan.Destination, (UnixFileMode)target.UnixMode);
                        var attributes = File.GetAttributes(plan.Destination);
                        File.SetAttributes(
                            plan.Destination,
                            target.ReadOnly ? attributes | FileAttributes.ReadOnly : attributes & ~FileAttributes.ReadOnly);
                    }
                }
            }
            catch
            {
                foreach (var plan in applied.AsEnumerable().Reverse())
                {
                    try
                    {
                        if (File.Exists(plan.Destination))
                        {
                            File.SetAttributes(plan.Destination, File.GetAttributes(plan.Destination) & ~FileAttributes.ReadOnly);
                            File.Delete(plan.Destination);
                        }
                    }
                    catch { }
                    try { if (plan.BackupPath is not null && File.Exists(plan.BackupPath)) File.Move(plan.BackupPath, plan.Destination); } catch { }
                }
                throw;
            }

            foreach (var plan in plans)
            {
                try
                {
                    if (plan.BackupPath is not null && File.Exists(plan.BackupPath))
                    {
                        File.SetAttributes(plan.BackupPath, File.GetAttributes(plan.BackupPath) & ~FileAttributes.ReadOnly);
                        File.Delete(plan.BackupPath);
                    }
                }
                catch { }
                try { if (plan.StagedPath is not null && File.Exists(plan.StagedPath)) File.Delete(plan.StagedPath); } catch { }
            }
            return new WorkspaceRestoreResult(true, paths.ToList(), []);
        }
        catch (Exception ex)
        {
            foreach (var plan in plans)
            {
                try { if (plan.StagedPath is not null && File.Exists(plan.StagedPath)) File.Delete(plan.StagedPath); } catch { }
            }
            return new WorkspaceRestoreResult(false, [], [], ex.Message);
        }
    }

    private FileVersion? Observe(string relative, string workspace)
    {
        var path = ResolvePath(workspace, relative);
        if (!File.Exists(path))
        {
            if (Directory.Exists(path)) throw new IOException("A directory replaced a tracked file.");
            return null;
        }
        if (IsLink(path)) throw new IOException("A symbolic link replaced a tracked file.");
        return CaptureFile(path, storeBlob: false);
    }

    private void PersistManifests(IEnumerable<Manifest> manifests)
    {
        foreach (var manifest in manifests) WriteManifest(manifest);
    }

    private void WriteManifest(Manifest manifest)
    {
        Directory.CreateDirectory(_manifestRoot);
        var path = ManifestPath(manifest.ConversationId, manifest.TurnId);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(manifest, JsonOptions));
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); } catch { }
        }
    }

    private Manifest? ReadManifest(string conversationId, string turnId)
    {
        try
        {
            var path = ManifestPath(conversationId, turnId);
            if (!File.Exists(path)) return null;
            var manifest = JsonSerializer.Deserialize<Manifest>(File.ReadAllBytes(path), JsonOptions);
            if (manifest is not { Version: 1 }
                || manifest.ConversationId != conversationId
                || manifest.TurnId != turnId) return null;
            manifest.Before = new Dictionary<string, FileVersion>(manifest.Before, PathComparer());
            manifest.After = new Dictionary<string, FileVersion>(manifest.After, PathComparer());
            return manifest;
        }
        catch { return null; }
    }

    private bool BeforeBlobsExist(Manifest manifest) => manifest.Before.Values.All(version => File.Exists(BlobPath(version.Hash)));

    private byte[] ReadBlob(string hash)
    {
        var path = BlobPath(hash);
        var bytes = File.ReadAllBytes(path);
        if (Convert.ToHexString(SHA256.HashData(bytes)) != hash) throw new IOException("A saved workspace version is corrupt.");
        return bytes;
    }

    private void VerifyBlob(string hash)
    {
        if (!File.Exists(BlobPath(hash)) || HashFile(BlobPath(hash)) != hash)
            throw new IOException("A saved workspace version is unavailable.");
    }

    private string BlobPath(string hash) => Path.Combine(_blobRoot, hash[..2], hash);

    private string ManifestPath(string conversationId, string turnId)
    {
        var key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(conversationId + "\0" + turnId)));
        return Path.Combine(_manifestRoot, key + ".json");
    }

    private static FileVersion? GetVersion(IReadOnlyDictionary<string, FileVersion> versions, string path) =>
        versions.TryGetValue(path, out var version) ? version : null;

    private static bool SameVersion(FileVersion? left, FileVersion? right) =>
        left is null ? right is null : right is not null && left == right;

    private static string ResolvePath(string workspace, string relative)
    {
        if (string.IsNullOrWhiteSpace(relative)
            || Path.IsPathRooted(relative)
            || relative.Split('/').Any(part => part is "" or "." or ".."))
            throw new IOException("The saved workspace path is invalid.");
        var root = Path.GetFullPath(workspace).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (root.Length == 0) root = Path.GetPathRoot(Path.GetFullPath(workspace)) ?? root;
        if (IsLink(root)) throw new IOException("A symbolic link replaced the workspace root.");
        var destination = Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var rootPrefix = root.EndsWith(Path.DirectorySeparatorChar)
            ? root
            : root + Path.DirectorySeparatorChar;
        if (!destination.StartsWith(rootPrefix, comparison))
            throw new IOException("The saved workspace path is outside the project.");

        var current = root;
        var parts = relative.Split('/');
        for (var index = 0; index < parts.Length - 1; index++)
        {
            current = Path.Combine(current, parts[index]);
            if (Directory.Exists(current) && IsLink(current))
                throw new IOException("A symbolic-link path prevents a safe restore.");
        }
        return destination;
    }

    private static string HashFile(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static bool HasChildDirectory(string path)
    {
        try { return Directory.EnumerateDirectories(path).Any(child => !WorkspaceChangeTracker.IsIgnored(child)); }
        catch { return true; }
    }

    private static bool IsLink(string path)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            return attributes.HasFlag(FileAttributes.ReparsePoint);
        }
        catch { return true; }
    }

    private static string Relative(string root, string path) =>
        Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/');

    private static StringComparer PathComparer() =>
        OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    private static bool SameWorkspace(string left, string right)
    {
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var trim = Path.DirectorySeparatorChar.ToString() + Path.AltDirectorySeparatorChar;
        return string.Equals(Path.GetFullPath(left).TrimEnd(trim.ToCharArray()), Path.GetFullPath(right).TrimEnd(trim.ToCharArray()), comparison);
    }

    public sealed class WorkspaceVersionCapture
    {
        private readonly WorkspaceVersionStore _store;
        private readonly CaptureState _before;
        private bool _finished;

        internal WorkspaceVersionCapture(
            WorkspaceVersionStore store,
            string conversationId,
            string turnId,
            string workspacePath,
            CaptureState before)
        {
            _store = store;
            ConversationId = conversationId;
            TurnId = turnId;
            WorkspacePath = workspacePath;
            _before = before;
        }

        public string ConversationId { get; }
        public string TurnId { get; }
        public string WorkspacePath { get; }

        public WorkspaceChangeResult FinishResult()
        {
            if (_finished) return new WorkspaceChangeResult([], "incomplete", "Workspace snapshot was already finished.");
            _finished = true;
            return _store.Finish(this, _before);
        }
    }
}

public sealed record WorkspaceRestoreResult(
    bool Succeeded,
    IReadOnlyList<string> RestoredPaths,
    IReadOnlyList<string> ConflictPaths,
    string? Failure = null)
{
    public static WorkspaceRestoreResult Unavailable { get; } = new(false, [], [], "Saved workspace versions are unavailable.");
}
