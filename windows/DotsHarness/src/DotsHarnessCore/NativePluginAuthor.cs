// Copyright (c) 2026 DOTS
// Workspace-local native plugin drafts. These files are never loaded by the runtime.

using System.Text.Json;
using HarnessPluginKit;
using PluginRuntime;

namespace DotsHarnessCore;

public sealed class NativePluginAuthor(PluginCatalog catalog) : IDefaultPlugin
{
    private const int MaximumDraftFiles = 256;
    private const int MaximumDraftBytes = 2_000_000;
    private string Drafts => Path.Combine(catalog.Paths.Root, "plugin-drafts");

    public PluginManifest Manifest { get; } = new(
        "dots.plugin-author",
        "Plugin Author",
        "2.0.0",
        PluginPlane.Host,
        Inject: ["prompt", "tools"],
        Description: "Create and validate native Dots Harness plugin drafts.");

    public void Apply(IPluginContext ctx)
    {
        Directory.CreateDirectory(Drafts);
        ctx.Prompt.Section("plugin-author", 60,
            "Create native plugin source drafts with plugin.schema and plugin.save. Drafts live outside the runtime catalog and cannot be loaded. Validate locally, then build and sign through Marketplace CI; installation still requires the existing signature verification and explicit trust flow.");

        ctx.Tools.Register("plugin.schema", "Return the native plugin source package contract.", [], _ => Task.FromResult(Schema));
        ctx.Tools.Register("plugin.save", "Save a text-only native plugin source draft outside the runtime plugin catalog.",
        [
            new("id", "string", "Reverse-DNS plugin id, for example com.you.thing."),
            new("files", "string", "JSON object from safe relative paths to text. Must include plugin.yml and plugin.ir.json."),
        ], SaveAsync);
        ctx.Tools.Register("plugin.validate", "Validate a local plugin source draft without loading executable code.",
            [new("id", "string", "Plugin id.")], args => Task.FromResult(Validate(args.GetValueOrDefault("id") ?? "")));
        ctx.Tools.Register("plugin.list", "List local native source drafts. Drafts are not installed or loadable.", [], _ => Task.FromResult(ListDrafts()));
        ctx.Tools.Register("plugin.remove", "Delete a local native source draft by id.",
            [new("id", "string", "Plugin id.")], args => Task.FromResult(Remove(args.GetValueOrDefault("id") ?? "")));
    }

    private Task<string> SaveAsync(IReadOnlyDictionary<string, string> args)
    {
        var id = args.GetValueOrDefault("id")?.Trim() ?? "";
        if (!IsSafeId(id)) return Task.FromResult($"Not saved: unsafe plugin id '{id}'. Use a reverse-DNS id without path separators.");
        if (!args.TryGetValue("files", out var raw)
            || JsonSerializer.Deserialize<Dictionary<string, string>>(raw) is not { Count: > 0 } files
            || files.Count > MaximumDraftFiles)
            return Task.FromResult("Not saved: files must be a JSON object with at most 256 text files.");
        var totalBytes = 0;
        foreach (var (path, content) in files)
        {
            if (!IsSafeRelativePath(path)) return Task.FromResult($"Not saved: unsafe relative path '{path}'.");
            totalBytes = checked(totalBytes + System.Text.Encoding.UTF8.GetByteCount(content));
            if (totalBytes > MaximumDraftBytes) return Task.FromResult("Not saved: draft is larger than the 2 MB limit.");
        }
        if (!files.TryGetValue("plugin.yml", out var manifestText)
            || !files.TryGetValue("plugin.ir.json", out var irText))
            return Task.FromResult("Not saved: include plugin.yml and plugin.ir.json.");

        PluginManifest manifest;
        try { manifest = MiniYaml.DecodeManifest(manifestText); }
        catch (Exception ex) { return Task.FromResult($"Not saved: plugin.yml is invalid: {ex.Message}"); }
        if (!manifest.Id.Equals(id, StringComparison.Ordinal) || !manifest.Runtime.Equals("native", StringComparison.OrdinalIgnoreCase))
            return Task.FromResult("Not saved: plugin.yml id must match the requested id and runtime must be native.");
        try { using var _ = JsonDocument.Parse(irText); }
        catch (JsonException ex) { return Task.FromResult($"Not saved: plugin.ir.json is invalid: {ex.Message}"); }

        var folder = Path.GetFullPath(Path.Combine(Drafts, id));
        if (!IsInside(folder, Drafts) || HasSymlinkComponent(folder, Drafts))
            return Task.FromResult("Not saved: draft directory is not safe.");
        try
        {
            Directory.CreateDirectory(folder);
            foreach (var (relative, content) in files)
            {
                var destination = Path.GetFullPath(Path.Combine(folder, relative.Replace('/', Path.DirectorySeparatorChar)));
                if (!IsInside(destination, folder) || HasSymlinkComponent(destination, folder))
                    return Task.FromResult($"Not saved: draft path is not safe: {relative}.");
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                var temporary = destination + "." + Guid.NewGuid().ToString("N") + ".part";
                File.WriteAllText(temporary, content, new System.Text.UTF8Encoding(false));
                File.Move(temporary, destination, overwrite: true);
            }
            return Task.FromResult($"Saved native source draft '{id}' under '{folder}'. It remains outside the runtime catalog; validate it, then use Marketplace CI to build and sign it.");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return Task.FromResult($"Not saved: {ex.Message}");
        }
    }

