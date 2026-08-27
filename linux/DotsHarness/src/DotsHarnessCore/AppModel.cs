// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

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

    public PluginCatalog Catalog { get; }
    public PluginHost Host { get; }
    public SupportPaths Paths { get; }
    public AgentBridge Bridge { get; }
    public RouterController Router { get; }
    public LocalRuntimeController Local { get; }
    public HarnessScheduler Scheduler { get; }

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

    public AppModel(SupportPaths? paths = null, IEnumerable<Func<IHarnessPlugin>>? builtins = null)
    {
        Paths = paths ?? SupportPaths.Default();
        Paths.Ensure();
        Catalog = new PluginCatalog(Paths);
        if (builtins is not null)
        {
            foreach (var builtin in builtins) Catalog.RegisterBuiltin(builtin);
        }
        var settings = LoadSettings(Paths.Settings);
        Host = new PluginHost(Catalog, settings);
        Router = new RouterController(Paths);
        Bridge = new AgentBridge(Router, Paths);
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
        var document = CompositionLoader.LoadHost(Paths, Catalog);
        var issues = Host.Mount(document);
        if (issues.Count > 0)
        {
            Bridge.Status = string.Join(" · ", issues.Select(i => $"{i.RowId}: {i.Message}"));
        }
        OnPropertyChanged(nameof(Catalog));
        OnPropertyChanged(nameof(Host));
    }

    public void NewConversation() => _ = Bridge.NewConversationAsync(WorkspacePath);

    public void Send(PromptMode mode = PromptMode.Queue)
    {
        var text = Draft.Trim();
        if (string.IsNullOrEmpty(text)) return;
        Draft = "";
        _ = Bridge.SendAsync(text, mode);
    }

    public void Cancel() => _ = Bridge.CancelAsync();

    public void SetAppearance(AppearanceKind value)
    {
        Appearance = value;
        Host.Settings.Set("ui.appearance", JsonValue.String(value.ToString().ToLowerInvariant()));
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
    public static CompositionDocument BundledHost() => new(PluginPlane.Host, new[]
    {
        new CompositionEntry("fable-thinking", "dots.fable-thinking"),
    });

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
