// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Text.Json.Nodes;
using HarnessPluginKit;
using PluginRuntime;
using JsonValue = HarnessPluginKit.JsonValue;

namespace DotsHarnessCore;

public sealed partial class AppModel : ObservableObject
{
    public event Action<InboxNotification>? ScheduledTaskNotificationRaised;

    private const string VoiceCredentialID = "voice.api.key";
    public enum AppearanceKind
    {
        System,
        Light,
        Dark,
    }

    private readonly ObservableCollection<ChatAttachment> _draftAttachments = new();
    private readonly HashSet<string> _unavailableProjectPaths = new(StringComparer.OrdinalIgnoreCase);
    private AppearanceKind _appearance = AppearanceKind.System;
    private bool _confirmBeforeExit = true;
    private bool _closeToTray = true;
    private bool _autoUpdate = true;
    private bool _selfVerification = true;
    private bool _skillSuggestionsEnabled = true;
    private bool _computerUseEnabled;
    private bool _seedProjectRules = true;
    private bool _autoApprovePlans;
    private WorkspaceConflictPolicy _workspaceConflictPolicy = DotsHarnessCore.WorkspaceConflictPolicy.WaitThenAsk;
    private int _conflictWaitSeconds = 30;
    private string _preferredHost;
    private string _workspacePath;
    private IReadOnlyList<SshHost> _sshHosts = [];
    private string? _workLocationAlias;
    private SshTarget? _remoteTarget;
    private string? _sshNotice;
    private string _draft = "";
    private bool _isPlanMode;
    private VoiceInputProvider _voiceProvider = VoiceInputProvider.WhisperTinyQ5;
    private string _voiceApiEndpoint = "";
    private string _voiceApiKey = "";
    private string _voiceApiModel = "";
    private string _voiceApiRealtimeEndpoint = "";
    private string _voiceCustomModelPath = "";
    private bool _voiceIntroSeen;
    private double _visionModelProgress;
    private IReadOnlyDictionary<KeyboardShortcutAction, UserKeyboardShortcut> _keyboardShortcuts =
        KeyboardShortcutCatalog.CreateDefaults();

    public ObservableCollection<ChatAttachment> DraftAttachments => _draftAttachments;

    public PluginCatalog Catalog { get; }
    public NotificationInboxStore NotificationInbox { get; }
    public SkillCatalog Skills { get; }
    public SkillSuggestionMonitor SkillSuggestions { get; }
    public PluginHost Host { get; }
    public NativeMarketplaceClient Marketplace { get; }
    public MarketplaceSession MarketplaceSession { get; }
    public MarketplacePublisher MarketplacePublisher { get; }
    public SupportPaths Paths { get; }
    public ObservableCollection<string> Projects { get; } = new();
    public AgentBridge Bridge { get; }
    public SkillCatalog ActiveSkills => Bridge.Skills;
    public SkillSuggestionMonitor ActiveSkillSuggestions => Bridge.SkillSuggestions ?? SkillSuggestions;
    public string? ActiveFollowUpSuggestion => Bridge.FollowUpConversationId == SelectedConversationId
        ? Bridge.FollowUpSuggestion
        : null;
    public IReadOnlyList<string> ActiveFollowUpChoices => Bridge.FollowUpConversationId == SelectedConversationId
        ? Bridge.FollowUpChoices
        : Array.Empty<string>();
    public BrowserBackend? SelectedBrowserBackend { get; private set; }
    public RemoteControlEventHub RemoteEvents { get; }
    public RemoteControlHost RemoteControl { get; }
    public RemotePairingInfo? RemotePairing => RemoteControl.Pairing;
    public RouterController Router { get; }
    public WorkspaceConflictPolicy WorkspaceConflictPolicy => _workspaceConflictPolicy;
    public int ConflictWaitSeconds => _conflictWaitSeconds;
    public McpRegistry McpRegistry { get; }
    public LocalRuntimeController Local { get; }
    public VoiceInputController Voice { get; }
    public HarnessScheduler Scheduler { get; }
    public LocalizationService Localization { get; }
    public AppLanguage Language => Localization.Language;
    public bool IsRightToLeft => Localization.IsRightToLeft;
    public IReadOnlyDictionary<KeyboardShortcutAction, UserKeyboardShortcut> KeyboardShortcuts => _keyboardShortcuts;

    public string L(string key, params object?[] arguments) => Localization.Get(key, arguments);

