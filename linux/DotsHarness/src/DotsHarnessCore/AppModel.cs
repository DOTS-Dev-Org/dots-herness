// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using HarnessPluginKit;
using PluginRuntime;

namespace DotsHarnessCore;

public sealed class AppModel : ObservableObject
{
    public enum AppearanceKind
    {
        System,
        Light,
        Dark,
    }

    private string _draft = "";
    private AppearanceKind _appearance = AppearanceKind.System;
    private bool _confirmBeforeExit = true;
    private bool _selfVerification = true;
    private bool _seedProjectRules = true;
    private string _preferredHost;
    private string _workspacePath;
    private bool _isPlanMode;
    private VoiceInputProvider _voiceProvider = VoiceInputProvider.WhisperTinyQ5;
    private string _voiceApiEndpoint = "";
    private string _voiceApiKey = "";
    private string _voiceApiModel = "";
    private string _voiceApiRealtimeEndpoint = "";
    private string _voiceCustomModelPath = "";
    private bool _voiceIntroSeen;
    private double _visionModelProgress;

    public ObservableCollection<ChatAttachment> DraftAttachments { get; } = new();

    public PluginCatalog Catalog { get; }
    public SkillCatalog Skills { get; }
    public PluginHost Host { get; }
    public SupportPaths Paths { get; }
    public AgentBridge Bridge { get; }
    public RemoteControlEventHub RemoteEvents { get; }
    public RemoteControlHost RemoteControl { get; }
    public RemotePairingInfo? RemotePairing => RemoteControl.Pairing;
    public RouterController Router { get; }
    public LocalRuntimeController Local { get; }
    public VoiceInputController Voice { get; }
    public HarnessScheduler Scheduler { get; }
    public LocalizationService Localization { get; }
    public AppLanguage Language => Localization.Language;
    public bool IsRightToLeft => Localization.IsRightToLeft;

    public string L(string key, params object?[] arguments) => Localization.Get(key, arguments);

    public string Draft
    {
        get => _draft;
        set => SetProperty(ref _draft, value);
    }

    public AppearanceKind Appearance
    {
        get => _appearance;
        private set => SetProperty(ref _appearance, value);
    }

    public bool ConfirmBeforeExit
    {
        get => _confirmBeforeExit;
        private set => SetProperty(ref _confirmBeforeExit, value);
    }

    /// <summary>Agent runs its own build/test/check after each change. Default on.</summary>
    public bool SelfVerification
    {
        get => _selfVerification;
        private set => SetProperty(ref _selfVerification, value);
    }

    /// <summary>
    /// Seed AGENTS.md and CLAUDE.md into a workspace that ships neither, once
    /// when the workspace opens. Default on; off means nothing is ever created.
    /// </summary>
    public bool SeedProjectRules
    {
        get => _seedProjectRules;
        private set => SetProperty(ref _seedProjectRules, value);
    }

    public string PreferredHost
    {
        get => _preferredHost;
        private set => SetProperty(ref _preferredHost, value);
    }

    public string WorkspacePath
    {
        get => _workspacePath;
        private set => SetProperty(ref _workspacePath, value);
    }

    public bool IsPlanMode
    {
        get => _isPlanMode;
        private set => SetProperty(ref _isPlanMode, value);
    }

    public VoiceInputProvider VoiceProvider
    {
        get => _voiceProvider;
        private set => SetProperty(ref _voiceProvider, value);
    }

    public string VoiceApiEndpoint
    {
        get => _voiceApiEndpoint;
        private set => SetProperty(ref _voiceApiEndpoint, value);
    }

    public string VoiceApiKey
    {
        get => _voiceApiKey;
        private set => SetProperty(ref _voiceApiKey, value);
    }

    public string VoiceApiModel
    {
        get => _voiceApiModel;
        private set => SetProperty(ref _voiceApiModel, value);
    }

    public string VoiceApiRealtimeEndpoint
    {
        get => _voiceApiRealtimeEndpoint;
        private set => SetProperty(ref _voiceApiRealtimeEndpoint, value);
    }

    public string VoiceCustomModelPath
    {
        get => _voiceCustomModelPath;
        private set => SetProperty(ref _voiceCustomModelPath, value);
    }

    public bool ShowsVoiceIntro => !_voiceIntroSeen;
    public bool IsVoiceReady => Voice.IsReady;
    public bool IsVoiceRunning => Voice.IsRunning;

    public IReadOnlyList<Conversation> Conversations => Bridge.Conversations;

