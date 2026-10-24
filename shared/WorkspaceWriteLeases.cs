using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public enum WorkspaceConflictPolicy
{
    WaitThenAsk,
    Ask,
    WaitOnly,
}

public enum WorkspaceConflictChoice
{
    KeepWaiting,
    StopHolder,
    StopAllOthers,
    Skip,
}

public sealed record WorkspaceLeaseHolder(
    string ConversationId,
    string ConversationTitle,
    string RunId,
    string ToolName,
    string Label,
    string WorkspaceRoot,
    DateTimeOffset StartedAt);

public sealed record PendingWorkspaceConflict(
    string ConversationId,
    string ToolCallId,
    string Path,
    string HolderConversationId,
    string HolderTitle,
    int HeldSeconds,
    int OtherRunningConversations);

/// <summary>A canonical write target, either one file or the entire workspace.</summary>
public sealed record WorkspaceLeaseTarget(string Root, string? FilePath, bool WholeWorkspace);

/// <summary>
/// Process-wide, cancellable write leases for workspace mutations. Different chats
/// cannot race a read-before-write check or overwrite the same file at once.
/// </summary>
public static class WorkspaceWriteLeases
{
    private readonly record struct DeferredWriteKey(string ConversationId, string TargetKey);
    private sealed record DeferredWrite(string Label, bool FinalCheckRequested);

    private sealed class Entry(WorkspaceLeaseTarget target, WorkspaceLeaseHolder holder)
    {
        public WorkspaceLeaseTarget Target { get; } = target;
        public WorkspaceLeaseHolder Holder { get; } = holder;
        public TaskCompletionSource Released { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed class Lease(Entry entry) : IDisposable
    {
        private Entry? _entry = entry;
        public void Dispose()
        {
            var owned = Interlocked.Exchange(ref _entry, null);
            if (owned is not null) Release(owned);
        }
    }

    private static readonly object Gate = new();
    private static readonly List<Entry> Active = [];
    private static readonly Dictionary<DeferredWriteKey, DeferredWrite> Deferred = [];
    private static readonly StringComparer PathComparer = OperatingSystem.IsWindows()
        ? StringComparer.OrdinalIgnoreCase
        : StringComparer.Ordinal;

    public static string KeyFor(WorkspaceLeaseTarget target)
    {
        var key = target.WholeWorkspace
            ? "workspace:" + target.Root
            : "file:" + target.Root + "\n" + target.FilePath;
        return OperatingSystem.IsWindows() ? key.ToUpperInvariant() : key;
    }

    /// <summary>Records a first collision so the agent can finish independent work before rechecking.</summary>
    public static bool DeferWrite(WorkspaceLeaseTarget target, string conversationId, string label)
    {
        lock (Gate)
        {
            var key = new DeferredWriteKey(conversationId, KeyFor(target));
            if (Deferred.ContainsKey(key)) return false;
            Deferred[key] = new DeferredWrite(label, FinalCheckRequested: false);
            return true;
        }
    }

    public static bool FinalCheckWasRequested(WorkspaceLeaseTarget target, string conversationId)
    {
        lock (Gate)
            return Deferred.TryGetValue(new DeferredWriteKey(conversationId, KeyFor(target)), out var deferred)
                && deferred.FinalCheckRequested;
    }

    /// <summary>Schedules unresolved writes for one final retry before a response is returned.</summary>
    public static IReadOnlyList<string> ScheduleFinalChecks(string conversationId)
    {
        lock (Gate)
        {
            var pending = Deferred.Where(pair => pair.Key.ConversationId == conversationId
                    && !pair.Value.FinalCheckRequested)
                .ToArray();
            foreach (var item in pending)
                Deferred[item.Key] = item.Value with { FinalCheckRequested = true };
            return pending.Select(item => item.Value.Label).OrderBy(label => label, StringComparer.Ordinal).ToArray();
        }
    }

    public static void ClearDeferredWrite(WorkspaceLeaseTarget target, string conversationId)
    {
        lock (Gate) Deferred.Remove(new DeferredWriteKey(conversationId, KeyFor(target)));
    }

    public static void ClearDeferredWrites(string conversationId)
    {
        lock (Gate)
            foreach (var key in Deferred.Keys.Where(key => key.ConversationId == conversationId).ToArray())
                Deferred.Remove(key);
    }

    /// <summary>Acquires a mutation lease, waiting until a conflicting chat releases or this run is cancelled.</summary>
    public static async Task<IDisposable?> AcquireAsync(
        NativeToolCall call,
        string workspace,
        string conversationId,
        CancellationToken cancellationToken)
    {
        var target = TargetFor(call, workspace);
        if (target is null || string.IsNullOrWhiteSpace(conversationId)) return null;
        var holder = new WorkspaceLeaseHolder(conversationId, conversationId, "", call.Name,
            LeaseLabel(call, workspace), target.Root, DateTimeOffset.UtcNow);
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (TryAcquire(target, holder, out var lease, out _)) return lease;
            await WaitUntilFreeAsync(target, conversationId, timeout: null, cancellationToken).ConfigureAwait(false);
        }
    }

