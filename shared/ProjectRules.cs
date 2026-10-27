// Copyright (c) 2026 DOTS
// Reads the rules files an agent-aware repository already ships - AGENTS.md,
// CLAUDE.md, AGENTS.override.md, .claude/rules, .cursor/rules and their
// siblings - so HerNess honours the conventions a project has already written
// down for other tools.
//
// Mirrors workspace-level loading in macOS ProjectRules.swift; descendant scope
// context is assembled by the macOS agent host.

namespace DotsHarnessCore;

public static class ProjectRules
{
    private sealed record CachedSnapshot(string Signature, string Text);
    private static readonly object CacheGate = new();
    private static readonly Dictionary<string, CachedSnapshot> Snapshots = new(StringComparer.Ordinal);

    /// <summary>
    /// Read in this order; the first entries carry the most weight because a
    /// repository that has both usually keeps AGENTS.md as the general file.
    /// </summary>
    public static readonly string[] FileNames =
    [
        "AGENTS.md",
        "CLAUDE.md",
        "CLAUDE.local.md",
        ".claude/CLAUDE.md",
        "GEMINI.md",
        ".github/copilot-instructions.md",
        ".cursorrules",
    ];

    public const string OverrideFileName = "AGENTS.override.md";

    public static readonly string[] RulesDirectories = [".claude/rules", ".cursor/rules"];

    /// <summary>
    /// Per-file and total ceilings. A rules file is meant to be short; a repo
    /// that pastes a novel into AGENTS.md must not evict the conversation.
    /// </summary>
    public const int MaxBytesPerFile = 16_000;

    public const int MaxTotalBytes = 32_000;
    public const int MaxRuleFilesPerDirectory = 10;

    /// <summary>
    /// The workspace's rules text, already labelled by source file. Empty when
    /// the project ships none.
    /// </summary>
    public static string Text(string? workspace) => Snapshot(workspace).Text;

    /// <summary>Returns whether the rule text came from the metadata-validated cache.</summary>
    internal static (string Text, bool CacheHit) Snapshot(string? workspace)
    {
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return ("", false);
        lock (CacheGate)
        {
            var root = ResolveLinks(Path.GetFullPath(workspace));
            var before = Signature(root);
            if (Snapshots.TryGetValue(root, out var cached) && cached.Signature == before)
                return (cached.Text, true);

            var text = LoadTextAndSync(root);
            var after = Signature(root);
            if (before == after)
            {
                if (Snapshots.Count >= 16) Snapshots.Clear();
                Snapshots[root] = new CachedSnapshot(after, text);
            }
            else
            {
                Snapshots.Remove(root);
            }
            return (text, false);
        }
    }

    /// <summary>Invalidates a workspace after an in-app rules-file write.</summary>
    public static void Invalidate(string? workspace)
    {
        if (string.IsNullOrWhiteSpace(workspace)) return;
        lock (CacheGate) Snapshots.Remove(ResolveLinks(Path.GetFullPath(workspace)));
    }

