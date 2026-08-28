// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Collections.ObjectModel;
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
    private string _preferredHost;
    private string _workspacePath;
    private bool _isPlanMode;

    public ObservableCollection<ChatAttachment> DraftAttachments { get; } = new();

    public PluginCatalog Catalog { get; }
    public SkillCatalog Skills { get; }
    public PluginHost Host { get; }
    public SupportPaths Paths { get; }
    public AgentBridge Bridge { get; }
    public RouterController Router { get; }
    public LocalRuntimeController Local { get; }
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
    public string SelectedModelID
    {
        get => Router.SelectedModelID;
        set => SetSelectedModel(value);
    }

    public AppModel(SupportPaths? paths = null, IEnumerable<Func<IHarnessPlugin>>? builtins = null)
    {
        Paths = paths ?? SupportPaths.Default();
        Paths.Ensure();
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
        Router = new RouterController(Paths, Host.ImageAdapters);
        Router.SelectedModelID = settings.Get("agent.model")?.AsString() ?? "";
        Bridge = new AgentBridge(Router, Paths, Skills);
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
        PreferredHost = "native";
        WorkspacePath = settings.Get("agent.workspace")?.AsString()
            ?? Environment.CurrentDirectory;
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
        Localization.PropertyChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(Language));
            OnPropertyChanged(nameof(IsRightToLeft));
        };
        if (migratedFableSetting) PersistSettings();
    }

    public void Start()
    {
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
        Remount();
        _ = Router.RefreshAsync();
        Scheduler.RunsDueTasks = true;
        Scheduler.Start();
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
        Skills.SetWorkspace(value);
        Host.Settings.Set("agent.workspace", JsonValue.String(value));
        PersistSettings();
    }

    public void PersistSettings()
    {
        var snapshot = Host.Settings.Snapshot();
        File.WriteAllText(Paths.Settings, JsonValue.Object(snapshot).ToJson());
    }

    public string AssembledSystemPrompt() => Host.Prompt.AssembledText();

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
