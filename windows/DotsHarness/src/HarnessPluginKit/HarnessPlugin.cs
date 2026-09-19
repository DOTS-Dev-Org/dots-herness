// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

namespace HarnessPluginKit;

/// <summary>Live host handle. Never serialize this object.</summary>
public interface IPluginContext
{
    string RowId { get; }
    string PluginId { get; }
    string? PluginDirectory { get; }
    PluginPlane Plane { get; }
    PluginTrust Trust { get; }
    IReadOnlyDictionary<string, JsonValue> Config { get; }

    object? Get(string name);
    object Require(string name);
    void Provide(string name, object value);

    void Effect(Action undo);
    Action On(string @event, Action<object?> handler);

    IToolRegistry Tools { get; }
    IPromptRegistry Prompt { get; }
    ISlotRegistry Slots { get; }
    ISettingsRegistry Settings { get; }
    IEventBus Events { get; }
}

public interface IHarnessPlugin
{
    PluginManifest Manifest { get; }
    void Apply(IPluginContext ctx);
}

/// <summary>Bundled plugins implement this so the catalog can construct them.</summary>
public interface IDefaultPlugin : IHarnessPlugin
{
}
