// Copyright (c) 2026 DOTS
// Agent tool boundary for plugin installation. Native code is never written
// straight into the live catalog by an agent; signed Marketplace packages are
// the only supported installation path. Mirrors the macOS InstallPluginTool.

using System.Text.Json.Nodes;
using PluginRuntime;

namespace DotsHarnessCore;

public static class InstallPluginTool
{
    public const string Name = "install_plugin";

    public const string MalformedNotice =
        "That call was not usable. Send `id` and a non-empty `files` map that includes \"plugin.yml\".";

    public const string RefusalNotice =
        "Not installed: native plugin packages must come from Marketplace after CI build, DOTS signature verification, and explicit trust acceptance.";

    public static NativeToolDefinition Definition { get; } = new(
        Name,
        "Install a native plugin through the signed Marketplace flow. This agent tool "
        + "intentionally refuses to write executable plugin code into the live catalog. "
        + "Publish a source/IR package, wait for the platform build and signature, then "
        + "install it from Marketplace after the user accepts the native-code warning. "
        + "JavaScript and manifest-only plugins are not supported.",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["id"] = new JsonObject
                {
                    ["type"] = "string",
                    ["description"] = "Plugin id, also the folder name. Reverse-DNS, no slashes or spaces.",
                },
                ["files"] = new JsonObject
                {
                    ["type"] = "object",
                    ["description"] = "Map of relative file path to text content. Must include \"plugin.yml\". "
                        + "Subfolders allowed (\"assets/x.txt\"); no absolute paths or \"..\".",
                },
                ["summary"] = new JsonObject
                {
                    ["type"] = "string",
                    ["description"] = "Optional one line on what the plugin does.",
                },
            },
            ["required"] = new JsonArray("id", "files"),
        });

    /// <summary>Never throws; a bad call is reported back to the model, not failed.</summary>
    public static string Execute(string? arguments)
    {
        JsonObject? parsed;
        try { parsed = JsonNode.Parse(arguments ?? "")?.AsObject(); }
        catch { return MalformedNotice; }
        if (parsed is null) return MalformedNotice;

        var id = (parsed["id"]?.GetValue<string>() ?? "").Trim();
        if (!IsSafeComponent(id))
            return $"Not installed: \"{id}\" is not a usable plugin id (no slashes, spaces, or \"..\").";
        if (parsed["files"] is not JsonObject files || files.Count == 0)
            return MalformedNotice;

        foreach (var (rawPath, value) in files)
        {
            if (value is not System.Text.Json.Nodes.JsonValue text || !text.TryGetValue<string>(out _))
                return $"Not installed: \"{rawPath}\" content must be a string.";
            if (!IsSafeRelativePath(rawPath))
                return $"Not installed: \"{rawPath}\" is not a safe relative path.";
        }

        if (files["plugin.yml"] is not System.Text.Json.Nodes.JsonValue manifestValue
            || !manifestValue.TryGetValue<string>(out var manifestText))
            return "Not installed: files must include \"plugin.yml\".";
        try
        {
            _ = MiniYaml.DecodeManifest(manifestText);
        }
        catch (Exception error)
        {
            return "Not installed: plugin.yml did not parse — " + error.Message;
        }

        return RefusalNotice;
    }

    internal static bool IsSafeComponent(string value)
    {
        if (string.IsNullOrEmpty(value) || value.Length > 200) return false;
        if (value.StartsWith('.')) return false;
        if (value.Contains('/') || value.Contains('\\')) return false;
        if (value.Contains("..")) return false;
        if (value.Any(char.IsWhiteSpace)) return false;
        return true;
    }

    internal static bool IsSafeRelativePath(string value)
    {
        if (string.IsNullOrEmpty(value) || value.StartsWith('/') || value.Length > 400) return false;
        var parts = value.Split('/');
        return parts.All(part => part.Length > 0 && part != ".." && part != "." && !part.StartsWith('.'));
    }
}
