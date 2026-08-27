// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using HarnessPluginKit;

namespace PluginRuntime;

public static class FiberLocal
{
    private static readonly AsyncLocal<string> OwnerSlot = new();
    public static string Owner
    {
        get => string.IsNullOrEmpty(OwnerSlot.Value) ? "host" : OwnerSlot.Value;
        set => OwnerSlot.Value = value;
    }

    public static T WithOwner<T>(string owner, Func<T> body)
    {
        var previous = OwnerSlot.Value;
        OwnerSlot.Value = owner;
        try { return body(); }
        finally { OwnerSlot.Value = previous; }
    }

    public static void WithOwner(string owner, Action body)
    {
        var previous = OwnerSlot.Value;
        OwnerSlot.Value = owner;
        try { body(); }
        finally { OwnerSlot.Value = previous; }
    }
}

public sealed class InMemoryPromptRegistry : IPromptRegistry
{
    private readonly List<PromptSection> _items = new();

    public void RetractOwner(string owner) => _items.RemoveAll(i => i.Owner == owner);

    public Action Section(string name, int order, string text)
    {
        var owner = FiberLocal.Owner;
        _items.RemoveAll(i => i.Name == name && i.Owner == owner);
        _items.Add(new PromptSection(name, order, text, owner));
        return () => _items.RemoveAll(i => i.Name == name && i.Owner == owner);
    }

    public string AssembledText() =>
        string.Join("\n\n", _items.OrderBy(i => i.Order).Select(i => i.Text));

    public IReadOnlyList<PromptSection> Sections() =>
        _items.OrderBy(i => i.Order).ToList();
}

public sealed class InMemoryToolRegistry : IToolRegistry
{
    private sealed record Stored(RegisteredTool Meta, Func<IReadOnlyDictionary<string, string>, Task<string>> Execute);

    private readonly Dictionary<string, Stored> _items = new(StringComparer.Ordinal);

    public void RetractOwner(string owner)
    {
        foreach (var key in _items.Where(kv => kv.Value.Meta.Owner == owner).Select(kv => kv.Key).ToList())
        {
            _items.Remove(key);
        }
    }

    public Action Register(
        string name,
        string description,
        IReadOnlyList<ToolParameter> parameters,
        Func<IReadOnlyDictionary<string, string>, Task<string>> execute)
    {
        var owner = FiberLocal.Owner;
        _items[name] = new Stored(new RegisteredTool(name, description, parameters, owner), execute);
        return () =>
        {
            if (_items.TryGetValue(name, out var stored) && stored.Meta.Owner == owner)
            {
                _items.Remove(name);
            }
        };
    }

    public IReadOnlyList<RegisteredTool> Tools() =>
        _items.Values.Select(v => v.Meta).OrderBy(t => t.Name).ToList();

    public Task<string> CallAsync(string name, IReadOnlyDictionary<string, string> arguments)
    {
        if (!_items.TryGetValue(name, out var stored))
        {
            throw PluginException.ApplyFailed($"unknown tool {name}");
        }
        return stored.Execute(arguments);
    }
}

public sealed class InMemorySlotRegistry : ISlotRegistry, INotifyPropertyChanged
{
    private readonly List<SlotRegistration> _items = new();

    public event PropertyChangedEventHandler? PropertyChanged;

    public void RetractOwner(string owner)
    {
        var removed = _items.RemoveAll(i => i.Owner == owner);
        if (removed > 0) OnChanged();
    }

    public Action Inject(string slot, string id, int order, string label, Func<object> viewFactory)
    {
        var owner = FiberLocal.Owner;
        _items.RemoveAll(i => i.Slot == slot && i.Id == id && i.Owner == owner);
        _items.Add(new SlotRegistration(id, slot, order, label, owner, viewFactory));
        OnChanged();
        return () =>
        {
            if (_items.RemoveAll(i => i.Slot == slot && i.Id == id && i.Owner == owner) > 0)
            {
                OnChanged();
            }
        };
    }

    public IReadOnlyList<SlotRegistration> Occupants(string slot) =>
        _items.Where(i => i.Slot == slot).OrderBy(i => i.Order).ToList();

    public IReadOnlyList<SlotRegistration> All() =>
        _items.OrderBy(i => i.Slot).ThenBy(i => i.Order).ThenBy(i => i.Id).ToList();

    private void OnChanged() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(All)));
}

public sealed class InMemorySettingsRegistry : ISettingsRegistry
{
    private readonly Dictionary<string, JsonValue> _values;
    private readonly Action<IReadOnlyDictionary<string, JsonValue>>? _persist;

    public InMemorySettingsRegistry(
        IReadOnlyDictionary<string, JsonValue>? values = null,
        Action<IReadOnlyDictionary<string, JsonValue>>? persist = null)
    {
        _values = values is null
            ? new Dictionary<string, JsonValue>(StringComparer.Ordinal)
            : new Dictionary<string, JsonValue>(values, StringComparer.Ordinal);
        _persist = persist;
    }

    public JsonValue? Get(string key) => _values.TryGetValue(key, out var value) ? value : null;

    public void Set(string key, JsonValue value)
    {
        _values[key] = value;
        _persist?.Invoke(_values);
    }

    public IReadOnlyDictionary<string, JsonValue> Snapshot() =>
        new ReadOnlyDictionary<string, JsonValue>(new Dictionary<string, JsonValue>(_values, StringComparer.Ordinal));
}

public sealed class InMemoryEventBus : IEventBus
{
    private readonly Dictionary<string, Dictionary<Guid, Action<object?>>> _handlers = new(StringComparer.Ordinal);

    public Action On(string name, Action<object?> handler)
    {
        var token = Guid.NewGuid();
        if (!_handlers.TryGetValue(name, out var bucket))
        {
            bucket = new Dictionary<Guid, Action<object?>>();
            _handlers[name] = bucket;
        }
        bucket[token] = handler;
        return () =>
        {
            if (_handlers.TryGetValue(name, out var existing))
            {
                existing.Remove(token);
            }
        };
    }

    public void Emit(string name, object? payload)
    {
        if (!_handlers.TryGetValue(name, out var bucket)) return;
        foreach (var handler in bucket.Values.ToList()) handler(payload);
    }
}

public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool SetProperty<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }

    protected void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
