// Copyright (c) 2026 DOTS
// Sandbox worktree lifecycle, recovery and conflict review.

using System.Diagnostics;
using System.Text.Json.Nodes;
using HarnessPluginKit;
using JsonValue = HarnessPluginKit.JsonValue;

namespace DotsHarnessCore;

public sealed partial class AppModel
{
    private bool _sandboxTransition;
    private bool _sandboxNetworkAccess;
    private bool _sandboxResolutionBusy;
    private bool _sandboxCleanupPending;
    private bool _sandboxCleanupMerge = true;
    private bool _sandboxRecoveryRequired;
    private string? _sandboxNotice;
    private SandboxWorkspace? _activeSandbox;
    private SandboxConflict? _sandboxConflict;
    private SandboxResolutionPreview? _sandboxResolutionPreview;
    private IReadOnlyList<SandboxWorkspace> _availableSandboxes = [];

    public SandboxWorkspaces SandboxStore { get; }
    public SandboxWorkspace? ActiveSandbox { get => _activeSandbox; private set => SetProperty(ref _activeSandbox, value); }
    public SandboxConflict? SandboxConflict { get => _sandboxConflict; private set => SetProperty(ref _sandboxConflict, value); }
    public SandboxResolutionPreview? SandboxResolutionPreview { get => _sandboxResolutionPreview; private set => SetProperty(ref _sandboxResolutionPreview, value); }
    public IReadOnlyList<SandboxWorkspace> AvailableSandboxes { get => _availableSandboxes; private set => SetProperty(ref _availableSandboxes, value); }
    public string? SandboxNotice { get => _sandboxNotice; private set => SetProperty(ref _sandboxNotice, value); }
    public bool SandboxResolutionBusy { get => _sandboxResolutionBusy; private set => SetProperty(ref _sandboxResolutionBusy, value); }
    public bool SandboxCleanupPending { get => _sandboxCleanupPending; private set => SetProperty(ref _sandboxCleanupPending, value); }
    public bool SandboxRecoveryRequired
    {
        get => _sandboxRecoveryRequired;
        private set
        {
            if (!SetProperty(ref _sandboxRecoveryRequired, value)) return;
            Bridge.SetSandboxRecoveryRequired(value);
        }
    }
    public bool SandboxNetworkAccess
    {
        get => _sandboxNetworkAccess;
        set
        {
            if (!SetProperty(ref _sandboxNetworkAccess, value)) return;
            Host.Settings.Set("agent.sandbox.networkAccess", JsonValue.Bool(value));
            PersistSettings();
            try { Bridge.SetSandboxExecution(
                ActiveSandbox is null ? [] : SandboxWorkspaces.AgentWritableRoots(ActiveSandbox),
                ActiveSandbox is not null && value,
                ActiveSandbox?.Branch,
                ActiveSandbox?.Path); }
            catch (Exception error) { SandboxNotice = error.Message; }
        }
    }
    public bool SandboxProcessIsolationAvailable => AgentCommandSandbox.IsAvailable;
    public string SandboxProcessIsolationStatus => AgentCommandSandbox.AvailabilityError
        ?? "When a sandbox is active, agent commands and the dock terminal run inside bubblewrap; host home and project memory are hidden. MCP connections pause for the same period.";
    public string SandboxWorkspaceDisplayPath => ActiveSandbox?.Path ?? WorkspacePath;

    private void RestoreSandboxState(ISettingsRegistry settings)
    {
        SandboxNetworkAccess = settings.Get("agent.sandbox.networkAccess")?.AsBool() ?? false;
        var origin = settings.Get("agent.sandbox.origin")?.AsString();
        if (string.IsNullOrWhiteSpace(origin)) return;
        var path = settings.Get("agent.sandbox.path")?.AsString() ?? WorkspacePath;
        try
        {
            if (string.IsNullOrWhiteSpace(path)) throw new InvalidOperationException("The saved sandbox worktree path is missing.");
            var sandbox = SandboxStore.Restore(
                origin,
                path,
                settings.Get("agent.sandbox.name")?.AsString(),
                settings.Get("agent.sandbox.originBranch")?.AsString());
            ActiveSandbox = sandbox;
            WorkspacePath = sandbox.Path;
            SandboxCleanupPending = settings.Get("agent.sandbox.cleanupPending")?.AsBool() ?? false;
            _sandboxCleanupMerge = settings.Get("agent.sandbox.cleanupMerge")?.AsBool() ?? true;
            SandboxRecoveryRequired = settings.Get("agent.sandbox.recoveryRequired")?.AsBool() ?? false;
            SandboxConflict = ReadPersistedConflict(sandbox, settings);
            Bridge.SetSandboxExecution(SandboxWorkspaces.AgentWritableRoots(sandbox), SandboxNetworkAccess, sandbox.Branch, sandbox.Path);
            _ = McpRegistry.SuspendForSandboxAsync(true);
        }
        catch (Exception error)
        {
            SandboxRecoveryRequired = true;
            SandboxNotice = "A saved sandbox needs recovery: " + error.Message;
            WorkspacePath = Directory.Exists(origin) ? Path.GetFullPath(origin) : "";
        }
        OnPropertyChanged(nameof(SandboxWorkspaceDisplayPath));
    }

