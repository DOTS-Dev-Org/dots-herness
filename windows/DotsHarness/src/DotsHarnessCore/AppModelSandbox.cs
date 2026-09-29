// Copyright (c) 2026 DOTS
// Sandbox worktree state for the Windows and Linux shells: enter an isolated git
// worktree, merge or discard it, and resolve merge conflicts inside it. Mirrors the
// macOS AppModel sandbox flow.

using PluginRuntime;

namespace DotsHarnessCore;

public sealed partial class AppModel
{
    private SandboxWorkspace? _activeSandbox;
    private SandboxConflict? _sandboxConflict;
    private SandboxResolutionPreview? _sandboxPreview;
    private string? _sandboxNotice;
    private bool _sandboxBusy;

    /// <summary>Non-null while the agent works in a sandbox worktree instead of the checkout.</summary>
    public SandboxWorkspace? ActiveSandbox
    {
        get => _activeSandbox;
        private set
        {
            if (SetProperty(ref _activeSandbox, value)) OnPropertyChanged(nameof(WorkLocation));
        }
    }

    public SandboxConflict? SandboxConflict { get => _sandboxConflict; private set => SetProperty(ref _sandboxConflict, value); }

    public SandboxResolutionPreview? SandboxResolutionPreview { get => _sandboxPreview; private set => SetProperty(ref _sandboxPreview, value); }

    public string? SandboxNotice { get => _sandboxNotice; set => SetProperty(ref _sandboxNotice, value); }

    public bool SandboxBusy { get => _sandboxBusy; private set => SetProperty(ref _sandboxBusy, value); }

    /// <summary>Where a sandbox is created from: the checkout the user opened, or the active sandbox's origin.</summary>
    public string? SandboxOriginPath => ActiveSandbox?.OriginPath;

    public async Task EnterSandboxAsync(string name)
    {
        if (ActiveSandbox is not null) { SandboxNotice = "A sandbox is already active."; return; }
        if (RemoteTarget is not null) { SandboxNotice = "Leave the remote host before starting a sandbox."; return; }
        if (CodingBridge.AnyRunBusy)
        {
            SandboxNotice = "The sandbox cannot change state while an agent operation is still running.";
            return;
        }
        var origin = WorkspacePath;
        if (string.IsNullOrWhiteSpace(origin)) { SandboxNotice = "Open a workspace first."; return; }

        await RunSandboxOperationAsync(async () =>
        {
            var sandbox = await Task.Run(() => SandboxWorkspaces.Enter(origin, name));
            var status = await Task.Run(() => SandboxWorkspaces.Git(new[] { "status", "--porcelain", "--untracked-files=all" }, origin));
            var uncommitted = status.Status != 0 || status.Text.Length > 0;
            SetWorkspace(sandbox.Path);
            ActivateSandbox(sandbox);
            SandboxConflict = null;
            SandboxResolutionPreview = null;
            PersistSandbox(sandbox);
            SandboxNotice = uncommitted
                ? $"Sandbox '{sandbox.Name}' started from the last commit. Your uncommitted changes stayed in {origin} and are not visible to the agent."
                : $"Sandbox '{sandbox.Name}' started.";
        });
    }

    /// <summary>Merges the sandbox into the origin branch, or throws it away.</summary>
    public async Task ExitSandboxAsync(bool merge)
    {
        if (ActiveSandbox is not { } sandbox) return;
        if (CodingBridge.AnyRunBusy)
        {
            SandboxNotice = "The sandbox cannot change state while an agent operation is still running.";
            return;
        }
        await RunSandboxOperationAsync(async () =>
        {
            var exit = await Task.Run(() => SandboxWorkspaces.Exit(sandbox, merge));
            switch (exit)
            {
                case SandboxExit.Conflicted conflicted:
                    SandboxConflict = conflicted.Conflict;
                    PersistConflict(conflicted.Conflict);
                    SandboxNotice = $"Merging '{sandbox.Name}' conflicts in {string.Join(", ", conflicted.Conflict.Files)}. The origin was left untouched.";
                    break;
                case SandboxExit.Merged merged:
                    LeaveSandbox(sandbox);
                    SandboxNotice = merged.Commits == 0
                        ? $"Sandbox '{sandbox.Name}' had no changes."
                        : $"Merged {merged.Commits} commit(s) from '{sandbox.Name}'.";
                    break;
                default:
                    LeaveSandbox(sandbox);
                    SandboxNotice = $"Sandbox '{sandbox.Name}' discarded. Its branch {sandbox.Branch} was kept.";
                    break;
            }
        });
    }

    public Task PrepareSandboxResolutionAsync() => WithConflictAsync(conflict =>
        Task.Run(() => SandboxWorkspaces.PrepareResolution(conflict)));

    public Task PreviewSandboxResolutionAsync() => WithConflictAsync(async conflict =>
        SandboxResolutionPreview = await Task.Run(() => SandboxWorkspaces.PreviewResolution(conflict)));

    public Task CancelSandboxResolutionAsync() => WithConflictAsync(async conflict =>
    {
        await Task.Run(() => SandboxWorkspaces.CancelResolution(conflict));
        SandboxResolutionPreview = null;
    });

    /// <summary>Commits the resolution the user approved in the preview, then merges.</summary>
    public Task ApplySandboxResolutionAsync() => WithConflictAsync(async conflict =>
    {
        if (SandboxResolutionPreview is not { } preview) throw SandboxWorkspaceException.Stale();
        var sandbox = conflict.Sandbox;
        var exit = await Task.Run(() => SandboxWorkspaces.ApplyResolution(conflict, preview.Fingerprint));
        if (exit is SandboxExit.Merged merged)
        {
            LeaveSandbox(sandbox);
            SandboxNotice = $"Resolved and merged {merged.Commits} commit(s) from '{sandbox.Name}'.";
        }
    });

