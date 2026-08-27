// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Text.Json;
using System.Text.Json.Serialization;
using HarnessPluginKit;

namespace PluginRuntime;

public enum PluginKind
{
    Builtin,
    Manifest,
    Dylib,
}

public sealed record CatalogEntry(
    PluginManifest Manifest,
    PluginKind Kind,
    PluginTrust Trust,
    bool Enabled = true,
    string? Broken = null,
    string? Url = null)
{
    public string Id => Manifest.Id;
}

public sealed record ResolvedPlugin(
    PluginManifest Manifest,
    PluginKind Kind,
    PluginTrust Trust,
    Func<IHarnessPlugin> Make);

public sealed record SupportPaths(
    string Root,
    string Plugins,
    string Presets,
    string Settings,
    string HostPatch,
    string Trust,
    string Models,
    string Runtime)
{
    public static SupportPaths Default()
    {
        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(baseDir))
        {
            baseDir = Path.GetTempPath();
        }
        var root = Path.Combine(baseDir, "DotsHarness");
        return new SupportPaths(
            root,
            Path.Combine(root, "plugins"),
            Path.Combine(root, "presets"),
            Path.Combine(root, "settings.json"),
            Path.Combine(root, "host.patch.yml"),
            Path.Combine(root, "trust.json"),
            Path.Combine(root, "models"),
            Path.Combine(root, "runtime"));
    }

    public void Ensure()
    {
        Directory.CreateDirectory(Plugins);
        Directory.CreateDirectory(Presets);
        Directory.CreateDirectory(Models);
        Directory.CreateDirectory(Runtime);
    }
}

public sealed class PluginCatalog : ObservableObject
{
    private readonly Dictionary<string, Func<IHarnessPlugin>> _builtins = new(StringComparer.Ordinal);
    private readonly Dictionary<string, PluginManifest> _builtinManifests = new(StringComparer.Ordinal);
    private readonly Dictionary<string, PluginTrust> _trustOverrides = new(StringComparer.Ordinal);
    private readonly HashSet<string> _disabled = new(StringComparer.Ordinal);
    private IReadOnlyList<CatalogEntry> _entries = Array.Empty<CatalogEntry>();

    public SupportPaths Paths { get; }

    public IReadOnlyList<CatalogEntry> Entries
    {
        get => _entries;
        private set => SetProperty(ref _entries, value);
    }

    public PluginCatalog(SupportPaths? paths = null)
    {
        Paths = paths ?? SupportPaths.Default();
        Paths.Ensure();
        LoadTrust();
    }

    public void RegisterBuiltin(Func<IHarnessPlugin> factory)
    {
        var plugin = factory();
        var manifest = plugin.Manifest;
        _builtinManifests[manifest.Id] = manifest;
        _builtins[manifest.Id] = factory;
        Refresh();
    }

    public void RegisterBuiltin<T>() where T : IDefaultPlugin, new() => RegisterBuiltin(() => new T());

    public void Refresh()
    {
        var next = new List<CatalogEntry>();
        foreach (var (id, manifest) in _builtinManifests.OrderBy(kv => kv.Key, StringComparer.Ordinal))
        {
            next.Add(new CatalogEntry(manifest, PluginKind.Builtin, PluginTrust.System, !_disabled.Contains(id)));
        }

        if (Directory.Exists(Paths.Plugins))
        {
            foreach (var folder in Directory.GetDirectories(Paths.Plugins))
            {
                var yaml = Path.Combine(folder, "plugin.yml");
                if (!File.Exists(yaml)) continue;
                try
                {
                    var manifest = MiniYaml.DecodeManifest(File.ReadAllText(yaml));
                    var kind = manifest.Library is null ? PluginKind.Manifest : PluginKind.Dylib;
                    var trust = _trustOverrides.TryGetValue(manifest.Id, out var t) ? t : PluginTrust.Untrusted;
                    next.Add(new CatalogEntry(manifest, kind, trust, !_disabled.Contains(manifest.Id), Url: folder));
                }
                catch (Exception ex)
                {
                    var name = Path.GetFileName(folder);
                    next.Add(new CatalogEntry(
                        new PluginManifest(name, name, "0.0.0", PluginPlane.Session),
                        PluginKind.Manifest,
                        PluginTrust.Untrusted,
                        Enabled: false,
                        Broken: ex.Message,
                        Url: folder));
                }
            }
        }

        Entries = next;
    }

    public void SetTrust(string id, PluginTrust trust)
    {
        if (_builtinManifests.ContainsKey(id)) return;
        _trustOverrides[id] = trust;
        PersistTrust();
        Refresh();
    }

    public void SetEnabled(string id, bool isEnabled)
    {
        if (isEnabled) _disabled.Remove(id);
        else _disabled.Add(id);
        PersistTrust();
        Refresh();
    }

    public ResolvedPlugin Resolve(string id)
    {
        if (_builtins.TryGetValue(id, out var factory) && _builtinManifests.TryGetValue(id, out var builtin))
        {
            return new ResolvedPlugin(builtin, PluginKind.Builtin, PluginTrust.System, factory);
        }

        var entry = Entries.FirstOrDefault(e => e.Manifest.Id == id)
            ?? throw PluginException.UnknownPlugin(id);
        if (entry.Broken is { } broken) throw PluginException.InvalidManifest(broken);

        return entry.Kind switch
        {
            PluginKind.Builtin => throw PluginException.UnknownPlugin(id),
            PluginKind.Manifest => new ResolvedPlugin(entry.Manifest, PluginKind.Manifest, entry.Trust,
                () => new ManifestPlugin(entry.Manifest, entry.Url)),
            PluginKind.Dylib => ResolveLibrary(entry),
            _ => throw PluginException.UnknownPlugin(id),
        };
    }

    private static ResolvedPlugin ResolveLibrary(CatalogEntry entry)
    {
        if (entry.Url is null || entry.Manifest.Library is null)
        {
            throw PluginException.InvalidManifest("missing library");
        }
        var path = Path.Combine(entry.Url, entry.Manifest.Library);
        return new ResolvedPlugin(entry.Manifest, PluginKind.Dylib, entry.Trust, () => PluginLibrary.Load(path));
    }

    private void LoadTrust()
    {
        if (!File.Exists(Paths.Trust)) return;
        try
        {
            var file = JsonSerializer.Deserialize<TrustFile>(File.ReadAllText(Paths.Trust), TrustJson.Options);
            if (file is null) return;
            _trustOverrides.Clear();
            foreach (var (key, value) in file.Trust)
            {
                _trustOverrides[key] = value;
            }
            _disabled.Clear();
            foreach (var id in file.Disabled) _disabled.Add(id);
        }
        catch
        {
            // ignore corrupt trust file
        }
    }

    private void PersistTrust()
    {
        var file = new TrustFile(
            new Dictionary<string, PluginTrust>(_trustOverrides, StringComparer.Ordinal),
            _disabled.OrderBy(x => x, StringComparer.Ordinal).ToList());
        File.WriteAllText(Paths.Trust, JsonSerializer.Serialize(file, TrustJson.Options));
    }

    private sealed record TrustFile(Dictionary<string, PluginTrust> Trust, List<string> Disabled);

    private static class TrustJson
    {
        public static readonly JsonSerializerOptions Options = new()
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
            WriteIndented = true,
        };
    }
}