    private string Validate(string id)
    {
        if (!IsSafeId(id)) return "Invalid draft id.";
        var folder = Path.GetFullPath(Path.Combine(Drafts, id));
        if (!IsInside(folder, Drafts) || HasSymlinkComponent(folder, Drafts)) return "Draft directory is not safe.";
        try
        {
            var manifest = MiniYaml.DecodeManifest(File.ReadAllText(Path.Combine(folder, "plugin.yml")));
            if (!manifest.Id.Equals(id, StringComparison.Ordinal) || !manifest.Runtime.Equals("native", StringComparison.OrdinalIgnoreCase)) return "plugin.yml id/runtime does not match the requested native draft.";
            if (string.IsNullOrWhiteSpace(manifest.Library) || !IsSafeRelativePath(manifest.Library)) return "plugin.yml needs a safe relative library path.";
            using var _ = JsonDocument.Parse(File.ReadAllText(Path.Combine(folder, "plugin.ir.json")));
            return $"Valid native source draft '{id}'. Runtime loading is unavailable until Marketplace CI builds/signs the package and the user accepts the trust prompt.";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or PluginException or ArgumentException)
        {
            return $"Draft validation failed: {ex.Message}";
        }
    }

    private string ListDrafts()
    {
        try
        {
            var rows = Directory.EnumerateDirectories(Drafts)
                .Where(path => !HasSymlinkComponent(path, Drafts))
                .OrderBy(Path.GetFileName, StringComparer.Ordinal)
                .Select(path =>
                {
                    try
                    {
                        var manifest = MiniYaml.DecodeManifest(File.ReadAllText(Path.Combine(path, "plugin.yml")));
                        return $"{manifest.Id} v{manifest.Version} [source draft; not loadable]";
                    }
                    catch { return $"{Path.GetFileName(path)} [invalid draft]"; }
                }).ToArray();
            return rows.Length == 0 ? "No plugin drafts found." : string.Join('\n', rows);
        }
        catch (IOException ex) { return $"Could not list drafts: {ex.Message}"; }
        catch (UnauthorizedAccessException ex) { return $"Could not list drafts: {ex.Message}"; }
    }

    private string Remove(string id)
    {
        if (!IsSafeId(id)) return "Invalid draft id.";
        var folder = Path.GetFullPath(Path.Combine(Drafts, id));
        if (!IsInside(folder, Drafts) || HasSymlinkComponent(folder, Drafts) || !Directory.Exists(folder)) return "No safe draft with that id exists.";
        try { Directory.Delete(folder, recursive: true); return $"Removed source draft '{id}'."; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return $"Could not remove draft: {ex.Message}"; }
    }

    private static bool IsSafeId(string id) => id.Length is > 0 and <= 200
        && !id.StartsWith('.') && !id.Contains("..", StringComparison.Ordinal)
        && id.All(ch => char.IsAsciiLetterOrDigit(ch) || ch is '.' or '_' or '-');

    private static bool IsSafeRelativePath(string path) => !string.IsNullOrWhiteSpace(path)
        && !Path.IsPathRooted(path) && !path.Contains('\\') && !path.Contains('\0')
        && path.Split('/').All(part => part.Length > 0 && part is not "." and not ".." && !part.StartsWith('.'));

    private static bool IsInside(string path, string root)
    {
        var basePath = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullPath = Path.GetFullPath(path);
        return fullPath.StartsWith(basePath + Path.DirectorySeparatorChar, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
    }

    private static bool HasSymlinkComponent(string path, string root)
    {
        try
        {
            var basePath = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var current = Path.GetFullPath(path);
            if (!IsInside(current, basePath)) return true;
            while (!current.Equals(basePath, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            {
                if ((File.Exists(current) || Directory.Exists(current))
                    && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) return true;
                current = Directory.GetParent(current)?.FullName ?? returnTrue();
            }
            return false;
        }
        catch { return true; }

        static string returnTrue() => throw new IOException("Path parent is unavailable.");
    }

    private const string Schema = """
        Native plugin source package:
          plugin.yml
          plugin.ir.json
          license
          source/macos/       # Swift/SwiftUI + SwiftPM dynamic-library source
          source/windows/     # C# + WPF + IHarnessPlugin source
          source/linux/       # C# + Avalonia + IHarnessPlugin source
          artifacts/<platform>/<architecture>/

        plugin.yml contains id, name, version, abi, plane, runtime: native, and library.
        plugin.ir.json defines portable prompt/tools/events/settings/panels. Platform source
        remains platform-specific. Drafts live outside the runtime catalog; only Marketplace
        CI artifacts that pass signature/hash verification can be installed and trusted.
        """;
}