    private static string LoadTextAndSync(string workspace)
    {
        var files = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        foreach (var name in FileNames.Append(OverrideFileName))
        {
            var data = ReadData(Path.Combine(workspace, name), workspace);
            if (data is not null) files[name] = data;
        }

        var agents = Path.Combine(workspace, "AGENTS.md");
        var claude = Path.Combine(workspace, "CLAUDE.md");
        if (Contains(workspace, agents) && Contains(workspace, claude)
            && SyncPair(agents, claude, files) is { } pair
            && files.TryGetValue(Path.GetFileName(pair.Source), out var sourceData))
        {
            try
            {
                File.WriteAllBytes(pair.Target, sourceData);
                files[Path.GetFileName(pair.Target)] = sourceData;
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        var blocks = new List<string>();
        var bodies = new HashSet<string>(StringComparer.Ordinal);
        var total = 0;

        // AGENTS.override.md replaces AGENTS.md/CLAUDE.md, not the other tools' files.
        var rootRuleNames = files.ContainsKey(OverrideFileName)
            ? [OverrideFileName, .. FileNames.Where(name => name is not "AGENTS.md" and not "CLAUDE.md")]
            : FileNames;
        foreach (var name in rootRuleNames)
        {
            var block = files.TryGetValue(name, out var data) ? Render(data, name) : null;
            if (block is null) continue;
            // After sync AGENTS.md and CLAUDE.md hold the same text; emit it once.
            if (!bodies.Add(block[block.IndexOf('\n')..])) continue;
            if (total + block.Length > MaxTotalBytes) break;
            total += block.Length;
            blocks.Add(block);
        }

        foreach (var path in RuleFiles(workspace))
        {
            var data = ReadData(path, workspace);
            var block = data is null ? null : Render(data, RelativeLabel(path, workspace));
            if (block is null) continue;
            if (total + block.Length > MaxTotalBytes) break;
            total += block.Length;
            blocks.Add(block);
        }

        return string.Join("\n\n", blocks);
    }

    /// <summary>
    /// Written to both files when a project ships neither, so every workspace
    /// starts with a rules file the user can edit.
    /// </summary>
    public const string Seed = """
        # Project rules
        
        Conventions for any agent working in this repository.
        AGENTS.md and CLAUDE.md are kept byte-identical by HerNess: edit either one.
        
        - (add project conventions here)
        """;

    /// <summary>
    /// Creates AGENTS.md and CLAUDE.md when the project ships neither. Called
    /// once when a workspace opens, before the first turn - never per message -
    /// and skipped entirely when the user turns the setting off. A project that
    /// already has either file is left alone.
    /// </summary>
    public static bool SeedIfMissing(string? workspace)
    {
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return false;
        var agents = Path.Combine(workspace, "AGENTS.md");
        var claude = Path.Combine(workspace, "CLAUDE.md");
        if (!Contains(workspace, agents) || !Contains(workspace, claude)) return false;
        if (File.Exists(agents) || File.Exists(claude) || File.Exists(Path.Combine(workspace, OverrideFileName))) return false;
        try
        {
            File.WriteAllText(agents, Seed);
            File.WriteAllText(claude, Seed);
            Invalidate(workspace);
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    /// <summary>
    /// Keeps AGENTS.md and CLAUDE.md identical: whichever was written last wins
    /// and is mirrored onto the other, so a rule the user records in one tool's
    /// file is honoured by the other. Missing counterpart is created.
    /// </summary>
    public static void Sync(string? workspace)
    {
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return;
        var root = ResolveLinks(Path.GetFullPath(workspace));
        var agents = Path.Combine(root, "AGENTS.md");
        var claude = Path.Combine(root, "CLAUDE.md");
        if (!Contains(root, agents) || !Contains(root, claude)) return;
        var files = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        var agentsData = ReadData(agents, root);
        var claudeData = ReadData(claude, root);
        if (agentsData is not null) files[Path.GetFileName(agents)] = agentsData;
        if (claudeData is not null) files[Path.GetFileName(claude)] = claudeData;
        if (SyncPair(agents, claude, files) is not { } pair
            || !files.TryGetValue(Path.GetFileName(pair.Source), out var data)) return;
        try
        {
            File.WriteAllBytes(pair.Target, data);
            Invalidate(root);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static (string Source, string Target)? SyncPair(string agents, string claude, IReadOnlyDictionary<string, byte[]> files)
    {
        files.TryGetValue(Path.GetFileName(agents), out var a);
        files.TryGetValue(Path.GetFileName(claude), out var c);
        if (a is null && c is null || a is not null && c is not null && a.AsSpan().SequenceEqual(c)) return null;
        if (a is not null && c is null) return (agents, claude);
        if (a is null && c is not null) return (claude, agents);
        return File.GetLastWriteTimeUtc(agents) >= File.GetLastWriteTimeUtc(claude)
            ? (agents, claude)
            : (claude, agents);
    }

    private static string Signature(string workspace)
    {
        var parts = new List<string> { workspace };
        foreach (var name in FileNames.Append(OverrideFileName)) parts.Add(FileStamp(Path.Combine(workspace, name), workspace));
        var ruleFiles = RuleFiles(workspace).ToArray();
        parts.Add("rules:" + string.Join("\0", ruleFiles.Select(path => RelativeLabel(path, workspace))));
        parts.AddRange(ruleFiles.Select(path => FileStamp(path, workspace)));
        return string.Join("\u0001", parts);
    }

    private static string FileStamp(string path, string workspace)
    {
        if (!Contains(workspace, path)) return path + "|outside";
        var resolved = ResolveLinks(Path.GetFullPath(path));
        try
        {
            var info = new FileInfo(resolved);
            if (!info.Exists) return path + "|missing";
            return string.Join("|", path, resolved, info.Length,
                info.LastWriteTimeUtc.Ticks, info.CreationTimeUtc.Ticks, (int)info.Attributes);
        }
        catch (IOException) { return path + "|missing"; }
        catch (UnauthorizedAccessException) { return path + "|missing"; }
    }

    private static IEnumerable<string> RuleFiles(string workspace) =>
        RulesDirectories.SelectMany(relative =>
        {
            var directory = Path.Combine(workspace, relative.Replace('/', Path.DirectorySeparatorChar));
            if (!Directory.Exists(directory)) return [];
            return Directory.EnumerateFiles(directory)
                .Where(path => Path.GetExtension(path).ToLowerInvariant() is ".md" or ".mdc")
                .OrderBy(Path.GetFileName, StringComparer.Ordinal)
                .Take(MaxRuleFilesPerDirectory);
        });

    private static byte[]? ReadData(string path, string workspace)
    {
        // Same symlink rule the file tools use: a rules file that resolves
        // outside the workspace is not this project's rules file.
        if (!File.Exists(path) || !Contains(workspace, path)) return null;
        byte[] bytes;
        try { bytes = File.ReadAllBytes(path); }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
        return bytes;
    }

    private static string? Render(byte[] bytes, string label)
    {
        if (bytes.Length == 0) return null;
        var truncated = bytes.Length > MaxBytesPerFile;
        var length = truncated ? Utf8Boundary(bytes, MaxBytesPerFile) : bytes.Length;
        var body = System.Text.Encoding.UTF8.GetString(bytes, 0, length).Trim();
        if (body.Length == 0) return null;
        return $"# {label}\n{body}" + (truncated ? "\n… truncated" : "");
    }

    /// <summary>
    /// Largest cut point at or below <paramref name="limit"/> that does not split
    /// a multi-byte character, so a truncated Turkish or CJK file never ends in a
    /// replacement character.
    /// </summary>
    private static int Utf8Boundary(byte[] bytes, int limit)
    {
        var cut = limit;
        while (cut > 0 && (bytes[cut] & 0xC0) == 0x80) cut--;
        return cut;
    }

    private static bool Contains(string workspace, string path)
    {
        var root = ResolveLinks(Path.GetFullPath(workspace));
        var resolved = ResolveLinks(Path.GetFullPath(path));
        var prefix = root.EndsWith(Path.DirectorySeparatorChar) ? root : root + Path.DirectorySeparatorChar;
        return resolved.StartsWith(prefix, StringComparison.Ordinal);
    }

    private static string ResolveLinks(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.ResolveLinkTarget(returnFinalTarget: true)?.FullName ?? info.FullName;
        }
        catch (IOException) { return path; }
    }

    private static string RelativeLabel(string path, string workspace) =>
        Path.GetRelativePath(workspace, path).Replace(Path.DirectorySeparatorChar, '/');
}