    public async Task EnterSandboxAsync(string name)
    {
        if (ActiveSandbox is not null || SandboxRecoveryRequired || Bridge.AnyRunBusy || IsRemoteWorkLocation)
        {
            SandboxNotice = ActiveSandbox is not null ? "Leave the active sandbox before starting another one."
                : SandboxRecoveryRequired ? "Recover the saved sandbox before starting another one."
                : IsRemoteWorkLocation ? "Sandbox worktrees are available for local workspaces only."
                : L("ssh.busy");
            return;
        }
        var origin = WorkspacePath;
        if (string.IsNullOrWhiteSpace(origin)) { SandboxNotice = "Open a workspace first."; return; }
        try
        {
            var dirty = await Task.Run(() => GitStatus(origin).Length > 0);
            var sandbox = await Task.Run(() => SandboxStore.Enter(origin, name));
            SwitchWorkspaceForSandbox(sandbox.Path);
            ActiveSandbox = sandbox;
            SandboxConflict = null;
            SandboxResolutionPreview = null;
            SandboxCleanupPending = false;
            _sandboxCleanupMerge = true;
            SandboxRecoveryRequired = false;
            Bridge.SetSandboxExecution(SandboxWorkspaces.AgentWritableRoots(sandbox), SandboxNetworkAccess, sandbox.Branch, sandbox.Path);
            _ = McpRegistry.SuspendForSandboxAsync(true);
            SaveSandboxState(sandbox);
            SandboxNotice = dirty
                ? $"Sandbox '{sandbox.Name}' started from the last commit. Uncommitted changes remain in the origin workspace and are not visible in the worktree."
                : $"Sandbox '{sandbox.Name}' started. {SandboxProcessIsolationStatus}";
        }
        catch (Exception error) { SandboxNotice = error.Message; }
    }

    public async Task RefreshAvailableSandboxesAsync()
    {
        var origin = ActiveSandbox?.OriginPath ?? WorkspacePath;
        if (string.IsNullOrWhiteSpace(origin)) { AvailableSandboxes = []; return; }
        try { AvailableSandboxes = await Task.Run(() => SandboxStore.List(origin)); }
        catch { AvailableSandboxes = []; }
    }

    public async Task RecoverSandboxAsync(SandboxWorkspace candidate)
    {
        if (ActiveSandbox is not null || Bridge.AnyRunBusy) { SandboxNotice = "Finish the active operation before recovering a sandbox."; return; }
        try
        {
            var sandbox = await Task.Run(() => SandboxStore.Restore(candidate.OriginPath, candidate.Path, candidate.Name, candidate.OriginBranch));
            SwitchWorkspaceForSandbox(sandbox.Path);
            ActiveSandbox = sandbox;
            SandboxRecoveryRequired = false;
            var savedPath = Host.Settings.Get("agent.sandbox.path")?.AsString();
            SandboxConflict = SameWorkspacePath(savedPath, sandbox.Path) ? ReadPersistedConflict(sandbox, Host.Settings) : null;
            SandboxResolutionPreview = null;
            SandboxCleanupPending = SameWorkspacePath(savedPath, sandbox.Path) && (Host.Settings.Get("agent.sandbox.cleanupPending")?.AsBool() ?? false);
            Bridge.SetSandboxExecution(SandboxWorkspaces.AgentWritableRoots(sandbox), SandboxNetworkAccess, sandbox.Branch, sandbox.Path);
            SaveSandboxState(sandbox);
            SandboxNotice = $"Sandbox '{sandbox.Name}' recovered. {SandboxProcessIsolationStatus}";
        }
        catch (Exception error) { SandboxNotice = "Sandbox recovery failed: " + error.Message; }
    }

