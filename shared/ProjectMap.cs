// Copyright (c) 2026 DOTS
// The project's layout two folders deep, sent with every prompt so the agent knows
// where things live without listing or searching the workspace: per folder its file
// count, one line on what it is - from its README, its manifest, or the kinds of file
// it holds - and the files to open first. Built on this machine from git's file list
// (the walk elsewhere), with no model.
//
// Mirrors WorkspaceMemory.structureMarkdown on macOS.

namespace DotsHarnessCore;

public static class ProjectMap
{
    private const int MaxFiles = 20_000, MaxFolders = 30, MaxSubfolders = 8, MaxEntries = 4, MaxPurpose = 100;

    private static readonly Dictionary<string, string> Manifests = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Package.swift"] = "Swift package", ["package.json"] = "Node package", ["Cargo.toml"] = "Rust crate",
        ["go.mod"] = "Go module", ["pyproject.toml"] = "Python project", ["requirements.txt"] = "Python project",
        ["build.gradle"] = "Gradle project", ["build.gradle.kts"] = "Gradle project", ["settings.gradle"] = "Gradle project",
        ["settings.gradle.kts"] = "Gradle project", ["wrangler.toml"] = "Cloudflare Worker", ["wrangler.jsonc"] = "Cloudflare Worker",
        ["project.yml"] = "XcodeGen project", ["pubspec.yaml"] = "Dart package", ["composer.json"] = "PHP package",
        ["Gemfile"] = "Ruby project", ["pom.xml"] = "Maven project", ["CMakeLists.txt"] = "CMake project",
        ["Makefile"] = "", ["Dockerfile"] = "",
    };

    private static readonly HashSet<string> EntryStems = new(StringComparer.OrdinalIgnoreCase)
    {
        "main", "index", "program", "app", "server", "startup", "appdelegate",
    };

    private static readonly object Gate = new();
    private static (string Workspace, string Stamp, string Text)? _cached;

    /// <summary>
    /// The map for the prompt; its file list and fingerprint come from the shared project
    /// scan policy, so ignore-file changes are reflected in every automatic scan.
    /// </summary>
    public static string Text(string? workspace)
    {
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return "";
        var root = Path.GetFullPath(workspace);
        var scanned = NativeWorkspaceTools.ScanFiles(root).ToList();
        var stamp = WorkspaceScanPolicy.Revision(root, scanned);
        lock (Gate) if (_cached is { } hit && hit.Workspace == root && hit.Stamp == stamp) return hit.Text;
        var files = scanned.Take(MaxFiles)
            .Select(path => Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/'))
            .ToList();
        var text = Markdown(files, relative => Read(Path.Combine(root, relative)));
        lock (Gate) _cached = (root, stamp, text);
        return text;
    }

    /// <summary>The map of a file list; `read` returns the start of a file, or null.</summary>
    public static string Markdown(IReadOnlyList<string> files, Func<string, string?> read)
    {
        var folders = files.Where(path => path.Contains('/')).GroupBy(path => path[..path.IndexOf('/')], StringComparer.Ordinal)
            .OrderBy(group => group.Key, StringComparer.Ordinal).ToList();
        if (folders.Count == 0) return "";
        var lines = new List<string>
        {
            "# Project Map",
            "Folders two levels deep: what each holds, the files to open first. Start from these instead of listing or searching the workspace.",
        };
        var rootEntries = Entries("", files);
        if (rootEntries.Length > 0) lines.Add($"- root - open: {rootEntries}");
        foreach (var folder in folders.Take(MaxFolders))
        {
            lines.Add("- " + Line(folder.Key, folder.ToList(), read));
            var subfolders = folder.Where(path => path.IndexOf('/', folder.Key.Length + 1) > 0)
                .GroupBy(path => path[..path.IndexOf('/', folder.Key.Length + 1)], StringComparer.Ordinal)
                .OrderByDescending(group => group.Count()).ThenBy(group => group.Key, StringComparer.Ordinal).ToList();
            foreach (var subfolder in subfolders.Take(MaxSubfolders))
                lines.Add("  - " + Line(subfolder.Key, subfolder.ToList(), read));
            if (subfolders.Count > MaxSubfolders) lines.Add($"  - +{subfolders.Count - MaxSubfolders} more folders");
        }
        if (folders.Count > MaxFolders) lines.Add($"- +{folders.Count - MaxFolders} more folders");
        return string.Join("\n", lines);
    }

    private static string Line(string folder, List<string> inside, Func<string, string?> read)
    {
        // No file count: it moves with every added file and forces project_memory to be captured again.
        var line = $"`{folder}/` - {Purpose(folder, inside, read)}";
        var entries = Entries(folder, inside);
        return entries.Length == 0 ? line : line + " - open: " + entries;
    }

    /// <summary>Files directly in `folder` worth opening first: its README, manifests, entry points.</summary>
    private static string Entries(string folder, IReadOnlyList<string> files)
    {
        var prefix = folder.Length == 0 ? "" : folder + "/";
        return string.Join(", ", files
            .Where(path => path.StartsWith(prefix, StringComparison.Ordinal) && path.IndexOf('/', prefix.Length) < 0)
            .Select(path => path[prefix.Length..])
            .Select(name => (Name: name, Rank: Rank(name)))
            .Where(item => item.Rank >= 0)
            .OrderBy(item => item.Rank).ThenBy(item => item.Name, StringComparer.Ordinal)
            .Take(MaxEntries).Select(item => item.Name));
    }

    private static int Rank(string name)
    {
        if (name.StartsWith("README", StringComparison.OrdinalIgnoreCase)) return 0;
        if (Manifests.ContainsKey(name) || Path.GetExtension(name) is ".csproj" or ".sln") return 1;
        return EntryStems.Contains(Path.GetFileNameWithoutExtension(name)) ? 2 : -1;
    }

    /// <summary>The first sentence of the folder's README, else its manifest's kind and its main file types.</summary>
    private static string Purpose(string folder, List<string> inside, Func<string, string?> read)
    {
        var direct = inside.Where(path => path.IndexOf('/', folder.Length + 1) < 0)
            .Select(path => path[(folder.Length + 1)..]).OrderBy(name => name, StringComparer.Ordinal).ToList();
        if (direct.FirstOrDefault(name => name.StartsWith("README", StringComparison.OrdinalIgnoreCase)) is { } readme
            && FirstLine(read($"{folder}/{readme}")) is { } summary) return summary;
        if (direct.Contains("package.json") && Description(read($"{folder}/package.json")) is { } description) return description;
        var kind = direct.Select(name => Manifests.GetValueOrDefault(name) ?? (Path.GetExtension(name) is ".csproj" or ".sln" ? ".NET project" : null))
            .FirstOrDefault(value => !string.IsNullOrEmpty(value));
        var types = inside.Select(Path.GetExtension).Where(extension => extension.Length > 0)
            .GroupBy(extension => extension.ToLowerInvariant()).OrderByDescending(group => group.Count()).ThenBy(group => group.Key, StringComparer.Ordinal)
            .Take(2).Select(group => group.Key).ToList();
        var mostly = types.Count == 0 ? "" : "mostly " + string.Join(", ", types);
        return kind is null ? (mostly.Length == 0 ? "files" : mostly) : mostly.Length == 0 ? kind : $"{kind}, {mostly}";
    }

    /// <summary>The first prose line of a Markdown file: no heading, badge, HTML, rule or list marker.</summary>
    internal static string? FirstLine(string? text)
    {
        if (text is null) return null;
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length < 8 || "#![<=-*|>`".Contains(line[0])) continue;
            return line.Length <= MaxPurpose ? line : line[..MaxPurpose].TrimEnd() + "…";
        }
        return null;
    }

    /// <summary>package.json's description, matched rather than parsed: only the file's start is read.</summary>
    private static string? Description(string? json) =>
        json is not null && System.Text.RegularExpressions.Regex.Match(json, "\"description\"\\s*:\\s*\"([^\"]+)\"") is { Success: true } match
            ? FirstLine(match.Groups[1].Value)
            : null;

    private static string? Read(string path)
    {
        try
        {
            using var stream = File.OpenRead(path);
            var buffer = new byte[4_096];
            var count = stream.Read(buffer, 0, buffer.Length);
            return System.Text.Encoding.UTF8.GetString(buffer, 0, count);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }
}
