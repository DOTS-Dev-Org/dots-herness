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

/// <summary>Manifest-only plugin used when the user drops plugin.yml without a DLL.</summary>
public sealed class ManifestPlugin : IHarnessPlugin
{
    public static readonly PluginManifest Placeholder = new(
        "dots.manifest-placeholder",
        "Manifest",
        "0.0.0",
        PluginPlane.Session);

    public PluginManifest Manifest => Resolved;
    public PluginManifest Resolved { get; }
    public string? Directory { get; }

    public ManifestPlugin(PluginManifest manifest, string? directory)
    {
        Resolved = manifest;
        Directory = directory;
    }

    public void Apply(IPluginContext ctx)
    {
        var spec = Resolved.PromptSection;
        if (spec is null) return;
        string text;
        if (!string.IsNullOrEmpty(spec.Text))
        {
            text = spec.Text;
        }
        else if (!string.IsNullOrEmpty(spec.File) && Directory is not null)
        {
            var path = Path.Combine(Directory, spec.File);
            text = System.IO.File.Exists(path) ? System.IO.File.ReadAllText(path) : "";
        }
        else
        {
            text = "";
        }
        if (string.IsNullOrWhiteSpace(text)) return;
        ctx.Prompt.Section(spec.Name, spec.Order, text);
    }
}