    public static WorkspaceLeaseTarget? TargetFor(NativeToolCall call, string workspace)
    {
        if (string.IsNullOrWhiteSpace(workspace)) return null;
        var root = ResolveLinks(Path.GetFullPath(workspace));
        if (call.Name == "run_command")
        {
            if (!NativeWorkspaceTools.MayDeleteFiles(Argument(call, "command"))) return null;
            return new WorkspaceLeaseTarget(root, null, true);
        }

        var argument = call.Name == NativeWorkspaceTools.GeneratedMediaName ? "destination_path" : "path";
        if (call.Name is not ("write_file" or "remove_file")
            && call.Name != NativeFileEdit.EditName
            && call.Name != NativeWorkspaceTools.GeneratedMediaName) return null;
        var requested = Argument(call, argument);
        if (string.IsNullOrWhiteSpace(requested)) return null;

        var path = ResolveLinks(Path.GetFullPath(requested, root));
        var relative = Path.GetRelativePath(root, path);
        if (Path.IsPathRooted(relative)
            || relative == "."
            || relative == ".."
            || relative.StartsWith(".." + Path.DirectorySeparatorChar, PathComparison)
            || relative.StartsWith(".." + Path.AltDirectorySeparatorChar, PathComparison)) return null;
        return new WorkspaceLeaseTarget(root, path, false);
    }

    public static bool TryAcquire(
        WorkspaceLeaseTarget target,
        WorkspaceLeaseHolder holder,
        out IDisposable? lease,
        out WorkspaceLeaseHolder? conflict)
    {
        lock (Gate)
        {
            var occupied = Active.FirstOrDefault(entry =>
                !string.Equals(entry.Holder.ConversationId, holder.ConversationId, StringComparison.Ordinal)
                && Conflicts(target, entry.Target));
            if (occupied is not null)
            {
                lease = null;
                conflict = occupied.Holder;
                return false;
            }
            var entry = new Entry(target, holder);
            Active.Add(entry);
            Deferred.Remove(new DeferredWriteKey(holder.ConversationId, KeyFor(target)));
            lease = new Lease(entry);
            conflict = null;
            return true;
        }
    }

    public static WorkspaceLeaseHolder? HolderFor(WorkspaceLeaseTarget target, string excludingConversationId)
    {
        lock (Gate)
            return Active.FirstOrDefault(entry =>
                !string.Equals(entry.Holder.ConversationId, excludingConversationId, StringComparison.Ordinal)
                && Conflicts(target, entry.Target))?.Holder;
    }

    /// <summary>Waits for the current conflicting holder. The caller must retry acquisition after this returns.</summary>
    public static async Task<bool> WaitUntilFreeAsync(
        WorkspaceLeaseTarget target,
        string excludingConversationId,
        TimeSpan? timeout,
        CancellationToken cancellationToken)
    {
        var deadline = timeout is { } duration ? DateTimeOffset.UtcNow + duration : (DateTimeOffset?)null;
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Task? release;
            lock (Gate)
            {
                release = Active.FirstOrDefault(entry =>
                    !string.Equals(entry.Holder.ConversationId, excludingConversationId, StringComparison.Ordinal)
                    && Conflicts(target, entry.Target))?.Released.Task;
            }
            if (release is null) return true;
            if (deadline is null)
            {
                await release.WaitAsync(cancellationToken).ConfigureAwait(false);
                continue;
            }

            var remaining = deadline.Value - DateTimeOffset.UtcNow;
            if (remaining <= TimeSpan.Zero) return false;
            try { await release.WaitAsync(remaining, cancellationToken).ConfigureAwait(false); }
            catch (TimeoutException) { return false; }
        }
    }

