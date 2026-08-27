// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

namespace HarnessPluginKit;

public sealed record CompositionEntry(
    string Id,
    string Plugin,
    bool Disabled = false,
    IReadOnlyDictionary<string, bool>? Isolate = null,
    IReadOnlyDictionary<string, JsonValue>? Config = null)
{
    public IReadOnlyDictionary<string, bool> Isolate { get; init; } =
        Isolate ?? new Dictionary<string, bool>(StringComparer.Ordinal);

    public IReadOnlyDictionary<string, JsonValue> Config { get; init; } =
        Config ?? new Dictionary<string, JsonValue>(StringComparer.Ordinal);

    public CompositionEntry WithDisabled(bool disabled) => this with { Disabled = disabled };

    public CompositionEntry WithMergedConfig(IReadOnlyDictionary<string, JsonValue> incoming) =>
        this with { Config = Config.MergeFrom(incoming) };
}

public sealed record CompositionDocument(PluginPlane Plane, IReadOnlyList<CompositionEntry> Entries)
{
    public CompositionDocument WithEntries(IReadOnlyList<CompositionEntry> entries) => this with { Entries = entries };
}

public abstract record CompositionPatch
{
    public sealed record Insert(IReadOnlyList<CompositionEntry> Entries) : CompositionPatch;
    public sealed record Disable(string Id) : CompositionPatch;
    public sealed record Enable(string Id) : CompositionPatch;
    public sealed record MergeConfig(string Id, IReadOnlyDictionary<string, JsonValue> Config) : CompositionPatch;

    public static CompositionDocument Apply(IReadOnlyList<CompositionPatch> patches, CompositionDocument document)
    {
        var entries = document.Entries.ToList();
        foreach (var patch in patches)
        {
            switch (patch)
            {
                case Insert insert:
                    foreach (var entry in insert.Entries)
                    {
                        var index = entries.FindIndex(e => e.Id == entry.Id);
                        if (index >= 0) entries[index] = entry;
                        else entries.Add(entry);
                    }
                    break;
                case Disable disable:
                    Replace(entries, disable.Id, e => e.WithDisabled(true));
                    break;
                case Enable enable:
                    Replace(entries, enable.Id, e => e.WithDisabled(false));
                    break;
                case MergeConfig merge:
                    Replace(entries, merge.Id, e => e.WithMergedConfig(merge.Config));
                    break;
            }
        }
        return document.WithEntries(entries);
    }

    private static void Replace(List<CompositionEntry> entries, string id, Func<CompositionEntry, CompositionEntry> map)
    {
        var index = entries.FindIndex(e => e.Id == id);
        if (index >= 0) entries[index] = map(entries[index]);
    }
}

public sealed record MountIssue(string RowId, string Message)
{
    public string Id => RowId + ":" + Message;
}

public sealed class PluginException : Exception
{
    public PluginErrorKind Kind { get; }

    public PluginException(PluginErrorKind kind, string message) : base(message)
    {
        Kind = kind;
    }

    public static PluginException MissingService(string name) =>
        new(PluginErrorKind.MissingService, $"waiting for {name}");

    public static PluginException UnknownPlugin(string id) =>
        new(PluginErrorKind.UnknownPlugin, $"Cannot find plugin {id}");

    public static PluginException IncompatibleAbi(string abi) =>
        new(PluginErrorKind.IncompatibleAbi, $"incompatible ABI {abi}");

    public static PluginException UntrustedLibrary(string id) =>
        new(PluginErrorKind.UntrustedLibrary, $"untrusted dylib {id}");

    public static PluginException ApplyFailed(string message) =>
        new(PluginErrorKind.ApplyFailed, message);

    public static PluginException GlobalService(string name) =>
        new(PluginErrorKind.GlobalService,
            $"row published process-global service [{name}]; a session service must sit behind an isolate realm or move to the host composition");

    public static PluginException SlotCollision(string message) =>
        new(PluginErrorKind.SlotCollision, message);

    public static PluginException InvalidManifest(string message) =>
        new(PluginErrorKind.InvalidManifest, message);

    public static PluginException InvalidComposition(string message) =>
        new(PluginErrorKind.InvalidComposition, message);
}

public enum PluginErrorKind
{
    MissingService,
    UnknownPlugin,
    IncompatibleAbi,
    UntrustedLibrary,
    ApplyFailed,
    GlobalService,
    SlotCollision,
    InvalidManifest,
    InvalidComposition,
}
