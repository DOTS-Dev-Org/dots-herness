// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using HarnessPluginKit;

namespace PluginRuntime;

public sealed class LivePluginContext : IPluginContext
{
    private readonly ServiceRealm _services;
    private readonly List<Action> _disposers = new();

    public string RowId { get; }
    public string PluginId { get; }
    public string? PluginDirectory { get; }
    public PluginPlane Plane { get; }
    public PluginTrust Trust { get; }
    public IReadOnlyDictionary<string, JsonValue> Config { get; }
    public IToolRegistry Tools { get; }
    public IPromptRegistry Prompt { get; }
    public ISlotRegistry Slots { get; }
    public ISettingsRegistry Settings { get; }
    public IEventBus Events { get; }

    public LivePluginContext(
        string rowId,
        string pluginId,
        string? pluginDirectory,
        PluginPlane plane,
        PluginTrust trust,
        IReadOnlyDictionary<string, JsonValue> config,
        ServiceRealm services,
        IToolRegistry tools,
        IPromptRegistry prompt,
        ISlotRegistry slots,
        ISettingsRegistry settings,
        IEventBus events)
    {
        RowId = rowId;
        PluginId = pluginId;
        PluginDirectory = pluginDirectory;
        Plane = plane;
        Trust = trust;
        Config = config;
        _services = services;
        Tools = tools;
        Prompt = prompt;
        Slots = slots;
        Settings = settings;
        Events = events;
    }

    public object? Get(string name) => _services.Get(name);

    public object Require(string name) =>
        _services.Get(name) ?? throw PluginException.MissingService(name);

    public void Provide(string name, object value)
    {
        _services.Provide(name, value);
        Effect(() => _services.Retract(name));
    }

    public void Effect(Action undo) => _disposers.Add(undo);

    public Action On(string @event, Action<object?> handler)
    {
        var stop = Events.On(@event, handler);
        Effect(stop);
        return stop;
    }

    public void Dispose()
    {
        for (var i = _disposers.Count - 1; i >= 0; i--)
        {
            try { _disposers[i](); } catch { /* undo must not throw out of unmount */ }
        }
        _disposers.Clear();
        (_services.Get("provider.imageAdapters") as ProviderImageAdapterRegistry)?.UnregisterOwner(RowId);
        if (Prompt is InMemoryPromptRegistry prompt) prompt.RetractOwner(RowId);
        if (Tools is InMemoryToolRegistry tools) tools.RetractOwner(RowId);
        if (Slots is InMemorySlotRegistry slots) slots.RetractOwner(RowId);
    }
}

public sealed class ServiceRealm
{
    private readonly Dictionary<string, object> _values = new(StringComparer.Ordinal);
    private readonly ServiceRealm? _parent;

    public ServiceRealm(ServiceRealm? parent = null, IReadOnlyDictionary<string, object>? seed = null)
    {
        _parent = parent;
        if (seed is null) return;
        foreach (var (key, value) in seed) _values[key] = value;
    }

    public object? Get(string name) =>
        _values.TryGetValue(name, out var value) ? value : _parent?.Get(name);

    public void Provide(string name, object value) => _values[name] = value;

    public void Retract(string name) => _values.Remove(name);

    public IReadOnlyList<string> PublishedNames => _values.Keys.ToList();
}

public sealed record MountedFiber(string Id, string PluginId, string Status, IReadOnlyDictionary<string, bool> Isolate);

public sealed class PluginHost : ObservableObject
{
    private readonly ServiceRealm _root;
    private readonly Dictionary<string, LivePluginContext> _contexts = new(StringComparer.Ordinal);
    private readonly PluginCatalog _catalog;
    private IReadOnlyList<MountedFiber> _fibers = Array.Empty<MountedFiber>();
    private IReadOnlyList<MountIssue> _issues = Array.Empty<MountIssue>();

    public InMemoryToolRegistry Tools { get; }
    public InMemoryPromptRegistry Prompt { get; }
    public InMemorySlotRegistry Slots { get; }
    public InMemorySettingsRegistry Settings { get; }
    public InMemoryEventBus Events { get; }
    public ProviderImageAdapterRegistry ImageAdapters { get; }