    public static async Task<bool> WaitForConversationReleaseAsync(
        string conversationId,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (true)
        {
            Task[] releases;
            lock (Gate)
                releases = Active.Where(entry => entry.Holder.ConversationId == conversationId)
                    .Select(entry => entry.Released.Task).ToArray();
            if (releases.Length == 0) return true;
            var remaining = deadline - DateTimeOffset.UtcNow;
            if (remaining <= TimeSpan.Zero) return false;
            try { await Task.WhenAll(releases).WaitAsync(remaining, cancellationToken).ConfigureAwait(false); }
            catch (TimeoutException) { return false; }
        }
    }

    public static void ReleaseAll(string conversationId)
    {
        Entry[] released;
        lock (Gate)
        {
            released = Active.Where(entry => entry.Holder.ConversationId == conversationId).ToArray();
            foreach (var entry in released) Active.Remove(entry);
            foreach (var key in Deferred.Keys.Where(key => key.ConversationId == conversationId).ToArray())
                Deferred.Remove(key);
        }
        foreach (var entry in released) entry.Released.TrySetResult();
    }

    public static bool AreRelatedWorkspaces(string first, string second)
    {
        if (string.IsNullOrWhiteSpace(first) || string.IsNullOrWhiteSpace(second)) return false;
        var left = ResolveLinks(Path.GetFullPath(first));
        var right = ResolveLinks(Path.GetFullPath(second));
        return IsSameOrNested(left, right) || IsSameOrNested(right, left);
    }

    private static bool IsSameOrNested(string parent, string candidate) =>
        PathComparer.Equals(parent, candidate)
        || candidate.StartsWith(Path.TrimEndingDirectorySeparator(parent) + Path.DirectorySeparatorChar, PathComparison);

    private static string LeaseLabel(NativeToolCall call, string workspace) =>
        Argument(call, "path") ?? Argument(call, "destination_path")
        ?? (Argument(call, "command") is { } command ? command[..Math.Min(40, command.Length)] : null)
        ?? Path.GetFileName(Path.TrimEndingDirectorySeparator(workspace));

    private static string? Argument(NativeToolCall call, string name)
    {
        try { return JsonNode.Parse(call.Arguments)?[name]?.GetValue<string>(); }
        catch { return null; }
    }

    private static bool Conflicts(WorkspaceLeaseTarget requested, WorkspaceLeaseTarget held)
    {
        if (!PathComparer.Equals(requested.Root, held.Root)) return false;
        if (requested.WholeWorkspace || held.WholeWorkspace) return true;
        return requested.FilePath is not null && held.FilePath is not null
            && PathComparer.Equals(requested.FilePath, held.FilePath);
    }

    private static void Release(Entry entry)
    {
        lock (Gate) Active.Remove(entry);
        entry.Released.TrySetResult();
    }

    private static string ResolveLinks(string path)
    {
        var full = Path.GetFullPath(path);
        var volume = Path.GetPathRoot(full) ?? "";
        var current = volume;
        foreach (var segment in full[volume.Length..].Split(
                     [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            try
            {
                FileSystemInfo info = Directory.Exists(current)
                    ? new DirectoryInfo(current)
                    : new FileInfo(current);
                if (info.LinkTarget is not null && info.ResolveLinkTarget(returnFinalTarget: true) is { } target)
                    current = target.FullName;
            }
            catch
            {
                // The tool itself reports inaccessible paths. Keeping the
                // normalized spelling still protects ordinary same-path races.
            }
        }
        return Path.TrimEndingDirectorySeparator(Path.GetFullPath(current));
    }

    private static StringComparison PathComparison => OperatingSystem.IsWindows()
        ? StringComparison.OrdinalIgnoreCase
        : StringComparison.Ordinal;
}
