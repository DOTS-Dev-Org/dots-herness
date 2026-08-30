// Copyright (c) 2026 DOTS
// Reads the rules files an agent-aware repository already ships - AGENTS.md,
// CLAUDE.md, .cursor/rules - so HerNess honours the conventions a project has
// already written down for other tools. The text is project context, never
// policy: it is emitted under trust="data".
//
// Mirrors macos/DotsHarness/Sources/DotsHarnessCore/ProjectRules.swift.

namespace DotsHarnessCore;

public static class ProjectRules
{
    /// <summary>
    /// Read in this order; the first entries carry the most weight because a
    /// repository that has both usually keeps AGENTS.md as the general file.
    /// </summary>
    public static readonly string[] FileNames = ["AGENTS.md", "CLAUDE.md", ".cursorrules"];

    public const string CursorRulesDirectory = ".cursor/rules";

    /// <summary>
    /// Per-file and total ceilings. A rules file is meant to be short; a repo
    /// that pastes a novel into AGENTS.md must not evict the conversation.
    /// </summary>
    public const int MaxBytesPerFile = 16_000;

    public const int MaxTotalBytes = 32_000;
    public const int MaxCursorRuleFiles = 10;

    /// <summary>
    /// The workspace's rules text, already labelled by source file. Empty when
    /// the project ships none.
    /// </summary>
    public static string Text(string? workspace)
    {
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return "";
        Sync(workspace);
        var blocks = new List<string>();
        var bodies = new HashSet<string>(StringComparer.Ordinal);
        var total = 0;

        foreach (var name in FileNames)
        {
            var block = Read(Path.Combine(workspace, name), name, workspace);
            if (block is null) continue;
            // After sync AGENTS.md and CLAUDE.md hold the same text; emit it once.
            if (!bodies.Add(block[block.IndexOf('\n')..])) continue;
            if (total + block.Length > MaxTotalBytes) return string.Join("\n\n", blocks);
            total += block.Length;
            blocks.Add(block);
        }

        foreach (var path in CursorRuleFiles(workspace))
        {
            var block = Read(path, RelativeLabel(path, workspace), workspace);
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
        if (File.Exists(agents) || File.Exists(claude)) return false;
        try
        {
            File.WriteAllText(agents, Seed);
            File.WriteAllText(claude, Seed);
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
        var agents = Path.Combine(workspace, "AGENTS.md");
        var claude = Path.Combine(workspace, "CLAUDE.md");
        if (!Contains(workspace, agents) || !Contains(workspace, claude)) return;

        var hasAgents = File.Exists(agents);
        var hasClaude = File.Exists(claude);
        if (!hasAgents && !hasClaude) return;

        string source, target;
        if (!hasClaude) (source, target) = (agents, claude);
        else if (!hasAgents) (source, target) = (claude, agents);
        else
        {
            (source, target) = File.GetLastWriteTimeUtc(agents) >= File.GetLastWriteTimeUtc(claude)
                ? (agents, claude)
                : (claude, agents);
        }

        try
        {
            var data = File.ReadAllBytes(source);
            if (File.Exists(target) && data.AsSpan().SequenceEqual(File.ReadAllBytes(target))) return;
            File.WriteAllBytes(target, data);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static IEnumerable<string> CursorRuleFiles(string workspace)
    {
        var directory = Path.Combine(workspace, ".cursor", "rules");
        if (!Directory.Exists(directory)) return [];
        return Directory.EnumerateFiles(directory)
            .Where(path => Path.GetExtension(path) is ".md" or ".mdc")
            .OrderBy(Path.GetFileName, StringComparer.Ordinal)
            .Take(MaxCursorRuleFiles);
    }

    private static string? Read(string path, string label, string workspace)
    {
        // Same symlink rule the file tools use: a rules file that resolves
        // outside the workspace is not this project's rules file.
        if (!File.Exists(path) || !Contains(workspace, path)) return null;
        byte[] bytes;
        try { bytes = File.ReadAllBytes(path); }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
        if (bytes.Length == 0) return null;
        var truncated = bytes.Length > MaxBytesPerFile;
        var body = System.Text.Encoding.UTF8
            .GetString(bytes, 0, Math.Min(bytes.Length, MaxBytesPerFile))
            .Trim();
        if (body.Length == 0) return null;
        return $"# {label}\n{body}" + (truncated ? "\n… truncated" : "");
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