    public string? SelectedConversationId
    {
        get => Bridge.SelectedId;
        set
        {
            if (value is not null) Bridge.Select(value);
            OnPropertyChanged();
            OnPropertyChanged(nameof(Selected));
        }
    }

    public Conversation? Selected => Bridge.Selected;
    public string StatusLine => Bridge.Status;
    public bool VisionPluginInstalled => Catalog.Entries.Any(entry => entry.Manifest.Id == VisionFallbackDefaults.PluginId);
    public bool VisionPluginEnabled => Catalog.Entries.FirstOrDefault(entry => entry.Manifest.Id == VisionFallbackDefaults.PluginId)?.Enabled == true;
    public VisionFallbackState VisionState => Host.GetService<IVisionFallbackService>(VisionFallbackDefaults.ServiceName)?.State
        ?? VisionFallbackState.Unavailable;
    public double VisionModelProgress
    {
        get => _visionModelProgress;
        private set => SetProperty(ref _visionModelProgress, Math.Clamp(value, 0, 1));
    }
    public long VisionModelBytes => Host.GetService<IVisionFallbackService>(VisionFallbackDefaults.ServiceName)?.ModelBytes
        ?? VisionFallbackDefaults.ModelBytes;
    public string SelectedModelID
    {
        get => Router.SelectedModelID;
        set => SetSelectedModel(value);
    }