    /// <summary>Read-only native app data exposed to plugins via <c>harness.host(topic)</c>.</summary>
    public HostDataRegistry HostData { get; }

    public T? GetService<T>(string name) where T : class => _root.Get(name) as T;

    public void ProvideService(string name, object value) => _root.Provide(name, value);

    public IReadOnlyList<MountedFiber> Fibers
    {
        get => _fibers;
        private set => SetProperty(ref _fibers, value);
    }

    public IReadOnlyList<MountIssue> Issues
    {
        get => _issues;
        private set => SetProperty(ref _issues, value);
    }

    public PluginHost(PluginCatalog catalog, InMemorySettingsRegistry? settings = null)
    {
        _catalog = catalog;
        Tools = new InMemoryToolRegistry();
        Prompt = new InMemoryPromptRegistry();
        Slots = new InMemorySlotRegistry();
        Settings = settings ?? new InMemorySettingsRegistry();
        Events = new InMemoryEventBus();
        ImageAdapters = new ProviderImageAdapterRegistry();
        HostData = new HostDataRegistry();
        _root = new ServiceRealm(seed: new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["tools"] = Tools,
            ["prompt"] = Prompt,
            ["slots"] = Slots,
            ["settings"] = Settings,
            ["events"] = Events,
            ["provider.imageAdapters"] = ImageAdapters,
            ["host.data"] = HostData,
        });
    }

    public void UnmountAll()
    {
        foreach (var context in _contexts.Values) context.Dispose();
        _contexts.Clear();
        Fibers = Array.Empty<MountedFiber>();
        Issues = Array.Empty<MountIssue>();
    }

    public IReadOnlyList<MountIssue> Mount(CompositionDocument document)
    {
        UnmountAll();
        var nextIssues = new List<MountIssue>();
        var nextFibers = new List<MountedFiber>();
        var enabled = document.Entries.Where(e => !e.Disabled);

        foreach (var entry in enabled)
        {
            try
            {
                var resolved = _catalog.Resolve(entry.Plugin);
                if (!resolved.Manifest.AbiCompatible)
                {
                    throw PluginException.IncompatibleAbi(resolved.Manifest.Abi);
                }
                if (resolved.Kind == PluginKind.Dylib && resolved.Trust == PluginTrust.Untrusted)
                {
                    throw PluginException.UntrustedLibrary(resolved.Manifest.Id);
                }
                var plugin = resolved.Make();
                var isolate = entry.Isolate;
                var realm = document.Plane == PluginPlane.Session && isolate.Count > 0
                    ? new ServiceRealm(_root)
                    : _root;
                foreach (var name in resolved.Manifest.Inject)
                {
                    if (realm.Get(name) is null) throw PluginException.MissingService(name);
                }
                var publishedBefore = _root.PublishedNames.ToHashSet(StringComparer.Ordinal);
                var context = new LivePluginContext(
                    entry.Id,
                    resolved.Manifest.Id,
                    resolved.PluginDirectory,
                    document.Plane,
                    resolved.Trust,
                    entry.Config,
                    realm,
                    Tools,
                    Prompt,
                    Slots,
                    Settings,
                    Events);
                try
                {
                    FiberLocal.WithOwner(entry.Id, () => plugin.Apply(context));
                    if (document.Plane == PluginPlane.Session)
                    {
                        var published = _root.PublishedNames.Where(n => !publishedBefore.Contains(n)).ToList();
                        if (isolate.Count == 0 && published.Count > 0)
                        {
                            throw PluginException.GlobalService(string.Join(", ", published.OrderBy(x => x)));
                        }
                    }
                    _contexts[entry.Id] = context;
                    nextFibers.Add(new MountedFiber(entry.Id, resolved.Manifest.Id, "active", isolate));
                }
                catch
                {
                    context.Dispose();
                    throw;
                }
            }
            catch (Exception ex)
            {
                nextIssues.Add(new MountIssue(entry.Id, ex.Message));
            }
        }

        if (nextIssues.Count > 0)
        {
            UnmountAll();
            Issues = nextIssues;
            return nextIssues;
        }

        Fibers = nextFibers;
        Issues = Array.Empty<MountIssue>();
        Events.Emit("plugins/mounted", nextFibers.Select(f => f.Id).ToList());
        return Array.Empty<MountIssue>();
    }
}