    public string Draft
    {
        get => _draft;
        set
        {
            if (string.Equals(Draft, value, StringComparison.Ordinal)) return;
            _draft = value;
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

    /// <summary>Closing the window only hides it; the tray keeps runs and terminals alive.</summary>
    public bool CloseToTray
    {
        get => _closeToTray;
        private set => SetProperty(ref _closeToTray, value);
    }

    /// <summary>Installs a found release on launch and relaunches. Default on.</summary>
    public bool AutoUpdate
    {
        get => _autoUpdate;
        private set => SetProperty(ref _autoUpdate, value);
    }

    /// <summary>Agent runs its own build/test/check after each change. Default on.</summary>
    public bool SelfVerification
    {
        get => _selfVerification;
        private set => SetProperty(ref _selfVerification, value);
    }

    /// <summary>Show skill-suggestion cards when a command or prompt repeats. Default on.</summary>
    public bool SkillSuggestionsEnabled
    {
        get => _skillSuggestionsEnabled;
        private set => SetProperty(ref _skillSuggestionsEnabled, value);
    }

    public bool IsComputerUseEnabled
    {
        get => _computerUseEnabled;
        private set => SetProperty(ref _computerUseEnabled, value);
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

    /// <summary>Top-level areas of the window, picked from the rail. Home is the chat shell.</summary>
    public static readonly string[] Sections = ["home", "media", "tasks", "bots", "marketplace", "memory"];

    private string _section = "home";
    /// <summary>The rail section on display; mirrors macOS AppModel.section.</summary>
    public string Section { get => _section; set => SetProperty(ref _section, Sections.Contains(value) ? value : "home"); }

    private MediaStudioStore? _mediaStudio;
    private MusicStudioStore? _musicStudio;
    private BotStore? _bots;
    public MediaStudioStore MediaStudio => _mediaStudio ??= new(Path.Combine(Paths.Root, "media-studio"));
    public MusicStudioStore MusicStudio => _musicStudio ??= new(Path.Combine(Paths.Root, "music-studio"));
    public BotStore Bots => _bots ??= new(Path.Combine(Paths.Root, "bots"), Router, Paths, Localization, () => EffectiveSystemPrompt());
    public IProviderSecretStore Secrets => Router.Store.Secrets;

    /// <summary>The person's switch for memory as a whole; see AgentBridge.MemoryEnabled.</summary>
    public bool MemoryEnabled => Bridge.MemoryEnabled;

    /// <summary>How often finished tasks are turned into findings: off, hourly, daily or weekly.</summary>
    public string MemoryScanInterval { get; private set; } = "daily";

    public static readonly string[] MemoryScanIntervals = ["off", "hourly", "daily", "weekly"];

    private static TimeSpan? MemoryScanSpan(string interval) => interval switch
    {
        "off" => null,
        "hourly" => TimeSpan.FromHours(1),
        "weekly" => TimeSpan.FromDays(7),
        _ => TimeSpan.FromDays(1),
    };

    public void SetMemoryEnabled(bool value)
    {
        Bridge.MemoryEnabled = value;
        Host.Settings.Set("memory.enabled", JsonValue.Bool(value));
        PersistSettings();
        OnPropertyChanged(nameof(MemoryEnabled));
    }

    public void SetMemoryScanInterval(string interval)
    {
        if (!MemoryScanIntervals.Contains(interval)) return;
        MemoryScanInterval = interval;
        Bridge.MemoryScanInterval = MemoryScanSpan(interval);
        Host.Settings.Set("memory.scanInterval", JsonValue.String(interval));
        PersistSettings();
        OnPropertyChanged(nameof(MemoryScanInterval));
    }

    /// <summary>Apply generated plans without waiting for a separate plan approval.</summary>
    public bool AutoApprovePlans
    {
        get => _autoApprovePlans;
        private set => SetProperty(ref _autoApprovePlans, value);
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

    public IReadOnlyList<SshHost> SshHosts
    {
        get => _sshHosts;
        private set => SetProperty(ref _sshHosts, value);
    }

    public SshTarget? RemoteTarget
    {
        get => _remoteTarget;
        private set => SetProperty(ref _remoteTarget, value);
    }

    public bool IsRemoteWorkLocation => !string.IsNullOrWhiteSpace(_workLocationAlias);
    public string? SshNotice
    {
        get => _sshNotice;
        private set => SetProperty(ref _sshNotice, value);
    }

    public string WorkLocationLabel => IsRemoteWorkLocation
        ? RemoteTarget is { } target ? $"{target.Alias}: {target.RemotePath}" : _workLocationAlias ?? "SSH"
        : L("workLocation.local");

    public string? TerminalWorkspacePath => IsRemoteWorkLocation
        ? RemoteTarget?.Identity
        : Bridge.Selected is { } selected
            ? selected.Cwd
            : string.IsNullOrWhiteSpace(WorkspacePath) ? null : WorkspacePath;

    public bool ActiveProjectLocationAvailable =>
        !string.IsNullOrWhiteSpace(WorkspacePath) && Directory.Exists(WorkspacePath);

    public IReadOnlyList<string> ConnectedProjectPaths =>
        Projects.Where(path => Directory.Exists(path)).ToArray();

    public bool IsNoProjectScope => Bridge.IsNoProjectScope;

    public string? MissingProjectPath
    {
        get
        {
            var path = Bridge.Selected is { } selected ? selected.Cwd : WorkspacePath;
            return !string.IsNullOrWhiteSpace(path) && !Directory.Exists(path) ? path : null;
        }
    }

    public bool IsPlanMode
    {
        get => _isPlanMode;
        private set
        {
            if (IsPlanMode == value) return;
            _isPlanMode = value;
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
        NotificationInbox = new NotificationInboxStore(Path.Combine(Paths.Root, "notifications.json"));
        SandboxStore = new SandboxWorkspaces(Paths.Root);
        SessionAreaMigration.Run(Paths);
        Voice = new VoiceInputController(Paths);
        Catalog = new PluginCatalog(Paths);
        Catalog.RegisterBuiltin(() => new NativePluginAuthor(Catalog));
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
        _ = Localization.LoadLanguagePackAsync();
        var credentialStore = providerSecrets ?? new PlatformProviderSecrets(Paths.Root);
        MarketplaceSession = new MarketplaceSession(credentialStore);
        MarketplacePublisher = new MarketplacePublisher(MarketplaceSession);
        Host = new PluginHost(Catalog, settings);
        _keyboardShortcuts = KeyboardShortcutCatalog.Load(Host.Settings);
        Marketplace = new NativeMarketplaceClient(Paths, Catalog, Host, Remount, session: MarketplaceSession);
        Host.ProvideService("support.paths", new PluginSupportPaths(Paths.Root, Paths.Plugins, Paths.Models, Paths.Runtime));
        Host.ProvideService(
            VisionFallbackDefaults.InstallerServiceName,
            new VisionMarketplaceInstaller(Paths, Catalog, Host, Remount));
        RegisterHostDataTopics();
        foreach (var project in LoadProjects(settings))
        {
            if (!Projects.Contains(project, StringComparer.OrdinalIgnoreCase)) Projects.Add(project);
        }
        var hasStoredWorkspaceSetting = settings.Get("agent.workspace") is not null;
        var storedWorkspace = NormalizeProjectIdentity(settings.Get("agent.workspace")?.AsString());
        if (!string.IsNullOrWhiteSpace(storedWorkspace)
            && !Projects.Contains(storedWorkspace, StringComparer.OrdinalIgnoreCase))
        {
            Projects.Insert(0, storedWorkspace);
        }
        var providerStore = new NativeProviderStore(
            Paths.Root,
            credentialStore);
        Router = new RouterController(Paths, Host.ImageAdapters, credentialStore, providerStore);
        // Cached catalog applies at once; the fetch refreshes it in the background and never blocks startup.
        var remoteCatalogPath = Path.Combine(Paths.Root, "providers.remote.json");
        RemoteModelCatalog.LoadCache(remoteCatalogPath);
        _ = RemoteModelCatalog.RefreshAsync(remoteCatalogPath);
        Router.ContextCompactionThresholdPercent = Math.Clamp(
            settings.Get("agent.contextCompaction.thresholdPercent")?.AsInt() ?? 90,
            0,
            100);
        var legacyModel = settings.Get("agent.model")?.AsString() ?? "";
        Router.SelectedModelID = settings.Get("agent.model.coding")?.AsString() ?? legacyModel;
        var legacyEffort = settings.Get("agent.effort")?.AsString() ?? "";
        Router.SelectedEffort = settings.Get("agent.effort.coding")?.AsString() ?? legacyEffort;
        Router.UsageMode = ParseUsageMode(settings.Get("agent.usageMode.coding")?.AsString()
            ?? settings.Get("agent.usageMode")?.AsString());
        Router.ResponseStylePreference = ParseResponseStylePreference(
            settings.Get("agent.responseStyle")?.AsString());
        Router.AutoAccountFailoverAfterLimit = settings.Get("agent.autoAccountFailoverAfterLimit")?.AsBool() ?? false;
        Router.SubagentsPreference = settings.Get("agent.subagentsEnabled")?.AsBool();
        Router.FastMode = settings.Get("agent.fast")?.AsBool() ?? false;
        _workspaceConflictPolicy = Enum.TryParse<WorkspaceConflictPolicy>(
            settings.Get("agent.workspaceConflictPolicy")?.AsString(), ignoreCase: true, out var conflictPolicy)
            ? conflictPolicy
            : DotsHarnessCore.WorkspaceConflictPolicy.WaitThenAsk;
        _conflictWaitSeconds = Math.Clamp(settings.Get("agent.conflictWaitSeconds")?.AsInt() ?? 30, 0, 300);
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
                        ["scope"] = "project",
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
        WireConnection(Router);
        Bridge = new AgentBridge(
            Router, Paths, Skills, Host, RemoteEvents, SkillSuggestions);
        Bridge.AssistantResponseReceived += OnInboxAssistantResponse;
        Bridge.RunSummaryReceived += OnInboxRunSummary;
        Bridge.AttentionNeeded += OnInboxAttentionNeeded;
        Bridge.SetWorkspaceConflictPolicy(_workspaceConflictPolicy);
        Bridge.SetConflictWaitSeconds(_conflictWaitSeconds);
        McpRegistry = new McpRegistry(Paths, providerStore.Secrets);
        Bridge.McpRegistry = McpRegistry;
        _ = Task.Run(async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(4));
            await McpRegistry.ConnectAllAsync();
        });
        SelectedBrowserBackend = ParseBrowserBackend(settings.Get("agent.browserBackend")?.AsString());
        Bridge.SetBrowserBackend(SelectedBrowserBackend);
        RemoteControl = new RemoteControlHost(
            Bridge,
            Paths,
            RemoteEvents,
            () => WorkspacePath,
            () => Projects
                .Where(path => !string.IsNullOrWhiteSpace(path) && Directory.Exists(path))
                .Select(path => new RemoteProjectDescriptor(
                    RemoteControlIdentity.WorkspaceId(path),
                    Path.GetFileName(path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)),
                    RemoteControlIdentity.WorkspaceId(path)) { WorkspacePath = path })
                .ToArray());
        RemoteControl.SharesWithLan = Host.Settings.Get("remote.control.shareWithLAN")?.AsBool() ?? false;
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
        if (settings.Get("ui.closeToTray")?.AsBool() is { } closeToTray)
        {
            CloseToTray = closeToTray;
        }
        if (settings.Get("updates.auto")?.AsBool() is { } autoUpdate)
        {
            AutoUpdate = autoUpdate;
        }
        if (settings.Get("agent.selfVerification")?.AsBool() is { } selfVerification)
        {
            SelfVerification = selfVerification;
        }
        Bridge.SelfVerification = SelfVerification;
        if (settings.Get("skills.suggestions.enabled")?.AsBool() is { } skillSuggestionsEnabled)
        {
            SkillSuggestionsEnabled = skillSuggestionsEnabled;
        }
        SkillSuggestions.Enabled = SkillSuggestionsEnabled;
        IsComputerUseEnabled = settings.Get("agent.computerUseEnabled")?.AsBool() ?? false;
        Bridge.IsComputerUseEnabled = IsComputerUseEnabled;
        if (settings.Get("agent.seedProjectRules")?.AsBool() is { } seedProjectRules)
        {
            SeedProjectRules = seedProjectRules;
        }
        // Set before Start() binds the workspace, so a disabled setting never seeds.
        Bridge.SeedProjectRules = SeedProjectRules;
        // The same keys macOS stores them under.
        Bridge.MemoryEnabled = settings.Get("memory.enabled")?.AsBool() ?? true;
        if (settings.Get("memory.scanInterval")?.AsString() is { } scanInterval && MemoryScanIntervals.Contains(scanInterval))
        {
            MemoryScanInterval = scanInterval;
        }
        Bridge.MemoryScanInterval = MemoryScanSpan(MemoryScanInterval);
        if (settings.Get("agent.autoApprovePlans")?.AsBool() is { } autoApprovePlans)
        {
            AutoApprovePlans = autoApprovePlans;
        }
        Bridge.AutoApprovePlans = AutoApprovePlans;
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
        if (string.IsNullOrWhiteSpace(WorkspacePath) && Projects.Count > 0 && !hasStoredWorkspaceSetting)
        {
            WorkspacePath = Projects[0];
        }
        RefreshSshHosts();
        var workLocation = Host.Settings.Get("agent.workLocation")?.AsString() ?? "local";
        _workLocationAlias = workLocation.StartsWith("remote:", StringComparison.Ordinal)
            ? workLocation["remote:".Length..]
            : null;
        Bridge.SetRemoteWorkLocationSelected(IsRemoteWorkLocation);
        if (_workLocationAlias is { Length: > 0 } alias
            && SshHosts.Any(host => host.Alias.Equals(alias, StringComparison.OrdinalIgnoreCase)))
        {
            var remotePath = Host.Settings.Get(RemotePathSettingKey(alias))?.AsString();
            if (!string.IsNullOrWhiteSpace(remotePath))
            {
                RemoteTarget = new SshTarget(alias, remotePath);
                Bridge.SetRemoteTarget(RemoteTarget);
            }
            else SshNotice = L("ssh.chooseRemoteFolder");
        }
        else if (_workLocationAlias is { Length: > 0 } missingAlias)
            SshNotice = L("ssh.error.notReachable", missingAlias);
        RestoreSandboxState(Host.Settings);
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
                OnPropertyChanged(nameof(TerminalWorkspacePath));
                OnPropertyChanged(nameof(IsNoProjectScope));
                OnPropertyChanged(nameof(MissingProjectPath));
                OnPropertyChanged(nameof(ActiveFollowUpSuggestion));
                OnPropertyChanged(nameof(ActiveFollowUpChoices));
            };
            if (bridge.SkillSuggestions is { } bridgeSuggestions)
            {
                bridgeSuggestions.PropertyChanged += (_, _) =>
                {
                    OnPropertyChanged(nameof(ActiveSkillSuggestions));
                };
            }
            bridge.PlanAutoApproved += (_, _) =>
            {
                IsPlanMode = false;
            };
            bridge.PlanModeEntered += (_, _) => IsPlanMode = true;
            bridge.RunSummaryReceived += (_, _) =>
            {
                ScanSkillSuggestions();
            };
        }
        WireBridge(Bridge);
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
        // The remote gateway stays closed until the user turns it on.
        if (RemoteControlEnabled) _ = Task.Run(RemoteControl.Start);
        RestoreRemoteCloudTunnel();
        _ = Bridge.StartAsync(WorkspacePath);
        Scheduler.RunsDueTasks = !IsBackgroundDaemonEnabled;
        Scheduler.Start();
        Router.StartUsagePolling();
    }