    public async Task RetrySandboxRecoveryAsync()
    {
        if (ActiveSandbox is not { } sandbox || !SandboxRecoveryRequired) return;
        if (Bridge.AnyRunBusy || SandboxResolutionBusy) { SandboxNotice = "Finish the active operation before retrying recovery."; return; }
        try
        {
            await Task.Run(() => SandboxStore.ValidateReady(sandbox));
            SandboxRecoveryRequired = false;
            Bridge.SetSandboxExecution(SandboxWorkspaces.AgentWritableRoots(sandbox), SandboxNetworkAccess, sandbox.Branch, sandbox.Path);
            _ = McpRegistry.SuspendForSandboxAsync(true);
            SaveSandboxState(sandbox);
            SandboxNotice = "Sandbox recovery completed.";
        }
        catch (Exception error) { SandboxNotice = "Sandbox recovery still needs attention: " + error.Message; }
    }

    public async Task ExitSandboxAsync(bool merge)
    {
        if (ActiveSandbox is not { } sandbox) return;
        if (Bridge.AnyRunBusy || SandboxResolutionBusy || SandboxRecoveryRequired)
        {
            SandboxNotice = SandboxRecoveryRequired ? "Recover the sandbox state before leaving it." : "Finish the active operation before leaving the sandbox.";
            return;
        }
        var requestedMerge = SandboxCleanupPending ? _sandboxCleanupMerge : merge;
        try
        {
            var result = await Task.Run(() => SandboxStore.Exit(sandbox, requestedMerge));
            if (result.Kind == SandboxExitKind.Conflicted && result.Conflict is { } conflict)
            {
                SandboxConflict = conflict;
                SandboxResolutionPreview = null;
                PersistSandboxConflict(conflict);
                SandboxNotice = "Merge conflicts; the origin was left unchanged. Resolve inside the sandbox: " + string.Join(", ", conflict.Files);
                return;
            }
            FinishSandboxExit(sandbox, result.Kind == SandboxExitKind.Discarded
                ? $"Sandbox '{sandbox.Name}' discarded. Branch {sandbox.Branch} still holds the work."
                : result.Commits == 0 ? $"Sandbox '{sandbox.Name}' had no changes; removed."
                : $"Merged {result.Commits} commit(s) from '{sandbox.Name}'.");
        }
        catch (Exception error)
        {
            if (error.Message.Contains("cleanup", StringComparison.OrdinalIgnoreCase)
                || error.Message.Contains("sandbox was not removed", StringComparison.OrdinalIgnoreCase))
            {
                SandboxCleanupPending = true;
                _sandboxCleanupMerge = requestedMerge;
                SaveSandboxState(sandbox);
            }
            if (error.Message.Contains("merge --abort", StringComparison.OrdinalIgnoreCase))
            {
                SandboxRecoveryRequired = true;
                SaveSandboxState(sandbox);
            }
            SandboxNotice = error.Message;
        }
    }

    public async Task PrepareSandboxResolutionAsync()
    {
        var conflict = SandboxConflict;
        if (conflict is null) return;
        if (Bridge.AnyRunBusy || SandboxRecoveryRequired) { SandboxNotice = "Finish or recover the active operation before preparing a resolution."; return; }
        SandboxResolutionBusy = true;
        try
        {
            await Task.Run(() => SandboxStore.PrepareResolution(conflict));
            SandboxResolutionPreview = await Task.Run(() => SandboxStore.PreviewResolution(conflict));
            SandboxNotice = "Conflict resolution is ready in the sandbox. Review the complete preview before approving it.";
        }
        catch (Exception error) { SandboxNotice = error.Message; }
        finally { SandboxResolutionBusy = false; }
    }

    public async Task PreviewSandboxResolutionAsync()
    {
        var conflict = SandboxConflict;
        if (conflict is null || SandboxResolutionBusy) return;
        try { SandboxResolutionPreview = await Task.Run(() => SandboxStore.PreviewResolution(conflict)); }
        catch (Exception error) { SandboxNotice = error.Message; }
    }