    public AppModel(SupportPaths? paths = null, IEnumerable<Func<IHarnessPlugin>>? builtins = null)
    {
        Paths = paths ?? SupportPaths.Default();
        Paths.Ensure();
        Voice = new VoiceInputController(Paths);
        Catalog = new PluginCatalog(Paths);
        if (builtins is not null)
        {
            foreach (var builtin in builtins) Catalog.RegisterBuiltin(builtin);
        }
        Skills = new SkillCatalog(Paths);
        var settings = LoadSettings(Paths.Settings);
        var migratedFableSetting = false;
        if (settings.Get("skills.fableMigration.v1") is null
            && new[] { "fable.enabled", "fableThinking.enabled", "dots.fable-thinking.enabled" }
                .Select(key => settings.Get(key)?.AsBool())
                .FirstOrDefault(value => value is not null) is { } legacyEnabled)
        {
            Skills.SetEnabled("fable-thinking", legacyEnabled);
            settings.Set("skills.fableMigration.v1", JsonValue.Bool(true));
            migratedFableSetting = true;
        }
        Localization = new LocalizationService();
        if (settings.Get("ui.language")?.AsString() is { } storedLanguage
            && AppLanguages.TryParse(storedLanguage, out var language))
        {
            Localization.SetLanguage(language);
        }
        Host = new PluginHost(Catalog, settings);
        Host.ProvideService("support.paths", new PluginSupportPaths(Paths.Root, Paths.Plugins, Paths.Models, Paths.Runtime));
        Host.ProvideService(
            VisionFallbackDefaults.InstallerServiceName,
            new VisionMarketplaceInstaller(Paths, Catalog, Host, Remount));
        Router = new RouterController(Paths, Host.ImageAdapters);
        Router.SelectedModelID = settings.Get("agent.model")?.AsString() ?? "";
        RemoteEvents = new RemoteControlEventHub(Paths.Root);
        Router.ConnectionChanged += transition =>
        {
            var artifacts = new JsonArray();
            foreach (var artifact in transition.RemovedLocalArtifacts) artifacts.Add(artifact);
            RemoteEvents.Publish(
                "connection.changed",
                RemoteControlIdentity.WorkspaceId(WorkspacePath),
                null,
                new JsonObject
                {
                    ["action"] = transition.Action,
                    ["previousConnectionLabel"] = transition.PreviousConnectionLabel,
                    ["currentConnectionLabel"] = transition.CurrentConnectionLabel,
                    ["cleanupStatus"] = transition.CleanupStatus,
                    ["removedLocalArtifacts"] = artifacts,
                    ["remoteDataTouched"] = transition.RemoteDataTouched,
                    ["userDataPreserved"] = transition.UserDataPreserved,
                });
        };
        Bridge = new AgentBridge(Router, Paths, Skills, Host, RemoteEvents);
        RemoteControl = new RemoteControlHost(Bridge, Paths, RemoteEvents, () => WorkspacePath);
        Local = new LocalRuntimeController(Paths, Router);
        var taskRunner = new ScheduledTaskRunner(Paths, Router);
        Scheduler = new HarnessScheduler(
            new TaskStore(Paths),
            task => RunScheduledTaskAsync(task, taskRunner),
            runsDueTasks: !IsBackgroundDaemonEnabled);
        if (settings.Get("ui.appearance")?.AsString() is { } stored
            && Enum.TryParse<AppearanceKind>(stored, ignoreCase: true, out var appearance))
        {
            Appearance = appearance;
        }
        if (settings.Get("ui.confirmBeforeExit")?.AsBool() is { } confirmBeforeExit)
        {
            ConfirmBeforeExit = confirmBeforeExit;
        }
        if (settings.Get("agent.selfVerification")?.AsBool() is { } selfVerification)
        {
            SelfVerification = selfVerification;
        }
        Bridge.SelfVerification = SelfVerification;
        if (settings.Get("agent.seedProjectRules")?.AsBool() is { } seedProjectRules)
        {
            SeedProjectRules = seedProjectRules;
        }
        // Set before Start() binds the workspace, so a disabled setting never seeds.
        Bridge.SeedProjectRules = SeedProjectRules;
        _voiceIntroSeen = settings.Get("ui.voiceIntroSeen")?.AsBool() ?? false;
        if (settings.Get("voice.provider")?.AsString() is { } voiceProvider
            && Enum.TryParse<VoiceInputProvider>(voiceProvider, ignoreCase: true, out var parsedVoiceProvider))
        {
            _voiceProvider = parsedVoiceProvider;
        }
        _voiceApiEndpoint = settings.Get("voice.api.endpoint")?.AsString() ?? "";
        _voiceApiKey = settings.Get("voice.api.key")?.AsString() ?? "";
        _voiceApiModel = settings.Get("voice.api.model")?.AsString() ?? "";
        _voiceApiRealtimeEndpoint = settings.Get("voice.api.realtimeEndpoint")?.AsString() ?? "";
        _voiceCustomModelPath = settings.Get("voice.custom.path")?.AsString() ?? "";
        Voice.Configure(_voiceProvider, _voiceApiEndpoint, _voiceApiKey, _voiceApiModel, _voiceApiRealtimeEndpoint, _voiceCustomModelPath);
        PreferredHost = "native";
        WorkspacePath = settings.Get("agent.workspace")?.AsString()
            ?? Environment.CurrentDirectory;
        RemoteControl.SetWorkspacePath(WorkspacePath);
        Skills.SetWorkspace(WorkspacePath);
        Remount();
        Bridge.PropertyChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(Conversations));
            OnPropertyChanged(nameof(Selected));
            OnPropertyChanged(nameof(SelectedConversationId));
            OnPropertyChanged(nameof(StatusLine));
        };
        Router.PropertyChanged += (_, e) => OnPropertyChanged(e.PropertyName);
        Local.PropertyChanged += (_, e) => OnPropertyChanged(e.PropertyName);
        Voice.PropertyChanged += (_, e) =>
        {
            OnPropertyChanged(nameof(IsVoiceReady));
            OnPropertyChanged(nameof(IsVoiceRunning));
            if (e.PropertyName is nameof(VoiceInputController.Provider)
                or nameof(VoiceInputController.ApiEndpoint)
                or nameof(VoiceInputController.ApiKey)
                or nameof(VoiceInputController.ApiModel)
                or nameof(VoiceInputController.RealtimeEndpoint))
            {
                OnPropertyChanged(nameof(VoiceProvider));
            }
        };
        Localization.PropertyChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(Language));
            OnPropertyChanged(nameof(IsRightToLeft));
        };
        if (migratedFableSetting) PersistSettings();
    }

    public void Start()
    {
        RemoteControl.Start();
        _ = Bridge.StartAsync(new Uri("http://127.0.0.1"), WorkspacePath);
        Scheduler.RunsDueTasks = !IsBackgroundDaemonEnabled;
        Scheduler.Start();
    }

    /// <summary>
    /// Headless bootstrap for the background scheduler daemon: mount plugins,
    /// then start the engine. No window, no workspace binding — each task carries
    /// its own workspace.
    /// </summary>
    public void StartHeadless()
    {
        RemoteControl.Start();
        Remount();
        _ = Router.RefreshAsync();
        Scheduler.RunsDueTasks = true;
        Scheduler.Start();
    }

    public RemotePairingInfo BeginRemotePairing()
    {
        var pairing = RemoteControl.BeginPairing(RemoteControl.PublicEndpoint ?? RemoteControl.PreferredEndpoint);
        OnPropertyChanged(nameof(RemotePairing));
        return pairing;
    }

    public Task<string> EnableRemoteCloudTunnelAsync() => RemoteControl.EnableCloudTunnelAsync();

    public void DisableRemoteCloudTunnel()
    {
        RemoteControl.DisableCloudTunnel();
        OnPropertyChanged(nameof(RemotePairing));
    }

    public bool IsBackgroundDaemonEnabled =>
        Host.Settings.Get("tasks.backgroundDaemon")?.AsBool() ?? false;

    /// <summary>
    /// Enable/disable the per-user OS job that runs tasks while the app is closed.
    /// While the daemon owns execution the in-app engine stops firing due tasks.
    /// </summary>
    public void SetBackgroundDaemonEnabled(bool enabled)
    {
        if (enabled) SchedulerService.Install();
        else SchedulerService.Uninstall();
        Host.Settings.Set("tasks.backgroundDaemon", JsonValue.Bool(enabled));
        PersistSettings();
        Scheduler.RunsDueTasks = !enabled;
    }

    private async Task<TaskRunResult> RunScheduledTaskAsync(ScheduledTask task, ScheduledTaskRunner runner)
    {
        var result = await runner.RunAsync(task).ConfigureAwait(false);
        var workspace = ScheduledTaskRunner.NormalizeWorkspace(task.WorkspacePath);
        if (workspace is not null
            && ScheduledTaskRunner.NormalizeWorkspace(WorkspacePath) == workspace)
        {
            Bridge.MergeExternalConversations();
        }
        return result;
    }

    public void Remount()
    {
        Catalog.Refresh();
        Skills.Refresh();
        var document = CompositionLoader.LoadHost(Paths, Catalog);
        var issues = Host.Mount(document);
        Bridge.UpdateSystemPrompt(Host.Prompt.AssembledText());
        if (issues.Count > 0)
        {
            Bridge.Status = string.Join(" · ", issues.Select(i => $"{i.RowId}: {i.Message}"));
        }
        OnPropertyChanged(nameof(Catalog));
        OnPropertyChanged(nameof(Host));
        OnPropertyChanged(nameof(VisionPluginInstalled));
        OnPropertyChanged(nameof(VisionPluginEnabled));
        OnPropertyChanged(nameof(VisionState));
        VisionModelProgress = VisionState == VisionFallbackState.Ready ? 1 : 0;
    }

    public void SetVisionPluginEnabled(bool enabled)
    {
        Catalog.SetEnabled(VisionFallbackDefaults.PluginId, enabled);
        Remount();
    }

    public async Task InstallVisionPluginAsync(CancellationToken cancellationToken = default)
    {
        var installer = Host.GetService<IVisionFallbackInstaller>(VisionFallbackDefaults.InstallerServiceName)
            ?? throw new InvalidOperationException("Vision marketplace installer is unavailable.");
        await installer.InstallAsync(cancellationToken);
        OnPropertyChanged(nameof(VisionPluginInstalled));
        OnPropertyChanged(nameof(VisionPluginEnabled));
        OnPropertyChanged(nameof(VisionState));
    }

    public async Task PrepareVisionAsync(CancellationToken cancellationToken = default)
    {
        var service = Host.GetService<IVisionFallbackService>(VisionFallbackDefaults.ServiceName)
            ?? throw new InvalidOperationException("Vision plugin is not installed.");
        VisionModelProgress = 0;
        try
        {
            await service.PrepareAsync(
                new Progress<double>(value => VisionModelProgress = value),
                cancellationToken);
        }
        finally
        {
            VisionModelProgress = VisionState == VisionFallbackState.Ready ? 1 : 0;
            OnPropertyChanged(nameof(VisionState));
        }
    }

    public async Task DeleteVisionModelAsync(CancellationToken cancellationToken = default)
    {
        var service = Host.GetService<IVisionFallbackService>(VisionFallbackDefaults.ServiceName)
            ?? throw new InvalidOperationException("Vision plugin is not installed.");
        await service.DeleteModelAsync(cancellationToken);
        VisionModelProgress = 0;
        OnPropertyChanged(nameof(VisionState));
    }

    public void RemoveVisionPlugin()
    {
        Host.UnmountAll();
        var pluginDirectory = Path.Combine(Paths.Plugins, VisionFallbackDefaults.PluginId);
        var modelDirectory = Path.Combine(Paths.Models, "vision", "smolvlm-256m-q8");
        if (Directory.Exists(pluginDirectory)) Directory.Delete(pluginDirectory, recursive: true);
        if (Directory.Exists(modelDirectory)) Directory.Delete(modelDirectory, recursive: true);
        Remount();
    }

    public void NewConversation() => _ = Bridge.NewConversationAsync(WorkspacePath);

    public void AddDraftAttachments(IEnumerable<string> paths)
    {
        foreach (var path in paths)
        {
            if (!ChatAttachment.TryCreate(path, out var attachment)
                || DraftAttachments.Any(item => string.Equals(item.FilePath, attachment.FilePath, StringComparison.OrdinalIgnoreCase))) continue;
            DraftAttachments.Add(attachment);
        }
    }

    public void RemoveDraftAttachment(ChatAttachment attachment) => DraftAttachments.Remove(attachment);

    public void Send(PromptMode mode = PromptMode.Queue)
    {
        var text = Draft.Trim();
        if (string.IsNullOrEmpty(text) && DraftAttachments.Count == 0)
        {
            if (Bridge.CanContinue) _ = Bridge.ContinueAsync();
            return;
        }
        var attachments = DraftAttachments.ToList();
        var isApproval = attachments.Count == 0
            && PlanApproval.Matches(text)
            && Bridge.Selected?.PendingPlanMessageId is { } planId
            && Bridge.Selected.Messages.Any(message => message.Id == planId && message.Kind == ChatKind.Plan);
        var planMode = IsPlanMode && !isApproval;
        if (isApproval) IsPlanMode = false;
        Draft = "";
        DraftAttachments.Clear();
        _ = Bridge.SendAsync(text, attachments, mode, planMode);
    }

    public void TogglePlanMode() => IsPlanMode = !IsPlanMode;

    public void ApplyPlan()
    {
        if (Bridge.Connection is null || Bridge.Selected?.PendingPlanMessageId is null || Bridge.Selected.Running) return;
        IsPlanMode = false;
        _ = Bridge.ApplyPlanAsync();
    }

    public void Cancel() => _ = Bridge.CancelAsync();

    public void Continue() => _ = Bridge.ContinueAsync();

    public void SetSelectedModel(string value)
    {
        Router.SelectedModelID = value;
        Host.Settings.Set("agent.model", JsonValue.String(Router.SelectedModelID));
        PersistSettings();
        OnPropertyChanged(nameof(SelectedModelID));
    }

    public void SetAppearance(AppearanceKind value)
    {
        Appearance = value;
        Host.Settings.Set("ui.appearance", JsonValue.String(value.ToString().ToLowerInvariant()));
        PersistSettings();
    }

    public void SetAppLanguage(AppLanguage value)
    {
        Localization.SetLanguage(value);
        Host.Settings.Set("ui.language", JsonValue.String(value.Code()));
        PersistSettings();
        OnPropertyChanged(nameof(Language));
        OnPropertyChanged(nameof(IsRightToLeft));
    }

    public void SetSelfVerification(bool value)
    {
        SelfVerification = value;
        Bridge.SelfVerification = value;
        Host.Settings.Set("agent.selfVerification", JsonValue.Bool(value));
        PersistSettings();
    }

    public void SetSeedProjectRules(bool value)
    {
        SeedProjectRules = value;
        Bridge.SeedProjectRules = value;
        Host.Settings.Set("agent.seedProjectRules", JsonValue.Bool(value));
        PersistSettings();
    }

    public void SetConfirmBeforeExit(bool value)
    {
        ConfirmBeforeExit = value;
        Host.Settings.Set("ui.confirmBeforeExit", JsonValue.Bool(value));
        PersistSettings();
    }

    public void SetPreferredHost(string value)
    {
        PreferredHost = value;
        Host.Settings.Set("agent.host", JsonValue.String(value));
        PersistSettings();
    }

    public void SetWorkspace(string value)
    {
        WorkspacePath = value;
        RemoteControl.SetWorkspacePath(value);
        Skills.SetWorkspace(value);
        Host.Settings.Set("agent.workspace", JsonValue.String(value));
        PersistSettings();
    }

    public void DismissVoiceIntro()
    {
        if (_voiceIntroSeen) return;
        _voiceIntroSeen = true;
        Host.Settings.Set("ui.voiceIntroSeen", JsonValue.Bool(true));
        OnPropertyChanged(nameof(ShowsVoiceIntro));
        PersistSettings();
    }

    public void SetVoiceProvider(VoiceInputProvider value)
    {
        if (VoiceProvider == value) return;
        VoiceProvider = value;
        ConfigureVoice();
        Host.Settings.Set("voice.provider", JsonValue.String(value.ToString()));
        PersistSettings();
    }

    public void SetVoiceApiEndpoint(string value) { VoiceApiEndpoint = value; ConfigureVoice(); Host.Settings.Set("voice.api.endpoint", JsonValue.String(value)); PersistSettings(); }
    public void SetVoiceApiKey(string value) { VoiceApiKey = value; ConfigureVoice(); Host.Settings.Set("voice.api.key", JsonValue.String(value)); PersistSettings(); }
    public void SetVoiceApiModel(string value) { VoiceApiModel = value; ConfigureVoice(); Host.Settings.Set("voice.api.model", JsonValue.String(value)); PersistSettings(); }
    public void SetVoiceApiRealtimeEndpoint(string value) { VoiceApiRealtimeEndpoint = value; ConfigureVoice(); Host.Settings.Set("voice.api.realtimeEndpoint", JsonValue.String(value)); PersistSettings(); }
    public void SetVoiceCustomModelPath(string value) { VoiceCustomModelPath = value; ConfigureVoice(); Host.Settings.Set("voice.custom.path", JsonValue.String(value)); PersistSettings(); }
    public Task StartVoiceAsync(CancellationToken ct = default) => Voice.StartAsync(ct);
    public Task StopVoiceAsync(CancellationToken ct = default) => Voice.StopAsync(ct);
    public Task EnsureVoiceAssetsAsync(Action<FileDownloader.Progress>? progress = null, CancellationToken ct = default) => Voice.EnsureAssetsAsync(progress, ct);

    private void ConfigureVoice() => Voice.Configure(
        VoiceProvider,
        VoiceApiEndpoint,
        VoiceApiKey,
        VoiceApiModel,
        VoiceApiRealtimeEndpoint,
        VoiceCustomModelPath);

    public void PersistSettings()
    {
        var snapshot = Host.Settings.Snapshot();
        File.WriteAllText(Paths.Settings, JsonValue.Object(snapshot).ToJson());
        try { File.SetUnixFileMode(Paths.Settings, UnixFileMode.UserRead | UnixFileMode.UserWrite); } catch { }
    }

    /// <summary>Only the plugin/session prompt sections, fed back into <c>UpdateSystemPrompt</c>.</summary>
    public string AssembledSystemPrompt() => Host.Prompt.AssembledText();

    /// <summary>
    /// Everything actually sent as the system prompt - core policy, plan rules,
    /// plugin text and skill metadata - broken out by section with sizes.
    /// </summary>
    public string EffectiveSystemPrompt() => Bridge.EffectiveSystemPromptReport(WorkspacePath);

    private static InMemorySettingsRegistry LoadSettings(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                var value = JsonValue.Parse(File.ReadAllText(path));
                if (value.AsObject() is { } obj)
                {
                    return new InMemorySettingsRegistry(obj);
                }
            }
        }
        catch
        {
            // ignore corrupt settings
        }
        return new InMemorySettingsRegistry();
    }
}