    /// <summary>
    /// The remote-control gateway is opt-in: it only listens while the user
    /// keeps it on, and only on loopback unless LAN sharing is allowed.
    /// </summary>
    public bool RemoteControlEnabled
    {
        get => Host.Settings.Get("remote.control.enabled")?.AsBool() ?? false;
        set
        {
            Host.Settings.Set("remote.control.enabled", JsonValue.Bool(value));
            PersistSettings();
            if (value) _ = Task.Run(RemoteControl.Start); else RemoteControl.Stop();
            RestoreRemoteCloudTunnel();
        }
    }

    /// <summary>
    /// The tunnel comes up on its own whenever the gateway runs, so a phone off
    /// the LAN still reaches it; it carries sealed requests only (RemoteSealed),
    /// never plaintext. The phone learns a new URL from tunnel.ready/bootstrap.
    /// </summary>
    private void RestoreRemoteCloudTunnel()
    {
        if (!RemoteControlEnabled || Host.Settings.Get("remote.cloudTunnel")?.AsBool() == false || RemoteControl.PublicEndpoint is not null) return;
        _ = Task.Run(async () =>
        {
            try { await RemoteControl.EnableCloudTunnelAsync(); }
            catch { } // published as tunnel.failed by the host
        });
    }

    /// <summary>
    /// Sharing the gateway with the local network is a second, separate
    /// opt-in — the loopback default keeps it unreachable from the Wi-Fi.
    /// </summary>
    public bool RemoteControlSharesWithLAN
    {
        get => Host.Settings.Get("remote.control.shareWithLAN")?.AsBool() ?? false;
        set
        {
            Host.Settings.Set("remote.control.shareWithLAN", JsonValue.Bool(value));
            PersistSettings();
            RemoteControl.SharesWithLan = value;
        }
    }