    public async Task AskAgentToResolveSandboxConflictAsync()
    {
        var conflict = SandboxConflict;
        if (conflict is null || Bridge.AnyRunBusy || SandboxRecoveryRequired) return;
        SandboxResolutionBusy = true;
        try
        {
            await Task.Run(() => SandboxStore.PrepareResolution(conflict));
            var files = string.Join("\n", conflict.Files.Select(file => "- " + file));
            await Bridge.SendAsync($"Resolve this git merge conflict inside the active sandbox.\nEdit only these conflict files:\n{files}\nDo not access the origin checkout. Do not run git add or git commit. Remove every conflict marker, run relevant checks, and leave the resolved files ready for review.", PromptMode.Queue);
            SandboxResolutionPreview = await Task.Run(() => SandboxStore.PreviewResolution(conflict));
            SandboxNotice = "Agent resolution is ready for review.";
        }
        catch (Exception error) { SandboxNotice = error.Message; }
        finally { SandboxResolutionBusy = false; }
    }

    public async Task ApplySandboxResolutionAsync()
    {
        var conflict = SandboxConflict;
        var preview = SandboxResolutionPreview;
        if (conflict is null || preview is null) return;
        if (SandboxResolutionBusy || Bridge.AnyRunBusy || SandboxRecoveryRequired) return;
        if (preview.IsTruncated || preview.UnresolvedFiles.Count != 0)
        {
            SandboxNotice = "Approval requires a complete preview with no unresolved files.";
            return;
        }
        SandboxResolutionBusy = true;
        try
        {
            var result = await Task.Run(() => SandboxStore.ApplyResolution(conflict, preview.Fingerprint));
            if (result.Kind == SandboxExitKind.Merged) FinishSandboxExit(conflict.Sandbox, $"Merged the approved sandbox resolution ({result.Commits} commit(s)).");
            else if (result.Conflict is { } next)
            {
                SandboxConflict = next;
                SandboxResolutionPreview = null;
                PersistSandboxConflict(next);
                SandboxNotice = "The approved resolution conflicted again; no origin changes were applied.";
            }
        }
        catch (Exception error) { SandboxNotice = error.Message; }
        finally { SandboxResolutionBusy = false; }
    }

    public async Task CancelSandboxResolutionAsync()
    {
        var conflict = SandboxConflict;
        if (conflict is null || SandboxResolutionBusy || Bridge.AnyRunBusy || SandboxRecoveryRequired) return;
        try
        {
            await Task.Run(() => SandboxStore.CancelResolution(conflict));
            SandboxResolutionPreview = null;
            SandboxNotice = "Sandbox resolution cancelled; the origin was not changed.";
        }
        catch (Exception error) { SandboxNotice = error.Message; }
    }

    public async Task RetrySandboxCleanupAsync()
    {
        var sandbox = ActiveSandbox;
        if (sandbox is null || !SandboxCleanupPending || Bridge.AnyRunBusy || SandboxRecoveryRequired) return;
        try
        {
            await Task.Run(() => SandboxStore.RetryCleanup(sandbox, _sandboxCleanupMerge));
            FinishSandboxExit(sandbox, $"Sandbox '{sandbox.Name}' cleanup completed.");
        }
        catch (Exception error) { SandboxNotice = error.Message; }
    }

    public void RevealSandboxPath(string? path = null)
    {
        var selected = path ?? ActiveSandbox?.Path;
        if (string.IsNullOrWhiteSpace(selected) || !Directory.Exists(selected)) return;
        try
        {
            Process.Start(new ProcessStartInfo { FileName = selected, UseShellExecute = true });
        }
        catch (Exception error) { SandboxNotice = error.Message; }
    }

    private void SwitchWorkspaceForSandbox(string path)
    {
        _sandboxTransition = true;
        try { SetWorkspace(path, addToProjects: false); }
        finally { _sandboxTransition = false; }
        OnPropertyChanged(nameof(SandboxWorkspaceDisplayPath));
    }

    private void FinishSandboxExit(SandboxWorkspace sandbox, string notice)
    {
        ActiveSandbox = null;
        SandboxConflict = null;
        SandboxResolutionPreview = null;
        SandboxResolutionBusy = false;
        SandboxCleanupPending = false;
        _sandboxCleanupMerge = true;
        SandboxRecoveryRequired = false;
        foreach (var path in Projects.Where(path => SameWorkspacePath(path, sandbox.Path)).ToArray()) Projects.Remove(path);
        Host.Settings.Set("agent.sandbox.origin", JsonValue.Null);
        Host.Settings.Set("agent.sandbox.path", JsonValue.Null);
        Host.Settings.Set("agent.sandbox.name", JsonValue.Null);
        Host.Settings.Set("agent.sandbox.branch", JsonValue.Null);
        Host.Settings.Set("agent.sandbox.originBranch", JsonValue.Null);
        Host.Settings.Set("agent.sandbox.cleanupPending", JsonValue.Null);
        Host.Settings.Set("agent.sandbox.cleanupMerge", JsonValue.Null);
        Host.Settings.Set("agent.sandbox.recoveryRequired", JsonValue.Null);
        ClearPersistedSandboxConflict();
        Bridge.SetSandboxExecution([], networkAccess: false);
        _ = McpRegistry.SuspendForSandboxAsync(false);
        SwitchWorkspaceForSandbox(sandbox.OriginPath);
        SandboxNotice = notice;
        PersistProjects();
        PersistSettings();
    }

