// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using HarnessPluginKit;
using PluginRuntime;
using JsonValue = HarnessPluginKit.JsonValue;

namespace DotsHarnessCore;

public sealed class AppModel : ObservableObject
{
    private const string VoiceCredentialID = "voice.api.key";
    public enum AppearanceKind
    {
        System,
        Light,
        Dark,
    }

    private readonly Dictionary<AgentArea, string> _draftByArea = new()
    {
        [AgentArea.Chat] = "",
        [AgentArea.Coding] = "",
    };
    private readonly Dictionary<AgentArea, bool> _planModeByArea = new();
    private readonly Dictionary<AgentArea, ObservableCollection<ChatAttachment>> _draftAttachmentsByArea = new()
    {
        [AgentArea.Chat] = new ObservableCollection<ChatAttachment>(),
        [AgentArea.Coding] = new ObservableCollection<ChatAttachment>(),
    };
    private AppearanceKind _appearance = AppearanceKind.System;
    private bool _confirmBeforeExit = true;
    private bool _selfVerification = true;
    private bool _seedProjectRules = true;
    private string _preferredHost;
    private string _workspacePath;
    private AgentArea _activeArea;
    private VoiceInputProvider _voiceProvider = VoiceInputProvider.WhisperTinyQ5;
    private string _voiceApiEndpoint = "";
    private string _voiceApiKey = "";
    private string _voiceApiModel = "";
    private string _voiceApiRealtimeEndpoint = "";
    private string _voiceCustomModelPath = "";
    private bool _voiceIntroSeen;
    private double _visionModelProgress;
    private readonly ChatProjectStore _chatProjectStore;

    public ObservableCollection<ChatAttachment> DraftAttachments => _draftAttachmentsByArea[ActiveArea];

    public PluginCatalog Catalog { get; }
    public SkillCatalog Skills { get; }
    public SkillSuggestionMonitor SkillSuggestions { get; }
    public PluginHost Host { get; }
    public NativeMarketplaceClient Marketplace { get; }
    public SupportPaths Paths { get; }
    public ObservableCollection<string> CodingProjects { get; } = new();
    public ObservableCollection<ChatProject> ChatProjects { get; } = new();
    public AgentBridge ChatBridge { get; }
    public AgentBridge CodingBridge { get; }
    public AgentBridge Bridge => ActiveArea == AgentArea.Chat ? ChatBridge : CodingBridge;
    public SkillCatalog ActiveSkills => Bridge.Skills;
    public SkillSuggestionMonitor ActiveSkillSuggestions => Bridge.SkillSuggestions ?? SkillSuggestions;
    public BrowserBackend? SelectedBrowserBackend { get; private set; }
    public RemoteControlEventHub RemoteEvents { get; }
    public RemoteControlHost RemoteControl { get; }
    public RemotePairingInfo? RemotePairing => RemoteControl.Pairing;
    public RouterController ChatRouter { get; }
    public RouterController CodingRouter { get; }
    public RouterController Router => ActiveArea == AgentArea.Chat ? ChatRouter : CodingRouter;
    public LocalRuntimeController Local { get; }
    public VoiceInputController Voice { get; }
    public HarnessScheduler Scheduler { get; }
    public LocalizationService Localization { get; }
    public AppLanguage Language => Localization.Language;
    public bool IsRightToLeft => Localization.IsRightToLeft;

    public AgentArea ActiveArea
    {
        get => _activeArea;
        private set
        {
            if (!SetProperty(ref _activeArea, value)) return;
            OnPropertyChanged(nameof(Bridge));
            OnPropertyChanged(nameof(ActiveSkills));
            OnPropertyChanged(nameof(ActiveSkillSuggestions));
            OnPropertyChanged(nameof(Router));
            OnPropertyChanged(nameof(Conversations));
            OnPropertyChanged(nameof(Selected));
            OnPropertyChanged(nameof(SelectedConversationId));
            OnPropertyChanged(nameof(StatusLine));
            OnPropertyChanged(nameof(TerminalWorkspacePath));
            OnPropertyChanged(nameof(Draft));
            OnPropertyChanged(nameof(DraftAttachments));
            OnPropertyChanged(nameof(IsPlanMode));
            OnPropertyChanged(nameof(SelectedModelID));
        }
    }