    private async Task WithConflictAsync(Func<SandboxConflict, Task> operation)
    {
        if (SandboxConflict is not { } conflict) return;
        await RunSandboxOperationAsync(() => operation(conflict));
    }

    private async Task RunSandboxOperationAsync(Func<Task> operation)
    {
        if (SandboxBusy) return;
        SandboxBusy = true;
        try { await operation(); }
        catch (SandboxWorkspaceException error) { SandboxNotice = error.Message; }
        finally { SandboxBusy = false; }
    }

    private void ActivateSandbox(SandboxWorkspace sandbox)
    {
        ActiveSandbox = sandbox;
        try { AgentCommandSandbox.AdditionalWritableRoots = SandboxWorkspaces.AgentWritableRoots(sandbox); }
        catch (SandboxWorkspaceException) { AgentCommandSandbox.AdditionalWritableRoots = Array.Empty<string>(); }
    }

    private void LeaveSandbox(SandboxWorkspace sandbox)
    {
        ActiveSandbox = null;
        SandboxConflict = null;
        SandboxResolutionPreview = null;
        AgentCommandSandbox.AdditionalWritableRoots = Array.Empty<string>();
        ClearPersistedSandbox();
        var index = CodingProjects.ToList().FindIndex(p => string.Equals(p, sandbox.Path, StringComparison.OrdinalIgnoreCase));
        if (index >= 0) CodingProjects.RemoveAt(index);
        PersistCodingProjects();
        // Back to the checkout the sandbox was made from.
        if (Directory.Exists(sandbox.OriginPath)) SetWorkspace(sandbox.OriginPath);
    }

    private void RestoreSandbox()
    {
        var origin = Host.Settings.Get("agent.sandbox.origin")?.AsString();
        if (string.IsNullOrWhiteSpace(origin)) return;
        var path = Host.Settings.Get("agent.sandbox.path")?.AsString();
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path))
        {
            SandboxNotice = "A saved sandbox needs recovery because its worktree path is missing.";
            return;
        }
        try
        {
            var sandbox = SandboxWorkspaces.Restore(
                origin, path,
                Host.Settings.Get("agent.sandbox.name")?.AsString(),
                Host.Settings.Get("agent.sandbox.originBranch")?.AsString());
            ActivateSandbox(sandbox);
            var originHead = Host.Settings.Get("agent.sandbox.conflict.originHead")?.AsString();
            var sandboxHead = Host.Settings.Get("agent.sandbox.conflict.sandboxHead")?.AsString();
            var files = (Host.Settings.Get("agent.sandbox.conflict.files")?.AsArray() ?? Array.Empty<HarnessPluginKit.JsonValue>())
                .Select(item => item.AsString() ?? "")
                .Where(file => file.Length > 0)
                .ToList();
            if (!string.IsNullOrEmpty(originHead) && !string.IsNullOrEmpty(sandboxHead) && files.Count > 0)
            {
                SandboxConflict = new SandboxConflict(
                    sandbox,
                    Host.Settings.Get("agent.sandbox.conflict.originBranch")?.AsString() ?? sandbox.OriginBranch,
                    originHead, sandboxHead, files);
            }
        }
        catch (SandboxWorkspaceException error)
        {
            SandboxNotice = $"A saved sandbox needs recovery: {error.Message}";
        }
    }

    private void PersistSandbox(SandboxWorkspace sandbox)
    {
        Host.Settings.Set("agent.sandbox.origin", HarnessPluginKit.JsonValue.String(sandbox.OriginPath));
        Host.Settings.Set("agent.sandbox.path", HarnessPluginKit.JsonValue.String(sandbox.Path));
        Host.Settings.Set("agent.sandbox.name", HarnessPluginKit.JsonValue.String(sandbox.Name));
        Host.Settings.Set("agent.sandbox.originBranch", HarnessPluginKit.JsonValue.String(sandbox.OriginBranch));
        PersistSettings();
    }

    private void PersistConflict(SandboxConflict conflict)
    {
        Host.Settings.Set("agent.sandbox.conflict.originBranch", HarnessPluginKit.JsonValue.String(conflict.OriginBranch));
        Host.Settings.Set("agent.sandbox.conflict.originHead", HarnessPluginKit.JsonValue.String(conflict.OriginHead));
        Host.Settings.Set("agent.sandbox.conflict.sandboxHead", HarnessPluginKit.JsonValue.String(conflict.SandboxHead));
        Host.Settings.Set("agent.sandbox.conflict.files",
            HarnessPluginKit.JsonValue.Array(conflict.Files.Select(HarnessPluginKit.JsonValue.String).ToArray()));
        PersistSettings();
    }

    private void ClearPersistedSandbox()
    {
        foreach (var key in new[]
        {
            "agent.sandbox.origin", "agent.sandbox.path", "agent.sandbox.name", "agent.sandbox.originBranch",
            "agent.sandbox.conflict.originBranch", "agent.sandbox.conflict.originHead",
            "agent.sandbox.conflict.sandboxHead", "agent.sandbox.conflict.files",
        })
            Host.Settings.Set(key, HarnessPluginKit.JsonValue.String(""));
        Host.Settings.Set("agent.sandbox.conflict.files", HarnessPluginKit.JsonValue.Array());
        PersistSettings();
    }
}