public static class CompositionLoader
{
    public static CompositionDocument BundledHost() => new(PluginPlane.Host, Array.Empty<CompositionEntry>());

    public static CompositionDocument LoadHost(SupportPaths paths, PluginCatalog catalog)
    {
        var document = BundledHost();
        if (File.Exists(paths.HostPatch))
        {
            try
            {
                var patches = MiniYaml.LoadPatches(File.ReadAllText(paths.HostPatch));
                document = CompositionPatch.Apply(patches, document);
            }
            catch
            {
                // keep bundled host if the user overlay is unreadable
            }
        }
        var entries = document.Entries.ToList();
        if (catalog.Entries.Any(entry => entry.Manifest.Id == VisionFallbackDefaults.PluginId)
            && entries.All(entry => entry.Plugin != VisionFallbackDefaults.PluginId))
        {
            entries.Add(new CompositionEntry(
                VisionFallbackDefaults.PluginId,
                VisionFallbackDefaults.PluginId));
        }
        for (var i = 0; i < entries.Count; i++)
        {
            var item = catalog.Entries.FirstOrDefault(e => e.Manifest.Id == entries[i].Plugin);
            if (item is not null && !item.Enabled)
            {
                entries[i] = entries[i].WithDisabled(true);
            }
        }
        return document.WithEntries(entries);
    }
}