    public string L(string key, params object?[] arguments) => Localization.Get(key, arguments);

    public string Draft
    {
        get => _draftByArea[ActiveArea];
        set
        {
            if (string.Equals(Draft, value, StringComparison.Ordinal)) return;
            _draftByArea[ActiveArea] = value;
            OnPropertyChanged();
        }
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

    public string? TerminalWorkspacePath => ActiveArea == AgentArea.Chat
        ? ChatBridge.ChatContextRoots.FirstOrDefault(root => root.Kind == ChatContextRootKind.Directory)?.Path
        : string.IsNullOrWhiteSpace(WorkspacePath) ? null : WorkspacePath;

    public bool IsPlanMode
    {
        get => _planModeByArea.GetValueOrDefault(ActiveArea);
        private set
        {
            if (IsPlanMode == value) return;
            _planModeByArea[ActiveArea] = value;
            OnPropertyChanged();
        }
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

    public AppModel(
        SupportPaths? paths = null,
        IEnumerable<Func<IHarnessPlugin>>? builtins = null,
        IProviderSecretStore? providerSecrets = null)
    {
        Paths = paths ?? SupportPaths.Default();
        Paths.Ensure();
        SessionAreaMigration.Run(Paths);
        _chatProjectStore = new ChatProjectStore(Paths.Root);
        foreach (var project in _chatProjectStore.Load()) ChatProjects.Add(project);
        Voice = new VoiceInputController(Paths);
        Catalog = new PluginCatalog(Paths);
        if (builtins is not null)
        {
            foreach (var builtin in builtins) Catalog.RegisterBuiltin(builtin);
        }
        Skills = new SkillCatalog(Paths);
        SkillSuggestions = new SkillSuggestionMonitor(Paths, Skills);
        SkillSuggestions.PropertyChanged += (_, _) => OnPropertyChanged(nameof(SkillSuggestions));
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
        Marketplace = new NativeMarketplaceClient(Paths, Catalog, Host, Remount);
        Host.ProvideService("support.paths", new PluginSupportPaths(Paths.Root, Paths.Plugins, Paths.Models, Paths.Runtime));
        Host.ProvideService(
            VisionFallbackDefaults.InstallerServiceName,
            new VisionMarketplaceInstaller(Paths, Catalog, Host, Remount));
        RegisterHostDataTopics();
        var storedArea = settings.Get("ui.activeArea")?.AsString()
            ?? settings.Get("ui.assistantMode")?.AsString();
        foreach (var project in LoadCodingProjects(settings))
        {
            if (!CodingProjects.Contains(project, StringComparer.OrdinalIgnoreCase)) CodingProjects.Add(project);
        }
        var storedWorkspace = NormalizeCodingWorkspace(settings.Get("agent.workspace")?.AsString());
        if (!string.IsNullOrWhiteSpace(storedWorkspace)
            && !CodingProjects.Contains(storedWorkspace, StringComparer.OrdinalIgnoreCase))
        {
            CodingProjects.Insert(0, storedWorkspace);
        }
        var hasCodingWorkspace = !string.IsNullOrWhiteSpace(storedWorkspace)
            || CodingProjects.Count > 0;
        _activeArea = string.Equals(storedArea, "chat", StringComparison.OrdinalIgnoreCase)
            || (!hasCodingWorkspace && !string.Equals(storedArea, "coding", StringComparison.OrdinalIgnoreCase))
            ? AgentArea.Chat
            : AgentArea.Coding;
        var providerStore = new NativeProviderStore(
            Paths.Root,
            providerSecrets ?? new PlatformProviderSecrets(Paths.Root));
        ChatRouter = new RouterController(Paths, Host.ImageAdapters, providerSecrets, providerStore);
        CodingRouter = new RouterController(Paths, Host.ImageAdapters, providerSecrets, providerStore);
        var legacyModel = settings.Get("agent.model")?.AsString() ?? "";
        ChatRouter.SelectedModelID = settings.Get("agent.model.chat")?.AsString() ?? legacyModel;
        CodingRouter.SelectedModelID = settings.Get("agent.model.coding")?.AsString() ?? legacyModel;
        var legacyEffort = settings.Get("agent.effort")?.AsString() ?? "";
        ChatRouter.SelectedEffort = settings.Get("agent.effort.chat")?.AsString() ?? legacyEffort;
        CodingRouter.SelectedEffort = settings.Get("agent.effort.coding")?.AsString() ?? legacyEffort;
        RemoteEvents = new RemoteControlEventHub(Paths.Root);
        void WireConnection(RouterController router)
        {
            router.ConnectionChanged += transition =>
            {
                var artifacts = new JsonArray();
                foreach (var artifact in transition.RemovedLocalArtifacts) artifacts.Add(artifact);
                RemoteEvents.Publish(
                    "connection.changed",
                    RemoteControlIdentity.WorkspaceId(WorkspacePath),
                    null,
                    new JsonObject
                    {
                        ["area"] = router == ChatRouter ? "chat" : "coding",
                        ["action"] = transition.Action,
                        ["previousConnectionLabel"] = transition.PreviousConnectionLabel,
                        ["currentConnectionLabel"] = transition.CurrentConnectionLabel,
                        ["cleanupStatus"] = transition.CleanupStatus,
                        ["removedLocalArtifacts"] = artifacts,
                        ["remoteDataTouched"] = transition.RemoteDataTouched,
                        ["userDataPreserved"] = transition.UserDataPreserved,
                    });
            };
        }
        WireConnection(ChatRouter);
        WireConnection(CodingRouter);
        ChatBridge = new AgentBridge(
            ChatRouter, Paths, Skills, Host, RemoteEvents, SkillSuggestions,
            AgentArea.Chat, AgentArea.Chat.SessionFileName(), new ChatContextStore(Paths.Root));
        CodingBridge = new AgentBridge(
            CodingRouter, Paths, Skills, Host, RemoteEvents, SkillSuggestions,
            AgentArea.Coding, AgentArea.Coding.SessionFileName());
        SelectedBrowserBackend = ParseBrowserBackend(settings.Get("agent.browserBackend")?.AsString());
        ChatBridge.SetBrowserBackend(SelectedBrowserBackend);
        CodingBridge.SetBrowserBackend(SelectedBrowserBackend);
        RemoteControl = new RemoteControlHost(CodingBridge, Paths, RemoteEvents, () => WorkspacePath);
        Local = new LocalRuntimeController(Paths, CodingRouter);
        var taskRunner = new ScheduledTaskRunner(Paths, CodingRouter);
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
        ChatBridge.SelfVerification = SelfVerification;
        CodingBridge.SelfVerification = SelfVerification;
        if (settings.Get("agent.seedProjectRules")?.AsBool() is { } seedProjectRules)
        {
            SeedProjectRules = seedProjectRules;
        }
        // Set before Start() binds the workspace, so a disabled setting never seeds.
        ChatBridge.SeedProjectRules = SeedProjectRules;
        CodingBridge.SeedProjectRules = SeedProjectRules;
        _voiceIntroSeen = settings.Get("ui.voiceIntroSeen")?.AsBool() ?? false;
        if (settings.Get("voice.provider")?.AsString() is { } voiceProvider
            && Enum.TryParse<VoiceInputProvider>(voiceProvider, ignoreCase: true, out var parsedVoiceProvider))
        {
            _voiceProvider = parsedVoiceProvider;
        }
        _voiceApiEndpoint = settings.Get("voice.api.endpoint")?.AsString() ?? "";
        MigrateVoiceApiKey(settings, settings.Get(VoiceCredentialID)?.AsString());
        _voiceApiModel = settings.Get("voice.api.model")?.AsString() ?? "";
        _voiceApiRealtimeEndpoint = settings.Get("voice.api.realtimeEndpoint")?.AsString() ?? "";
        _voiceCustomModelPath = settings.Get("voice.custom.path")?.AsString() ?? "";
        Voice.Configure(_voiceProvider, _voiceApiEndpoint, _voiceApiKey, _voiceApiModel, _voiceApiRealtimeEndpoint, _voiceCustomModelPath);
        PreferredHost = "native";
        WorkspacePath = storedWorkspace;
        if (string.IsNullOrWhiteSpace(WorkspacePath) && CodingProjects.Count > 0)
        {
            WorkspacePath = CodingProjects[0];
        }
        RemoteControl.SetWorkspacePath(WorkspacePath);
        Skills.SetWorkspace(string.IsNullOrWhiteSpace(WorkspacePath) ? null : WorkspacePath);
        SkillSuggestions.SetWorkspace(string.IsNullOrWhiteSpace(WorkspacePath) ? null : WorkspacePath);
        Remount();
        void WireBridge(AgentBridge bridge)
        {
            bridge.PropertyChanged += (_, _) =>
            {
                OnPropertyChanged(nameof(Conversations));
                OnPropertyChanged(nameof(Selected));
                OnPropertyChanged(nameof(SelectedConversationId));
                OnPropertyChanged(nameof(StatusLine));
                OnPropertyChanged(nameof(ActiveArea));
                OnPropertyChanged(nameof(TerminalWorkspacePath));
            };
            if (bridge.SkillSuggestions is { } bridgeSuggestions)
            {
                bridgeSuggestions.PropertyChanged += (_, _) =>
                {
                    if (ActiveArea == bridge.Area) OnPropertyChanged(nameof(ActiveSkillSuggestions));
                };
            }
            bridge.RunSummaryReceived += (_, _) =>
            {
                if (ActiveArea == bridge.Area) ScanSkillSuggestions();
            };
        }
        WireBridge(ChatBridge);
        WireBridge(CodingBridge);
        ChatRouter.PropertyChanged += (_, e) => OnPropertyChanged(e.PropertyName);
        CodingRouter.PropertyChanged += (_, e) => OnPropertyChanged(e.PropertyName);
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
        // Gateway bind + host DNS lookup can stall; keep them off the UI thread.
        _ = Task.Run(RemoteControl.Start);
        _ = ChatBridge.StartAsync("");
        _ = CodingBridge.StartAsync(WorkspacePath);
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
        _ = CodingRouter.RefreshAsync();
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

    public void SetActiveArea(AgentArea area)
    {
        if (ActiveArea == area) return;
        ActiveArea = area;
        Host.Settings.Set("ui.activeArea", JsonValue.String(area.WireValue()));
        Host.Settings.Set("ui.assistantMode", JsonValue.String(area.WireValue()));
        PersistSettings();
        OnPropertyChanged(nameof(Conversations));
        OnPropertyChanged(nameof(Selected));
        OnPropertyChanged(nameof(StatusLine));
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

    public void SetBrowserBackend(BrowserBackend? backend)
    {
        SelectedBrowserBackend = backend == BrowserBackend.Unknown ? null : backend;
        ChatBridge.SetBrowserBackend(SelectedBrowserBackend);
        CodingBridge.SetBrowserBackend(SelectedBrowserBackend);
        Host.Settings.Set(
            "agent.browserBackend",
            SelectedBrowserBackend is { } selected ? JsonValue.String(selected.ToString()) : JsonValue.Null);
        PersistSettings();
        OnPropertyChanged(nameof(SelectedBrowserBackend));
    }

    private static BrowserBackend? ParseBrowserBackend(string? value) =>
        Enum.TryParse<BrowserBackend>(value, ignoreCase: true, out var backend)
            && backend != BrowserBackend.Unknown
            ? backend
            : null;

    private async Task<TaskRunResult> RunScheduledTaskAsync(ScheduledTask task, ScheduledTaskRunner runner)
    {
        var result = await runner.RunAsync(task).ConfigureAwait(false);
        var workspace = ScheduledTaskRunner.NormalizeWorkspace(task.WorkspacePath);
        if (workspace is not null
            && ScheduledTaskRunner.NormalizeWorkspace(WorkspacePath) == workspace)
        {
            CodingBridge.MergeExternalConversations();
        }
        return result;
    }

    public void Remount()
    {
        Catalog.Refresh();
        Skills.Refresh();
        var document = CompositionLoader.LoadHost(Paths, Catalog);
        var issues = Host.Mount(document);
        ChatBridge.UpdateSystemPrompt(Host.Prompt.AssembledText());
        CodingBridge.UpdateSystemPrompt(Host.Prompt.AssembledText());
        if (issues.Count > 0)
        {
            ChatBridge.Status = string.Join(" · ", issues.Select(i => $"{i.RowId}: {i.Message}"));
            CodingBridge.Status = string.Join(" · ", issues.Select(i => $"{i.RowId}: {i.Message}"));
        }
        OnPropertyChanged(nameof(Catalog));
        OnPropertyChanged(nameof(Host));
        OnPropertyChanged(nameof(VisionPluginInstalled));
        OnPropertyChanged(nameof(VisionPluginEnabled));
        OnPropertyChanged(nameof(VisionState));
        VisionModelProgress = VisionState == VisionFallbackState.Ready ? 1 : 0;
    }

    /// <summary>Read-only app state a plugin can pull via <c>harness.host("&lt;topic&gt;")</c>.
    /// Delegates run on every plugin read — keep them to already-computed values.</summary>
    private void RegisterHostDataTopics()
    {
        Host.HostData.Register("app", () => JsonValue.Object(
            ("version", JsonValue.String(GetType().Assembly.GetName().Version?.ToString() ?? "")),
            ("platform", JsonValue.String(OperatingSystem.IsWindows() ? "windows" : "linux")),
            ("area", JsonValue.String(ActiveArea.WireValue())),
            ("locale", JsonValue.String(System.Globalization.CultureInfo.CurrentUICulture.Name))));
        Host.HostData.Register("workspace", () => JsonValue.Object(
            ("path", JsonValue.String(WorkspacePath ?? "")),
            ("hasWorkspace", JsonValue.Bool(!string.IsNullOrEmpty(WorkspacePath)))));
        Host.HostData.Register("model", () => JsonValue.Object(
            ("selectedId", JsonValue.String(SelectedModelID ?? ""))));
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

    public void NewConversation()
    {
        if (ActiveArea == AgentArea.Coding && string.IsNullOrWhiteSpace(WorkspacePath)) return;
        _ = Bridge.NewConversationAsync(ActiveArea == AgentArea.Coding ? WorkspacePath : null);
    }

    public void NewChatConversation(string? projectId = null)
    {
        SetActiveArea(AgentArea.Chat);
        _ = ChatBridge.NewConversationAsync();
        ChatBridge.SetChatProject(projectId);
    }

    public ChatProject CreateChatProject(string name, string description = "")
    {
        var project = new ChatProject
        {
            Name = string.IsNullOrWhiteSpace(name) ? "New chat project" : name.Trim(),
            Description = description.Trim(),
            SortOrder = ChatProjects.Count,
        };
        ChatProjects.Add(project);
        _chatProjectStore.Save(ChatProjects);
        OnPropertyChanged(nameof(ChatProjects));
        return project;
    }

    public void SetChatProject(string? projectId)
    {
        SetActiveArea(AgentArea.Chat);
        ChatBridge.SetChatProject(projectId);
        OnPropertyChanged(nameof(Conversations));
    }

    public void DeleteChatProject(string projectId)
    {
        if (ChatProjects.All(project => project.Id != projectId)) return;
        foreach (var conversation in ChatBridge.Conversations
                     .Where(item => item.ChatProjectId == projectId)
                     .ToList())
        {
            ChatBridge.SetChatProject(null, conversation.Id);
        }
        var project = ChatProjects.FirstOrDefault(item => item.Id == projectId);
        if (project is not null) ChatProjects.Remove(project);
        _chatProjectStore.Save(ChatProjects);
        OnPropertyChanged(nameof(ChatProjects));
        OnPropertyChanged(nameof(Conversations));
    }

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
        Host.Settings.Set($"agent.model.{ActiveArea.WireValue()}", JsonValue.String(Router.SelectedModelID));
        if (ActiveArea == AgentArea.Coding)
            Host.Settings.Set("agent.model", JsonValue.String(Router.SelectedModelID));
        // Levels are model-specific; a level the new model rejects must not carry over.
        if (!Router.Efforts(value).Contains(Router.SelectedEffort)) SetEffort("");
        PersistSettings();
        OnPropertyChanged(nameof(SelectedModelID));
    }

    /// Reasoning effort for the selected model. Empty means the provider default.
    public void SetEffort(string value)
    {
        Router.SelectedEffort = value;
        var stored = string.IsNullOrEmpty(value) ? JsonValue.Null : JsonValue.String(value);
        Host.Settings.Set($"agent.effort.{ActiveArea.WireValue()}", stored);
        if (ActiveArea == AgentArea.Coding)
            Host.Settings.Set("agent.effort", stored);
        PersistSettings();
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
        ChatBridge.SelfVerification = value;
        CodingBridge.SelfVerification = value;
        Host.Settings.Set("agent.selfVerification", JsonValue.Bool(value));
        PersistSettings();
    }

    public void SetSeedProjectRules(bool value)
    {
        SeedProjectRules = value;
        ChatBridge.SeedProjectRules = value;
        CodingBridge.SeedProjectRules = value;
        Host.Settings.Set("agent.seedProjectRules", JsonValue.Bool(value));
        PersistSettings();
    }

    public void SetConfirmBeforeExit(bool value)
    {
        ConfirmBeforeExit = value;
        Host.Settings.Set("ui.confirmBeforeExit", JsonValue.Bool(value));
        PersistSettings();
    }

    // --- Legal documents & consent (see shared/LegalConsent.cs) ---------------

    private sealed class LegalSettingsStore(ISettingsRegistry settings) : ILegalStore
    {
        public string? Get(string key) => settings.Get(key)?.AsString();
        public void Set(string key, string value) => settings.Set(key, JsonValue.String(value));
    }

    private LegalService? _legal;
    private LegalService Legal => _legal ??= new LegalService(new LegalSettingsStore(Host.Settings), Paths.Root);

    public LegalDocuments? LegalDocuments { get; private set; }
    public bool LegalNeedsAcceptance { get; private set; }
    public bool LegalLoadFailed { get; private set; }

    public async Task LoadLegalAsync()
    {
        var lang = Language == AppLanguage.System
            ? AppLanguages.EffectiveSystemLanguage().Code()
            : Language.Code();
        var docs = await Legal.FetchAsync(lang).ConfigureAwait(false);
        if (docs is not null)
        {
            LegalDocuments = docs;
            LegalNeedsAcceptance = Legal.NeedsAcceptance(docs);
            LegalLoadFailed = false;
        }
        else
        {
            LegalLoadFailed = true;
            LegalNeedsAcceptance = !Legal.HasAnyAcceptance;
        }
        OnPropertyChanged(nameof(LegalDocuments));
        OnPropertyChanged(nameof(LegalNeedsAcceptance));
        OnPropertyChanged(nameof(LegalLoadFailed));
    }

    public void AcceptLegal()
    {
        if (LegalDocuments is not { } docs) return;
        Legal.Accept(docs);
        LegalNeedsAcceptance = false;
        PersistSettings();
        OnPropertyChanged(nameof(LegalNeedsAcceptance));
    }

    public bool LegalConsent(string name) => Legal.GetConsent(name);

    public bool AiTransferAllowed => Legal.AiTransferAllowed;

    public void SetPreferredHost(string value)
    {
        PreferredHost = value;
        Host.Settings.Set("agent.host", JsonValue.String(value));
        PersistSettings();
    }

    public void SetWorkspace(string value)
    {
        SetActiveArea(AgentArea.Coding);
        var normalized = NormalizeCodingWorkspace(value);
        WorkspacePath = normalized;
        if (!string.IsNullOrWhiteSpace(normalized)
            && !CodingProjects.Contains(normalized, StringComparer.OrdinalIgnoreCase))
        {
            CodingProjects.Insert(0, normalized);
        }
        PersistCodingProjects();
        RemoteControl.SetWorkspacePath(normalized);
        Skills.SetWorkspace(string.IsNullOrWhiteSpace(normalized) ? null : normalized);
        SkillSuggestions.SetWorkspace(string.IsNullOrWhiteSpace(normalized) ? null : normalized);
        Host.Settings.Set("agent.workspace", JsonValue.String(normalized));
        PersistSettings();
        _ = CodingBridge.StartAsync(normalized);
        OnPropertyChanged(nameof(CodingProjects));
    }

    /// <summary>
    /// Re-scans recent user prompts for a repeated pattern worth turning into a
    /// skill. The active area owns the suggestion monitor; no other area's
    /// pending suggestion is exposed to the current conversation UI.
    /// </summary>
    public void ScanSkillSuggestions()
    {
        var prompts = Selected?.Messages
            .Where(m => m.Kind == ChatKind.User)
            .Select(m => m.Text)
            ?? Enumerable.Empty<string>();
        ActiveSkillSuggestions.Scan(prompts);
    }

    public string AcceptSkillSuggestion(string name, string description, string? body = null) =>
        ActiveSkillSuggestions.AcceptCurrent(name, description, body);

    public void DismissSkillSuggestion() => ActiveSkillSuggestions.DismissCurrent();

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
    public void SetVoiceApiKey(string value)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                Router.Store.Secrets.Delete(VoiceCredentialID);
                if (Router.Store.Secrets.Read(VoiceCredentialID) is not null)
                    throw new NativeProviderException("The voice API key could not be removed from secure storage.");
            }
            else
            {
                Router.Store.Secrets.Write(VoiceCredentialID, value);
                if (!string.Equals(Router.Store.Secrets.Read(VoiceCredentialID), value, StringComparison.Ordinal))
                    throw new NativeProviderException("The voice API key could not be verified in secure storage.");
            }
            VoiceApiKey = value;
            ConfigureVoice();
            Host.Settings.Remove(VoiceCredentialID);
            PersistSettings();
        }
        catch (Exception error)
        {
            Router.Error = $"Voice API key was not stored securely: {error.Message}";
        }
    }
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

    private void MigrateVoiceApiKey(InMemorySettingsRegistry settings, string? legacy)
    {
        try
        {
            var stored = Router.Store.Secrets.Read(VoiceCredentialID);
            if (stored is not null)
            {
                _voiceApiKey = stored;
                if (legacy is not null)
                {
                    settings.Remove(VoiceCredentialID);
                    PersistSettings();
                }
                return;
            }

            if (string.IsNullOrWhiteSpace(legacy))
            {
                if (legacy is not null)
                {
                    settings.Remove(VoiceCredentialID);
                    PersistSettings();
                }
                return;
            }

            Router.Store.Secrets.Write(VoiceCredentialID, legacy);
            if (!string.Equals(Router.Store.Secrets.Read(VoiceCredentialID), legacy, StringComparison.Ordinal))
                throw new NativeProviderException("The voice API key migration could not be verified.");
            _voiceApiKey = legacy;
            settings.Remove(VoiceCredentialID);
            PersistSettings();
        }
        catch (Exception error)
        {
            _voiceApiKey = legacy ?? "";
            Router.Error = $"Voice API key migration failed; the existing setting was preserved: {error.Message}";
        }
    }

    public void PersistSettings()
    {
        var snapshot = Host.Settings.Snapshot();
        File.WriteAllText(Paths.Settings, JsonValue.Object(snapshot).ToJson());
        if (!OperatingSystem.IsWindows())
            try { File.SetUnixFileMode(Paths.Settings, UnixFileMode.UserRead | UnixFileMode.UserWrite); } catch { }
    }

    /// <summary>Only the plugin/session prompt sections, fed back into <c>UpdateSystemPrompt</c>.</summary>
    public string AssembledSystemPrompt() => Host.Prompt.AssembledText();

    /// <summary>
    /// Everything actually sent as the system prompt - core policy, plan rules,
    /// plugin text and skill metadata - broken out by section with sizes.
    /// </summary>
    public string EffectiveSystemPrompt() => Bridge.EffectiveSystemPromptReport(ActiveArea == AgentArea.Chat ? null : WorkspacePath);

    private void PersistCodingProjects()
    {
        Host.Settings.Set(
            "agent.projects",
            JsonValue.Array(CodingProjects.Select(JsonValue.String)));
    }

    private static IReadOnlyList<string> LoadCodingProjects(InMemorySettingsRegistry settings)
    {
        return (settings.Get("agent.projects")?.AsArray() ?? Array.Empty<JsonValue>())
            .Select(item => NormalizeCodingWorkspace(item.AsString()))
            .Where(path => !string.IsNullOrWhiteSpace(path))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private static string NormalizeCodingWorkspace(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return "";
        try
        {
            var full = Path.GetFullPath(value.Trim());
            return Directory.Exists(full) ? full : "";
        }
        catch { return ""; }
    }

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
        // Every catalog entry (builtin + installed) mounts by default. host.patch.yml is
        // only an override layer: ordering, config merge, explicit disable/enable.
        // NOTE: an entry's `isolate:` key is inert here — PluginHost.Mount only honors it
        // on a Session-plane document, and this path always builds a Host-plane one.
        foreach (var item in catalog.Entries.OrderBy(e => e.Manifest.Id, StringComparer.Ordinal))
        {
            if (entries.Any(entry => entry.Plugin == item.Manifest.Id))
            {
                continue;
            }
            entries.Add(new CompositionEntry(item.Manifest.Id, item.Manifest.Id));
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