    /// <summary>
    /// Headless bootstrap for the background scheduler daemon: mount plugins,
    /// then start the engine. No window, no workspace binding — each task carries
    /// its own workspace.
    /// </summary>
    public void StartHeadless()
    {
        // The remote gateway stays closed until the user turns it on.
        if (RemoteControlEnabled) RemoteControl.Start();
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

    public async Task<string> EnableRemoteCloudTunnelAsync()
    {
        var endpoint = await RemoteControl.EnableCloudTunnelAsync();
        Host.Settings.Set("remote.cloudTunnel", JsonValue.Bool(true));
        PersistSettings();
        return endpoint;
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
        Bridge.SetBrowserBackend(SelectedBrowserBackend);
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
        var conversation = result.ConversationId is null
            ? null
            : Bridge.Conversations.FirstOrDefault(item => item.Id == result.ConversationId);
        var notification = NotificationInbox.Append(
            "scheduledTask",
            L("tasks.notification.title"),
            task.Name,
            $"{L(result.Ok ? "tasks.notification.completed" : "tasks.notification.failed")}: {result.Message}",
            result.ConversationId,
            conversation?.Cwd);
        try { ScheduledTaskNotificationRaised?.Invoke(notification); } catch { }
        var workspace = ScheduledTaskRunner.NormalizeWorkspace(task.WorkspacePath);
        if (workspace is not null
            && ScheduledTaskRunner.NormalizeWorkspace(WorkspacePath) == workspace)
        {
            Bridge.MergeExternalConversations();
        }
        return result;
    }

    private void OnInboxAssistantResponse(object? sender, AssistantResponseEventArgs e)
    {
        var conversation = e.ConversationId is null
            ? null
            : Bridge.Conversations.FirstOrDefault(item => item.Id == e.ConversationId);
        NotificationInbox.Append(
            "completed",
            L("notifications.responseReady"),
            e.ConversationTitle,
            e.Text,
            e.ConversationId,
            conversation?.Cwd,
            isRead: false);
    }

    private void OnInboxRunSummary(object? sender, RunSummaryEventArgs e)
    {
        if (e.Outcome != "failed") return;
        var conversation = e.ConversationId is null
            ? null
            : Bridge.Conversations.FirstOrDefault(item => item.Id == e.ConversationId);
        NotificationInbox.Append(
            "failed",
            L("notifications.operationFailed"),
            e.ConversationTitle,
            e.FailureMessage ?? e.Summary.CleanupNote,
            e.ConversationId,
            conversation?.Cwd,
            isRead: e.ConversationId is not null && Bridge.SelectedId == e.ConversationId);
    }

    private void OnInboxAttentionNeeded(object? sender, RunAttentionEventArgs e)
    {
        var title = e.Kind switch
        {
            "question" => L("notifications.question"),
            "approval" => L("plan.waitingApproval"),
            _ => L("notifications.actionRequired"),
        };
        var conversation = Bridge.Conversations.FirstOrDefault(item => item.Id == e.ConversationId);
        NotificationInbox.Append(
            e.Kind,
            title,
            e.ConversationTitle,
            e.Detail,
            e.ConversationId,
            conversation?.Cwd,
            isRead: e.Kind != "question" && Bridge.SelectedId == e.ConversationId);
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

    /// <summary>Read-only app state a plugin can pull via <c>harness.host("&lt;topic&gt;")</c>.
    /// Delegates run on every plugin read — keep them to already-computed values.</summary>
    private void RegisterHostDataTopics()
    {
        Host.HostData.Register("app", () => JsonValue.Object(
            ("version", JsonValue.String(GetType().Assembly.GetName().Version?.ToString() ?? "")),
            ("platform", JsonValue.String(OperatingSystem.IsWindows() ? "windows" : "linux")),
            ("scope", JsonValue.String("project")),
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

    public void NewConversation() => _ = NewConversationAsync();

    public async Task NewConversationAsync()
    {
        if (Bridge.RemoteTarget is null
            && Bridge.IsNoProjectScope
            && Bridge.Selected is { Projectless: true })
        {
            await Bridge.NewProjectlessConversationAsync();
            return;
        }
        if (Bridge.RemoteTarget is not null)
        {
            await Bridge.NewConversationAsync(Bridge.Selected?.Cwd ?? WorkspacePath);
            return;
        }

        var workspace = Bridge.Selected?.Cwd ?? WorkspacePath;
        if (string.IsNullOrWhiteSpace(workspace))
        {
            workspace = Projects.FirstOrDefault(Directory.Exists);
            if (workspace is null)
            {
                await Bridge.NewProjectlessConversationAsync();
                return;
            }
        }
        if (!Directory.Exists(workspace)) return;

        if (!SameWorkspacePath(WorkspacePath, workspace) || !Bridge.CanSendSelectedConversation)
        {
            await SetWorkspaceAsync(workspace);
            if (!SameWorkspacePath(WorkspacePath, workspace)) return;
        }
        await Bridge.NewConversationAsync(workspace);
    }

    /// Rechecks all saved rows so the sidebar and composer react when a folder
    /// is moved or removed while the app is open.
    public bool RefreshProjectAvailability()
    {
        var current = Projects.Where(path => !Directory.Exists(path))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (_unavailableProjectPaths.SetEquals(current)) return false;
        _unavailableProjectPaths.Clear();
        _unavailableProjectPaths.UnionWith(current);
        OnPropertyChanged(nameof(Projects));
        OnPropertyChanged(nameof(ActiveProjectLocationAvailable));
        return true;
    }

    /// Moves the saved project row and its conversation ownership to a folder
    /// selected by the user. The history stays under the same project entry.
    public async Task<bool> RelocateProjectAsync(string missingPath, string selectedPath)
    {
        var oldPath = NormalizeProjectIdentity(missingPath);
        var newPath = NormalizeCodingWorkspace(selectedPath);
        if (oldPath.Length == 0 || newPath.Length == 0) return false;
        if (SameProjectPath(oldPath, newPath))
        {
            SetWorkspace(newPath);
            return true;
        }

        await Bridge.RelocateProjectHistoryAsync(oldPath, newPath);
        var oldEntry = Projects.FirstOrDefault(path => SameProjectPath(path, oldPath));
        var destinationListed = Projects.Any(path => SameProjectPath(path, newPath));
        if (oldEntry is not null)
        {
            var oldIndex = Projects.IndexOf(oldEntry);
            Projects.Remove(oldEntry);
            if (!destinationListed) Projects.Insert(Math.Min(oldIndex, Projects.Count), newPath);
        }
        else if (!destinationListed)
        {
            Projects.Insert(0, newPath);
        }
        PersistProjects();
        SetWorkspace(newPath);
        OnPropertyChanged(nameof(Projects));
        return true;
    }

    /// <summary>
    /// Workspace conversations stay grouped under their project while
    /// projectless and disconnected histories appear in Recent. These helpers
    /// are UI-neutral so WPF and Avalonia share the same project path rules.
    /// </summary>
    // --- Project pinning and chat order, shared by the sidebar and the tray panel ---

    // ponytail: own key; macOS keeps `pinned` inside agent.projectMetadata. Fold
    // into that object if the platforms ever share one settings file.
    private IEnumerable<string> PinnedProjects =>
        (Host.Settings.Get("agent.pinnedProjects")?.AsArray() ?? Array.Empty<JsonValue>())
            .Select(item => item.AsString() ?? "")
            .Where(item => item.Length > 0);

    public bool IsProjectPinned(string path) => PinnedProjects.Any(item => SameProjectPath(item, path));

    public void ToggleProjectPinned(string path)
    {
        var pinned = PinnedProjects.ToList();
        if (pinned.RemoveAll(item => SameProjectPath(item, path)) == 0) pinned.Add(path);
        Host.Settings.Set("agent.pinnedProjects", JsonValue.Array(pinned.Select(JsonValue.String)));
        PersistSettings();
        OnPropertyChanged(nameof(Projects));
    }

    /// Pinned projects first; each half keeps the saved project order.
    public IReadOnlyList<string> OrderedProjects => Projects.OrderByDescending(IsProjectPinned).ToList();

    public string ProjectSidebarGrouping => Host.Settings.Get("agent.projectSidebarGrouping")?.AsString() == "none"
        ? "none"
        : "folder";

    public string ProjectSidebarSort => Host.Settings.Get("agent.projectSidebarSort")?.AsString() == "name"
        ? "name"
        : "recent";

    public IReadOnlyList<string> ProjectSidebarOrder
    {
        get
        {
            var projects = OrderedProjects;
            return ProjectSidebarSort == "name"
                ? projects.OrderByDescending(IsProjectPinned)
                    .ThenBy(ProjectTitle, StringComparer.CurrentCultureIgnoreCase)
                    .ToList()
                : projects;
        }
    }

    public void SetProjectSidebarGrouping(string grouping)
    {
        if (grouping is not ("folder" or "none") || ProjectSidebarGrouping == grouping) return;
        Host.Settings.Set("agent.projectSidebarGrouping", JsonValue.String(grouping));
        PersistSettings();
        OnPropertyChanged(nameof(Projects));
    }

    public void SetProjectSidebarSort(string sort)
    {
        if (sort is not ("recent" or "name") || ProjectSidebarSort == sort) return;
        Host.Settings.Set("agent.projectSidebarSort", JsonValue.String(sort));
        PersistSettings();
        OnPropertyChanged(nameof(Projects));
    }

    public void ResetProjectSidebarOrganization()
    {
        Host.Settings.Set("agent.projectSidebarGrouping", JsonValue.String("folder"));
        Host.Settings.Set("agent.projectSidebarSort", JsonValue.String("recent"));
        PersistSettings();
        OnPropertyChanged(nameof(Projects));
    }

    /// Same setting key and values as macOS. Its "manual" order needs
    /// drag-reorder, which these platforms do not have, so it reads as last update.
    public ConversationSortOrder SortOrder(string? project) =>
        !string.IsNullOrWhiteSpace(project)
        && Host.Settings.Get("agent.projectSortOrders")?[project]?.AsString() == "priority"
            ? ConversationSortOrder.Priority
            : ConversationSortOrder.LastUpdate;

    public void SetSortOrder(string project, ConversationSortOrder order)
    {
        var orders = new Dictionary<string, JsonValue>(StringComparer.Ordinal);
        foreach (var pair in Host.Settings.Get("agent.projectSortOrders")?.AsObject() ?? orders) orders[pair.Key] = pair.Value;
        orders[project] = JsonValue.String(order == ConversationSortOrder.Priority ? "priority" : "lastUpdate");
        Host.Settings.Set("agent.projectSortOrders", JsonValue.Object(orders));
        PersistSettings();
        OnPropertyChanged(nameof(Projects));
    }

    /// A project's chats in the order its sort preference asks for; null is for
    /// lists that aren't scoped to one project's own preference.
    public IEnumerable<Conversation> Ordered(IEnumerable<Conversation> conversations, string? project) =>
        SortOrder(project) == ConversationSortOrder.Priority
            ? conversations.OrderByDescending(item => item.Pinned)
                .ThenBy(item => item.Title, StringComparer.CurrentCultureIgnoreCase)
            : conversations.OrderByDescending(item => item.Pinned)
                .ThenByDescending(SessionProjector.LastActivity);

    /// The project's pin and sort actions as plain rows, so WPF and Avalonia
    /// only have to render them.
    public IReadOnlyList<(string Title, Action Run)> ProjectMenu(string project)
    {
        string Mark(ConversationSortOrder order, string key) => (SortOrder(project) == order ? "✓ " : "") + L(key);
        return new (string, Action)[]
        {
            (L(IsProjectPinned(project) ? "sidebar.unpinProject" : "sidebar.pinProject"), () => ToggleProjectPinned(project)),
            (Mark(ConversationSortOrder.LastUpdate, "sidebar.sortLastUpdate"), () => SetSortOrder(project, ConversationSortOrder.LastUpdate)),
            (Mark(ConversationSortOrder.Priority, "sidebar.sortPriority"), () => SetSortOrder(project, ConversationSortOrder.Priority)),
        };
    }

    public string ProjectTitle(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return "Project";
        try
        {
            var title = new DirectoryInfo(path).Name;
            return string.IsNullOrWhiteSpace(title) ? path : title;
        }
        catch { return path; }
    }

    public void AddProject(string path) => SetWorkspace(path);

    /// <summary>Moves a queued prompt back into the composer; refused while the composer holds a draft.</summary>
    public bool EditQueuedPrompt(string promptId)
    {
        if (SelectedConversationId is not { } conversationId
            || !string.IsNullOrWhiteSpace(Draft)
            || DraftAttachments.Count > 0) return false;
        if (Bridge.RemoveQueuedPrompt(conversationId, promptId) is not { } prompt) return false;

        Draft = prompt.Text;
        foreach (var attachment in prompt.Attachments) DraftAttachments.Add(attachment);
        return true;
    }

    public sealed record GitBarInfo(string Branch, int Added, int Removed);

    /// <summary>Branch and uncommitted +/- line counts for the composer's git bar; null outside a repository.</summary>
    public async Task<GitBarInfo?> ReadGitBarAsync(CancellationToken cancellationToken = default)
    {
        var workspace = WorkspacePath;
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return null;

        var branch = (await GitOutputAsync(workspace, cancellationToken, "branch", "--show-current").ConfigureAwait(false))?.Trim();
        if (branch is null) return null;
        if (branch.Length == 0)
            branch = (await GitOutputAsync(workspace, cancellationToken, "rev-parse", "--short", "HEAD").ConfigureAwait(false))?.Trim() ?? "";

        int added = 0, removed = 0;
        var numstat = await GitOutputAsync(workspace, cancellationToken, "diff", "HEAD", "--numstat").ConfigureAwait(false) ?? "";
        foreach (var line in numstat.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var columns = line.Split('\t');
            if (columns.Length < 2) continue;
            added += int.TryParse(columns[0], out var a) ? a : 0;
            removed += int.TryParse(columns[1], out var r) ? r : 0;
        }
        return new GitBarInfo(branch, added, removed);
    }

    private static async Task<string?> GitOutputAsync(string workspace, CancellationToken cancellationToken, params string[] arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "git",
            WorkingDirectory = workspace,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);
        try
        {
            using var process = new Process { StartInfo = startInfo };
            if (!process.Start()) return null;
            var output = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var error = process.StandardError.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            await error.ConfigureAwait(false);
            return process.ExitCode == 0 ? await output.ConfigureAwait(false) : null;
        }
        catch { return null; }
    }

    public async Task<bool> OpenPullRequestsAsync(CancellationToken cancellationToken = default)
    {
        var url = await ForgeUrlAsync(WorkspacePath, cancellationToken).ConfigureAwait(false);
        if (url is null) return false;

        try
        {
            Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true });
            return true;
        }
        catch { return false; }
    }

    private static async Task<Uri?> ForgeUrlAsync(string? workspace, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return null;

        var startInfo = new ProcessStartInfo
        {
            FileName = "git",
            WorkingDirectory = workspace,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        startInfo.ArgumentList.Add("config");
        startInfo.ArgumentList.Add("--get");
        startInfo.ArgumentList.Add("remote.origin.url");

        try
        {
            using var process = new Process { StartInfo = startInfo };
            if (!process.Start()) return null;
            var output = process.StandardOutput.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            if (process.ExitCode != 0) return null;
            return ForgeUrlFromRemote((await output.ConfigureAwait(false)).Trim());
        }
        catch { return null; }
    }

    private static Uri? ForgeUrlFromRemote(string remote)
    {
        if (string.IsNullOrWhiteSpace(remote)) return null;
        remote = remote.Trim();
        if (remote.EndsWith(".git", StringComparison.OrdinalIgnoreCase))
            remote = remote[..^4];

        string host;
        string path;
        var schemeSeparator = remote.IndexOf("://", StringComparison.Ordinal);
        if (schemeSeparator >= 0)
        {
            var rest = remote[(schemeSeparator + 3)..].TrimEnd('/');
            var slash = rest.IndexOf('/');
            if (slash <= 0 || slash == rest.Length - 1) return null;
            host = rest[..slash];
            path = rest[(slash + 1)..];
            var at = host.IndexOf('@');
            if (at >= 0) host = host[(at + 1)..];
        }
        else
        {
            var at = remote.IndexOf('@');
            var colon = remote.IndexOf(':');
            if (at < 0 || colon <= at + 1 || colon == remote.Length - 1) return null;
            host = remote[(at + 1)..colon];
            path = remote[(colon + 1)..];
        }

        if (host.Length == 0 || path.Length == 0) return null;
        var baseUrl = $"https://{host}/{path}";
        var lowerHost = host.ToLowerInvariant();
        var suffix = lowerHost.Contains("github", StringComparison.Ordinal)
            ? "/pulls"
            : lowerHost.Contains("gitlab", StringComparison.Ordinal)
                ? "/-/merge_requests"
                : lowerHost.Contains("bitbucket", StringComparison.Ordinal)
                    ? "/pull-requests"
                    : "";
        return Uri.TryCreate(baseUrl + suffix, UriKind.Absolute, out var url) ? url : null;
    }

    public void AddDraftAttachments(IEnumerable<string> paths)
    {
        AppendDraftAttachments(PrepareDraftAttachments(paths.ToArray()));
    }

    public async Task AddDraftAttachmentsAsync(IEnumerable<string> paths)
    {
        var requestedPaths = paths.ToArray();
        if (requestedPaths.Length == 0) return;
        var additions = await Task.Run(() => PrepareDraftAttachments(requestedPaths));
        AppendDraftAttachments(additions);
    }

    public async Task<bool> AddDraftImageDataAsync(byte[] imageData, string imageExtension = "png")
    {
        if (imageData.Length == 0) return false;
        var extension = NormalizeDraftImageExtension(imageExtension);
        try
        {
            var path = await Task.Run(() =>
            {
                var directory = Path.Combine(Paths.Runtime, "pasted-images");
                Directory.CreateDirectory(directory);
                var imagePath = Path.Combine(directory, $"{Guid.NewGuid():N}.{extension}");
                File.WriteAllBytes(imagePath, imageData);
                return imagePath;
            });
            await AddDraftAttachmentsAsync([path]);
            return true;
        }
        catch (Exception error)
        {
            Debug.WriteLine($"Unable to save dropped image: {error.Message}");
            return false;
        }
    }

    private static List<ChatAttachment> PrepareDraftAttachments(IEnumerable<string> paths)
    {
        var additions = new List<ChatAttachment>();
        foreach (var path in paths)
        {
            if (ChatAttachment.TryCreate(path, out var attachment)) additions.Add(attachment);
        }
        return additions;
    }

    private void AppendDraftAttachments(IEnumerable<ChatAttachment> additions)
    {
        var pathComparer = OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;
        var knownPaths = new HashSet<string>(DraftAttachments.Select(item => item.FilePath), pathComparer);
        foreach (var attachment in additions)
        {
            if (knownPaths.Add(attachment.FilePath)) DraftAttachments.Add(attachment);
        }
    }

    private static string NormalizeDraftImageExtension(string extension)
    {
        var value = extension.Trim().TrimStart('.').ToLowerInvariant();
        return value is "png" or "jpg" or "jpeg" or "gif" or "webp" or "bmp" or "tif" or "tiff" or "heic" or "heif" or "avif"
            ? value
            : "png";
    }

    public void RemoveDraftAttachment(ChatAttachment attachment) => DraftAttachments.Remove(attachment);

    public void Send(PromptMode mode = PromptMode.Queue)
    {
        if (!Bridge.CanSendSelectedConversation) return;
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
        if (isApproval) IsPlanMode = false;
        _ = SendResolvedAsync(Bridge, text, attachments, mode, isApproval, () =>
        {
            Draft = "";
            DraftAttachments.Clear();
        });
    }

    /// Turns plan mode on when the message explicitly asks for a plan.
    private async Task SendResolvedAsync(
        AgentBridge bridge,
        string text,
        IReadOnlyList<ChatAttachment> attachments,
        PromptMode mode,
        bool isApproval,
        Action onAccepted)
    {
        if (!bridge.CanSendSelectedConversation)
        {
            Draft = text;
            DraftAttachments.Clear();
            foreach (var attachment in attachments) DraftAttachments.Add(attachment);
            return;
        }
        try
        {
            if (isApproval)
                await bridge.SendAsync(text, attachments, mode, planMode: false, onAccepted: onAccepted);
            else
                await bridge.SendWithPlanIntentResolutionAsync(
                    text,
                    attachments,
                    mode,
                    IsPlanMode,
                    bridge.ClassifyPlanIntentAsync,
                    onPlanModeResolved: () => IsPlanMode = true,
                    onAccepted: onAccepted);
        }
        catch (PromptPersistenceException)
        {
            Draft = text;
            DraftAttachments.Clear();
            foreach (var attachment in attachments) DraftAttachments.Add(attachment);
        }
    }

    public void TogglePlanMode() => IsPlanMode = !IsPlanMode;

    /// Rewinds to just before `message`; with `edit` the text goes back to the composer.
    public void RewindTo(ChatMessage message, bool edit)
    {
        if (message.Kind != ChatKind.User || Bridge.RewindBefore(message.Id) is not { } removed) return;
        if (!edit) return;
        Draft = removed.Text;
        DraftAttachments.Clear();
        foreach (var attachment in removed.Attachments) DraftAttachments.Add(attachment);
    }

    /// Shows or hides `message` translated into the UI language (English when it already is).
    public async Task ToggleTranslationAsync(ChatMessage message)
    {
        if (message.HasTranslation) { message.Translation = null; return; }
        if (message.IsTranslating || string.IsNullOrWhiteSpace(message.Text)) return;
        message.IsTranslating = true;
        try
        {
            message.Translation = await Router.TranslateAsync(message.Text, LocalizationService.Current.Culture.EnglishName);
        }
        catch (Exception ex)
        {
            message.Translation = ex.Message;
        }
        finally
        {
            message.IsTranslating = false;
        }
    }

    private System.Diagnostics.Process? _speech;
    private ChatMessage? _speaking;

    /// Reads `message` aloud with the OS voice (SAPI on Windows, speech-dispatcher/espeak-ng on Linux); a second call stops it.
    public void ToggleSpeech(ChatMessage message)
    {
        var wasSpeaking = ReferenceEquals(_speaking, message);
        StopSpeech();
        var text = message.Text.Trim();
        if (wasSpeaking || text.Length == 0) return;
        if (text.Length > 8000) text = text[..8000];
        var context = SynchronizationContext.Current;
        foreach (var info in SpeechCommands(text))
        {
            try
            {
                var process = System.Diagnostics.Process.Start(info);
                if (process is null) continue;
                process.EnableRaisingEvents = true;
                _speech = process;
                _speaking = message;
                message.IsSpeaking = true;
                process.Exited += (_, _) =>
                {
                    void Done() { if (ReferenceEquals(_speech, process)) { _speech = null; _speaking = null; } message.IsSpeaking = false; }
                    if (context is null) Done(); else context.Post(_ => Done(), null);
                };
                return;
            }
            catch (System.ComponentModel.Win32Exception) { }
        }
    }

    private void StopSpeech()
    {
        var process = _speech;
        var message = _speaking;
        _speech = null;
        _speaking = null;
        if (message is not null) message.IsSpeaking = false;
        try { if (process is { HasExited: false }) process.Kill(true); } catch (InvalidOperationException) { }
    }

    private static IEnumerable<System.Diagnostics.ProcessStartInfo> SpeechCommands(string text)
    {
        if (OperatingSystem.IsWindows())
        {
            var info = new System.Diagnostics.ProcessStartInfo("powershell") { CreateNoWindow = true, UseShellExecute = false };
            info.ArgumentList.Add("-NoProfile");
            info.ArgumentList.Add("-Command");
            info.ArgumentList.Add("Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak($env:DOTS_SPEAK)");
            info.Environment["DOTS_SPEAK"] = text;
            yield return info;
            yield break;
        }
        foreach (var (tool, wait) in new[] { ("spd-say", "-w"), ("espeak-ng", "") })
        {
            var info = new System.Diagnostics.ProcessStartInfo(tool) { UseShellExecute = false };
            if (wait.Length > 0) info.ArgumentList.Add(wait);
            info.ArgumentList.Add("--");
            info.ArgumentList.Add(text);
            yield return info;
        }
    }

    public void ApplyPlan()
    {
        if (!Bridge.CanSendSelectedConversation
            || !Router.HasActiveRoute
            || Bridge.Selected?.PendingPlanMessageId is null
            || Bridge.Selected.Running
            || (Bridge.Selected.PlanGateActive && Bridge.Selected.Continuation is not null)) return;
        IsPlanMode = false;
        _ = Bridge.ApplyPlanAsync();
    }

    public void CancelPlan() => _ = Bridge.CancelPlanAsync();

    /// <summary>
    /// Drops the pending plan and reopens the composer in plan mode, so the
    /// user's next message re-plans with their feedback. Mirrors macOS.
    /// </summary>
    public void RevisePlan()
    {
        _ = Bridge.CancelPlanAsync();
        IsPlanMode = true;
    }

    /// <summary>Applies the plan and keeps approving the later plans automatically.</summary>
    public void ApplyPlanAndAutoApprove()
    {
        SetAutoApprovePlans(true);
        ApplyPlan();
    }

    public void Cancel() => _ = Bridge.CancelAsync();

    public void Continue()
    {
        if (Bridge.CanSendSelectedConversation) _ = Bridge.ContinueAsync();
    }

    public void SetSelectedModel(string value)
    {
        Router.SelectedModelID = value;
        Host.Settings.Set("agent.model", JsonValue.String(Router.SelectedModelID));
        // Levels are model-specific; a level the new model rejects must not carry over.
        if (!Router.Efforts(value).Contains(Router.SelectedEffort)) SetEffort("");
        if (Router.FastMode && !Router.SupportsFast(value)) SetFast(false);
        PersistSettings();
        OnPropertyChanged(nameof(SelectedModelID));
    }

    /// Reasoning effort for the selected model. Empty means the provider default.
    public void SetEffort(string value)
    {
        Router.SelectedEffort = value;
        var stored = string.IsNullOrEmpty(value) ? JsonValue.Null : JsonValue.String(value);
        Host.Settings.Set("agent.effort", stored);
        PersistSettings();
    }

    /// Fast (priority) response mode; only meaningful for models that support it.
    public void SetFast(bool value)
    {
        Router.FastMode = value;
        Host.Settings.Set("agent.fast", value ? JsonValue.Bool(true) : JsonValue.Null);
        PersistSettings();
    }

    public void SetUsageMode(AgentUsageMode value)
    {
        Router.UsageMode = value;
        Host.Settings.Set("agent.usageMode", JsonValue.String(value.ToString().ToLowerInvariant()));
        PersistSettings();
        OnPropertyChanged(nameof(UsageMode));
    }

    public AgentUsageMode UsageMode => Router.UsageMode;

    public void SetContextCompactionThresholdPercent(int value)
    {
        Router.ContextCompactionThresholdPercent = Math.Clamp(value, 0, 100);
        Host.Settings.Set(
            "agent.contextCompaction.thresholdPercent",
            JsonValue.Number(Router.ContextCompactionThresholdPercent));
        PersistSettings();
        OnPropertyChanged(nameof(ContextCompactionThresholdPercent));
    }

    public int ContextCompactionThresholdPercent => Router.ContextCompactionThresholdPercent;

    public void SetWorkspaceConflictPolicy(WorkspaceConflictPolicy value)
    {
        if (!SetProperty(ref _workspaceConflictPolicy, value)) return;
        Bridge.SetWorkspaceConflictPolicy(value);
        Host.Settings.Set("agent.workspaceConflictPolicy", JsonValue.String(value.ToString()));
        PersistSettings();
    }

    public void SetConflictWaitSeconds(int value)
    {
        if (!SetProperty(ref _conflictWaitSeconds, Math.Clamp(value, 0, 300))) return;
        Bridge.SetConflictWaitSeconds(_conflictWaitSeconds);
        Host.Settings.Set("agent.conflictWaitSeconds", JsonValue.Number(_conflictWaitSeconds));
        PersistSettings();
    }

    /// <summary>An explicit choice outlives the usage mode's default in both directions.</summary>
    public void SetSubagentsEnabled(bool value)
    {
        Router.SubagentsPreference = value;
        Host.Settings.Set("agent.subagentsEnabled", JsonValue.Bool(value));
        PersistSettings();
        OnPropertyChanged(nameof(SubagentsEnabled));
    }

    public bool SubagentsEnabled => Router.SubagentsEnabled;

    public void SetAutoAccountFailoverAfterLimit(bool value)
    {
        Router.AutoAccountFailoverAfterLimit = value;
        Host.Settings.Set("agent.autoAccountFailoverAfterLimit", JsonValue.Bool(value));
        PersistSettings();
        OnPropertyChanged(nameof(AutoAccountFailoverAfterLimit));
    }

    public bool AutoAccountFailoverAfterLimit => Router.AutoAccountFailoverAfterLimit;

    public void SetResponseStylePreference(AgentResponseStylePreference value)
    {
        Router.ResponseStylePreference = value;
        Host.Settings.Set("agent.responseStyle", JsonValue.String(value.ToString().ToLowerInvariant()));
        PersistSettings();
        OnPropertyChanged(nameof(ResponseStylePreference));
    }

    public AgentResponseStylePreference ResponseStylePreference => Router.ResponseStylePreference;

    private static AgentUsageMode ParseUsageMode(string? value) =>
        Enum.TryParse<AgentUsageMode>(value, ignoreCase: true, out var mode) ? mode : AgentUsageMode.Standard;

    private static AgentResponseStylePreference ParseResponseStylePreference(string? value) =>
        value is null ? AgentResponseStylePreference.Ultra
        : Enum.TryParse<AgentResponseStylePreference>(value, ignoreCase: true, out var preference)
            ? preference
            : AgentResponseStylePreference.Balanced;

    public void SetAppearance(AppearanceKind value)
    {
        Appearance = value;
        Host.Settings.Set("ui.appearance", JsonValue.String(value.ToString().ToLowerInvariant()));
        PersistSettings();
    }

    public void SetAppLanguage(AppLanguage value)
    {
        Localization.SetLanguage(value);
        _ = Localization.LoadLanguagePackAsync();
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

    public void SetSkillSuggestionsEnabled(bool value)
    {
        SkillSuggestionsEnabled = value;
        SkillSuggestions.Enabled = value;
        Host.Settings.Set("skills.suggestions.enabled", JsonValue.Bool(value));
        PersistSettings();
    }

    public void SetSeedProjectRules(bool value)
    {
        SeedProjectRules = value;
        Bridge.SeedProjectRules = value;
        Host.Settings.Set("agent.seedProjectRules", JsonValue.Bool(value));
        PersistSettings();
    }

    public void SetComputerUseEnabled(bool value)
    {
        IsComputerUseEnabled = value;
        Bridge.IsComputerUseEnabled = value;
        Host.Settings.Set("agent.computerUseEnabled", JsonValue.Bool(value));
        PersistSettings();
    }

    public void SetAutoApprovePlans(bool value)
    {
        AutoApprovePlans = value;
        Bridge.AutoApprovePlans = value;
        Host.Settings.Set("agent.autoApprovePlans", JsonValue.Bool(value));
        PersistSettings();
    }

    public void SetConfirmBeforeExit(bool value)
    {
        ConfirmBeforeExit = value;
        Host.Settings.Set("ui.confirmBeforeExit", JsonValue.Bool(value));
        PersistSettings();
    }

    public void SetCloseToTray(bool value)
    {
        CloseToTray = value;
        Host.Settings.Set("ui.closeToTray", JsonValue.Bool(value));
        PersistSettings();
    }

    public void SetAutoUpdate(bool value)
    {
        AutoUpdate = value;
        Host.Settings.Set("updates.auto", JsonValue.Bool(value));
        PersistSettings();
    }

    public UserKeyboardShortcut ShortcutFor(KeyboardShortcutAction action) =>
        _keyboardShortcuts.TryGetValue(action, out var shortcut)
            ? shortcut
            : KeyboardShortcutCatalog.CreateDefaults()[action];

    public bool TryGetShortcutAction(string? key, byte modifiers, out KeyboardShortcutAction action)
    {
        foreach (var candidate in KeyboardShortcutCatalog.Actions)
        {
            if (ShortcutFor(candidate).Matches(key, modifiers))
            {
                action = candidate;
                return true;
            }
        }
        action = default;
        return false;
    }

    public string KeyboardShortcutTitle(KeyboardShortcutAction action) => action switch
    {
        KeyboardShortcutAction.ToggleSidebar => L("settings.shortcuts.sidebar"),
        KeyboardShortcutAction.PullRequests => L("sidebar.pullRequests"),
        KeyboardShortcutAction.Scheduled => L("settings.tasks"),
        KeyboardShortcutAction.Review => L("conversation.review"),
        KeyboardShortcutAction.Terminal => L("conversation.terminal"),
        KeyboardShortcutAction.Browser => L("conversation.browser"),
        KeyboardShortcutAction.Files => L("conversation.files"),
        KeyboardShortcutAction.NewConversation => L("conversation.newChat"),
        _ => action.ToString(),
    };

    public KeyboardShortcutUpdateResult UpdateShortcut(
        KeyboardShortcutAction action,
        UserKeyboardShortcut shortcut)
    {
        foreach (var other in KeyboardShortcutCatalog.Actions)
        {
            if (other != action && ShortcutFor(other) == shortcut)
                return new KeyboardShortcutUpdateResult(KeyboardShortcutUpdateStatus.Conflict, other);
        }

        _keyboardShortcuts = new Dictionary<KeyboardShortcutAction, UserKeyboardShortcut>(_keyboardShortcuts)
        {
            [action] = shortcut,
        };
        Host.Settings.Set(KeyboardShortcutCatalog.SettingsKey(action), JsonValue.String(shortcut.StoredValue));
        PersistSettings();
        OnPropertyChanged(nameof(KeyboardShortcuts));
        return new KeyboardShortcutUpdateResult(KeyboardShortcutUpdateStatus.Saved);
    }

    public void ResetKeyboardShortcuts()
    {
        foreach (var action in KeyboardShortcutCatalog.Actions)
            Host.Settings.Remove(KeyboardShortcutCatalog.SettingsKey(action));
        _keyboardShortcuts = KeyboardShortcutCatalog.CreateDefaults();
        PersistSettings();
        OnPropertyChanged(nameof(KeyboardShortcuts));
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

    public void SetWorkspace(string value, bool addToProjects = true) => _ = SetWorkspaceAsync(value, addToProjects);

    public Task SetWorkspaceAsync(string value, bool addToProjects = true)
    {
        var normalized = NormalizeCodingWorkspace(value);
        if (ActiveSandbox is not null && !_sandboxTransition && !SameWorkspacePath(normalized, ActiveSandbox.Path))
        {
            SandboxNotice = "Leave the active sandbox before changing workspaces.";
            return Task.CompletedTask;
        }
        WorkspacePath = normalized;
        if (addToProjects && !string.IsNullOrWhiteSpace(normalized))
        {
            var existingProject = Projects.FirstOrDefault(path => SameWorkspacePath(path, normalized));
            if (existingProject is null)
            {
                Projects.Insert(0, normalized);
            }
            else
            {
                var existingIndex = Projects.IndexOf(existingProject);
                if (existingIndex > 0)
                {
                    Projects.RemoveAt(existingIndex);
                    Projects.Insert(0, normalized);
                }
            }
        }
        PersistProjects();
        RemoteControl.SetWorkspacePath(normalized);
        Skills.SetWorkspace(string.IsNullOrWhiteSpace(normalized) ? null : normalized);
        SkillSuggestions.SetWorkspace(string.IsNullOrWhiteSpace(normalized) ? null : normalized);
        Host.Settings.Set("agent.workspace", JsonValue.String(normalized));
        PersistSettings();
        Bridge.PrepareWorkspaceSelection(normalized);
        var workspaceLoad = Bridge.StartAsync(normalized);
        OnPropertyChanged(nameof(Projects));
        RefreshProjectAvailability();
        return workspaceLoad;
    }

    public void SelectNoProject() => _ = SelectNoProjectAsync();

    public async Task SelectNoProjectAsync()
    {
        await SetWorkspaceAsync("");
        if (!string.IsNullOrWhiteSpace(WorkspacePath) || Bridge.RemoteTarget is not null) return;
        if (Bridge.Selected is null) await Bridge.NewProjectlessConversationAsync();
    }

    public void RefreshSshHosts()
    {
        SshHosts = RemoteSsh.ReadHosts();
        if (_workLocationAlias is { Length: > 0 } alias
            && !SshHosts.Any(host => host.Alias.Equals(alias, StringComparison.OrdinalIgnoreCase)))
        {
            SshNotice = L("ssh.error.notReachable", alias);
            SetLocalWorkLocation();
        }
    }

    public void AddSshHost(string alias, string hostName, string user, int port, string? identityFile = null)
    {
        RemoteSsh.AddManagedHost(alias.Trim(), hostName.Trim(), user.Trim(), port, identityFile);
        RefreshSshHosts();
    }

    public async Task<SshHost> EnrollSshHostAsync(
        string alias,
        string hostName,
        string user,
        int port,
        string password,
        IReadOnlyList<SshHostKey> scannedKeys,
        bool rememberPassword = false,
        CancellationToken ct = default)
    {
        alias = alias.Trim();
        hostName = hostName.Trim();
        user = user.Trim();
        if (!RemoteSsh.IsValidAlias(alias) || !RemoteSsh.IsValidHostInput(hostName, user, port))
            throw new InvalidOperationException("Enter a valid alias, host name, user name, and port.");
        if (SshHosts.Any(host => host.Alias.Equals(alias, StringComparison.OrdinalIgnoreCase) && !host.ManagedByApp))
            throw new InvalidOperationException($"The SSH alias '{alias}' already exists. Edit its existing Host entry instead.");

        SshEnrollment.TrustHostKeys(alias, hostName, user, port, scannedKeys);
        var publicKey = await SshEnrollment.EnsureKeyPairAsync(ct);
        await SshEnrollment.InstallPublicKeyAsync(hostName, user, port, password, publicKey, ct);
        AddSshHost(alias, hostName, user, port, SshEnrollment.IdentityFileReference);
        var passwordCredential = "ssh.password." + alias;
        if (rememberPassword)
        {
            try { Secrets.Write(passwordCredential, password); } catch { }
        }
        else Secrets.Delete(passwordCredential);

        var probe = await RemoteSsh.ProbeAsync(alias, ct);
        if (probe.ExitCode != 0 || probe.TimedOut)
            throw new InvalidOperationException(probe.CombinedOutput.Length > 0 ? probe.CombinedOutput : L("ssh.error.notReachable", alias));
        return SshHosts.First(host => host.Alias.Equals(alias, StringComparison.OrdinalIgnoreCase));
    }

    public async Task<SshHost> AddSshHostWithoutPasswordAsync(
        string alias,
        string hostName,
        string user,
        int port,
        IReadOnlyList<SshHostKey> scannedKeys,
        CancellationToken ct = default)
    {
        alias = alias.Trim();
        hostName = hostName.Trim();
        user = user.Trim();
        if (!RemoteSsh.IsValidAlias(alias) || !RemoteSsh.IsValidHostInput(hostName, user, port))
            throw new InvalidOperationException("Enter a valid alias, host name, user name, and port.");
        if (SshHosts.Any(host => host.Alias.Equals(alias, StringComparison.OrdinalIgnoreCase) && !host.ManagedByApp))
            throw new InvalidOperationException($"The SSH alias '{alias}' already exists. Edit its existing Host entry instead.");

        SshEnrollment.TrustHostKeys(alias, hostName, user, port, scannedKeys);
        AddSshHost(alias, hostName, user, port);
        var probe = await RemoteSsh.ProbeAsync(alias, ct);
        if (probe.ExitCode != 0 || probe.TimedOut)
            throw new InvalidOperationException(probe.CombinedOutput.Length > 0 ? probe.CombinedOutput : L("ssh.error.notReachable", alias));
        return SshHosts.First(host => host.Alias.Equals(alias, StringComparison.OrdinalIgnoreCase));
    }

    public async Task<SshHost> AddSshHostUsingGeneratedKeyAsync(
        string alias,
        string hostName,
        string user,
        int port,
        IReadOnlyList<SshHostKey> scannedKeys,
        CancellationToken ct = default)
    {
        alias = alias.Trim();
        hostName = hostName.Trim();
        user = user.Trim();
        if (!RemoteSsh.IsValidAlias(alias) || !RemoteSsh.IsValidHostInput(hostName, user, port))
            throw new InvalidOperationException("Enter a valid alias, host name, user name, and port.");
        if (SshHosts.Any(host => host.Alias.Equals(alias, StringComparison.OrdinalIgnoreCase) && !host.ManagedByApp))
            throw new InvalidOperationException($"The SSH alias '{alias}' already exists. Edit its existing Host entry instead.");

        SshEnrollment.TrustHostKeys(alias, hostName, user, port, scannedKeys);
        _ = await SshEnrollment.EnsureKeyPairAsync(ct);
        AddSshHost(alias, hostName, user, port, SshEnrollment.IdentityFileReference);
        var probe = await RemoteSsh.ProbeAsync(alias, ct);
        if (probe.ExitCode != 0 || probe.TimedOut)
            throw new InvalidOperationException(probe.CombinedOutput.Length > 0 ? probe.CombinedOutput : L("ssh.error.notReachable", alias));
        return SshHosts.First(host => host.Alias.Equals(alias, StringComparison.OrdinalIgnoreCase));
    }

    public void RemoveSshHost(string alias)
    {
        if (Bridge.AnyRunBusy) throw new InvalidOperationException(L("ssh.busy"));
        var host = SshHosts.FirstOrDefault(item => item.Alias.Equals(alias, StringComparison.OrdinalIgnoreCase));
        if (host is null) return;
        if (!host.ManagedByApp)
            throw new InvalidOperationException("Edit hand-written SSH hosts in ~/.ssh/config; DotsHarness only removes entries it created.");
        RemoteSsh.RemoveManagedHost(alias);
        Secrets.Delete("ssh.password." + alias);
        if (string.Equals(_workLocationAlias, alias, StringComparison.OrdinalIgnoreCase)) SetLocalWorkLocation();
        RefreshSshHosts();
    }

    public bool SetLocalWorkLocation()
    {
        if (Bridge.AnyRunBusy)
        {
            SshNotice = L("ssh.busy");
            return false;
        }
        _workLocationAlias = null;
        RemoteTarget = null;
        Bridge.SetRemoteTarget(null);
        Host.Settings.Set("agent.workLocation", JsonValue.String("local"));
        PersistSettings();
        SshNotice = null;
        NotifyWorkLocationChanged();
        return true;
    }

    public void TrustSshHostKeys(string alias, IReadOnlyList<SshHostKey> keys)
    {
        var host = SshHosts.FirstOrDefault(item => item.Alias.Equals(alias, StringComparison.OrdinalIgnoreCase))
            ?? throw new InvalidOperationException("The SSH host is no longer configured.");
        RemoteSsh.TrustScannedHostKeys(host, keys);
    }

    public string RemotePathForHost(string alias) =>
        Host.Settings.Get(RemotePathSettingKey(alias))?.AsString() ?? "~";

    /// <summary>Publishes an SSH notice to the Settings and work-location surfaces.</summary>
    public void SetSshNotice(string? notice) => SshNotice = notice;

    /// <summary>Probes a host so the Settings list can show whether it answers.</summary>
    public async Task<string> TestSshHostAsync(string alias, CancellationToken ct = default)
    {
        if (!RemoteSsh.IsAvailable) return L("ssh.error.unavailable");
        try
        {
            var probe = await RemoteSsh.ProbeAsync(alias, ct).ConfigureAwait(false);
            if (probe.ExitCode == 0 && !probe.TimedOut) return L("ssh.connected", alias);
            return probe.CombinedOutput.Length > 0 ? probe.CombinedOutput : L("ssh.error.notReachable", alias);
        }
        catch (Exception error)
        {
            return error.Message;
        }
    }

    public async Task SetRemoteWorkLocationAsync(string alias, string remotePath, CancellationToken ct = default)
    {
        if (ActiveSandbox is not null) throw new InvalidOperationException("Leave the active sandbox before switching to a remote workspace.");
        if (Bridge.AnyRunBusy) throw new InvalidOperationException(L("ssh.busy"));
        if (!RemoteSsh.IsAvailable) throw new InvalidOperationException(L("ssh.error.unavailable"));
        var host = SshHosts.FirstOrDefault(item => item.Alias.Equals(alias, StringComparison.OrdinalIgnoreCase))
            ?? throw new InvalidOperationException(L("ssh.error.notReachable", alias));
        SshNotice = L("ssh.connecting", host.Alias);
        var probe = await RemoteSsh.ProbeAsync(alias, ct);
        if (probe.ExitCode != 0 || probe.TimedOut)
            throw new InvalidOperationException(probe.CombinedOutput.Length > 0 ? probe.CombinedOutput : L("ssh.error.notReachable", alias));
        var resolved = await RemoteSsh.ResolveDirectoryAsync(alias, remotePath, ct);
        _workLocationAlias = alias;
        RemoteTarget = new SshTarget(alias, resolved);
        Bridge.SetRemoteTarget(RemoteTarget);
        Host.Settings.Set("agent.workLocation", JsonValue.String("remote:" + alias));
        Host.Settings.Set(RemotePathSettingKey(alias), JsonValue.String(resolved));
        PersistSettings();
        SshNotice = null;
        NotifyWorkLocationChanged();
    }

    private static string RemotePathSettingKey(string alias) => "agent.ssh.remotePath." + alias;

    private void NotifyWorkLocationChanged()
    {
        OnPropertyChanged(nameof(IsRemoteWorkLocation));
        OnPropertyChanged(nameof(WorkLocationLabel));
        OnPropertyChanged(nameof(TerminalWorkspacePath));
        OnPropertyChanged(nameof(SshHosts));
    }

    /// <summary>
    /// Looks for a lesson this project keeps relearning, worth turning into a
    /// skill. The active project owns the suggestion monitor; no other project's
    /// pending suggestion is exposed to the current conversation UI.
    /// </summary>
    public void ScanSkillSuggestions() =>
        ActiveSkillSuggestions.Scan(WorkspaceLessons.Read(string.IsNullOrWhiteSpace(WorkspacePath) ? null : WorkspacePath, Paths.Root));

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

    /// <summary>
    /// Everything actually sent as the system prompt - core policy, plan rules,
    /// plugin text and skill metadata - broken out by section with sizes.
    /// </summary>
    public string EffectiveSystemPrompt() => Bridge.EffectiveSystemPromptReport(WorkspacePath);

    private void PersistProjects()
    {
        Host.Settings.Set(
            "agent.projects",
            JsonValue.Array(Projects.Select(JsonValue.String)));
    }

    private static IReadOnlyList<string> LoadProjects(InMemorySettingsRegistry settings)
    {
        return (settings.Get("agent.projects")?.AsArray() ?? Array.Empty<JsonValue>())
            .Select(item => NormalizeProjectIdentity(item.AsString()))
            .Where(path => !string.IsNullOrWhiteSpace(path))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private static string NormalizeProjectIdentity(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return "";
        try { return Path.GetFullPath(value.Trim()); }
        catch { return ""; }
    }

    private static bool SameProjectPath(string? left, string? right)
    {
        var normalizedLeft = NormalizeProjectIdentity(left);
        var normalizedRight = NormalizeProjectIdentity(right);
        return normalizedLeft.Length > 0 && normalizedRight.Length > 0
            && string.Equals(
                normalizedLeft.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                normalizedRight.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
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
        // An entry's `isolate: {service: true}` keeps those services private to that
        // row (PluginHost.Mount gives it a child ServiceRealm) on this host plane too.
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

/// Per-project chat sort criteria, chosen from the sidebar or the tray panel.
public enum ConversationSortOrder
{
    LastUpdate,
    Priority,
}