    private void SaveSandboxState(SandboxWorkspace sandbox)
    {
        Host.Settings.Set("agent.sandbox.origin", JsonValue.String(sandbox.OriginPath));
        Host.Settings.Set("agent.sandbox.path", JsonValue.String(sandbox.Path));
        Host.Settings.Set("agent.sandbox.name", JsonValue.String(sandbox.Name));
        Host.Settings.Set("agent.sandbox.branch", JsonValue.String(sandbox.Branch));
        Host.Settings.Set("agent.sandbox.originBranch", JsonValue.String(sandbox.OriginBranch));
        Host.Settings.Set("agent.sandbox.cleanupPending", JsonValue.Bool(SandboxCleanupPending));
        Host.Settings.Set("agent.sandbox.cleanupMerge", JsonValue.Bool(_sandboxCleanupMerge));
        Host.Settings.Set("agent.sandbox.recoveryRequired", JsonValue.Bool(SandboxRecoveryRequired));
        PersistSettings();
    }

    private void PersistSandboxConflict(SandboxConflict conflict)
    {
        Host.Settings.Set("agent.sandbox.conflict.originBranch", JsonValue.String(conflict.OriginBranch));
        Host.Settings.Set("agent.sandbox.conflict.originHead", JsonValue.String(conflict.OriginHead));
        Host.Settings.Set("agent.sandbox.conflict.sandboxHead", JsonValue.String(conflict.SandboxHead));
        Host.Settings.Set("agent.sandbox.conflict.files", JsonValue.Array(conflict.Files.Select(JsonValue.String)));
        PersistSettings();
    }

    private void ClearPersistedSandboxConflict()
    {
        foreach (var key in new[] { "originBranch", "originHead", "sandboxHead", "files" })
            Host.Settings.Set("agent.sandbox.conflict." + key, JsonValue.Null);
    }

    private static SandboxConflict? ReadPersistedConflict(SandboxWorkspace sandbox, ISettingsRegistry settings)
    {
        var originHead = settings.Get("agent.sandbox.conflict.originHead")?.AsString();
        var sandboxHead = settings.Get("agent.sandbox.conflict.sandboxHead")?.AsString();
        var files = (settings.Get("agent.sandbox.conflict.files")?.AsArray() ?? [])
            .Select(item => item.AsString()).Where(item => !string.IsNullOrWhiteSpace(item)).Cast<string>().ToArray();
        return !string.IsNullOrWhiteSpace(originHead) && !string.IsNullOrWhiteSpace(sandboxHead) && files.Length > 0
            ? new SandboxConflict(sandbox, settings.Get("agent.sandbox.conflict.originBranch")?.AsString() ?? sandbox.OriginBranch, originHead, sandboxHead, files)
            : null;
    }

    private static bool SameWorkspacePath(string? left, string? right)
    {
        if (string.IsNullOrWhiteSpace(left) || string.IsNullOrWhiteSpace(right)) return false;
        try
        {
            var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
            return string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), comparison);
        }
        catch { return false; }
    }

    private static string GitStatus(string path)
    {
        try
        {
            var start = new ProcessStartInfo("git") { WorkingDirectory = path, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
            start.ArgumentList.Add("status"); start.ArgumentList.Add("--porcelain"); start.ArgumentList.Add("--untracked-files=all");
            using var process = Process.Start(start);
            if (process is null) return "unavailable";
            var output = process.StandardOutput.ReadToEndAsync();
            var error = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(10_000))
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                return "unavailable";
            }
            process.WaitForExit();
            var standardOutput = output.GetAwaiter().GetResult();
            var standardError = error.GetAwaiter().GetResult();
            return process.ExitCode == 0 ? standardOutput : standardError.Length > 0 ? standardError : "unavailable";
        }
        catch { return "unavailable"; }
    }
}
