// Copyright (c) 2026 DOTS
// Shared Markdown vault projection and guarded edits for the Windows and Linux clients.

using System.Text.RegularExpressions;

namespace DotsHarnessCore;

public sealed record MemoryNote(
    string Id,
    string Kind,
    string Title,
    string Path,
    string Body,
    IReadOnlyList<string> Tags,
    IReadOnlyList<string> Links,
    IReadOnlyList<string> Backlinks,
    bool Resolved = true);

public sealed record MemoryVaultEdge(string From, string To);
public sealed record MemoryVault(IReadOnlyList<MemoryNote> Notes, IReadOnlyList<MemoryVaultEdge> Edges)
{
    public static MemoryVault Empty { get; } = new([], []);
}

public enum MemoryEditKind { SetProject, ForgetProject, PinLesson, ForgetLesson, EditLesson, SetManualRules, EditInsight, ForgetInsight, ForgetDecision, KeepDecision }
public sealed record MemoryEdit(MemoryEditKind Kind, string Key = "", string Id = "", string Value = "");

public static class WorkspaceMemoryVault
{
    private static readonly Regex WikiLink = new(@"\[\[([^\]]+)\]\]", RegexOptions.Compiled);
    private const string ProjectPrefix = "project:";
    public const string InsightPrefix = "insight:";
    public const string ToolPrefix = "tool:";
    /// <summary>The tag of a decision a review suggested removing; see <see cref="ProjectDecisions.Proposals"/>.</summary>
    public const string ReviewTag = "review";

    public static MemoryVault Read(string? workspace, string? userRoot = null)
    {
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return MemoryVault.Empty;
        var root = Path.Combine(workspace, ".mem");
        // Findings are the person's and live outside the repository, so a project with no
        // .mem folder may still have a memory to show.
        var insights = WorkspaceInsights.Read(workspace, userRoot).Insights;
        var tools = WorkspaceInsights.ToolUses(workspace, userRoot);
        if (!Directory.Exists(root) && insights.Count == 0 && tools.Count == 0) return MemoryVault.Empty;

        var byId = new Dictionary<string, MemoryNote>(StringComparer.Ordinal);
        var order = new List<string>();
        void Ingest(string path, string fallbackKind)
        {
            if (!File.Exists(path) || !path.EndsWith(".md", StringComparison.OrdinalIgnoreCase)) return;
            string text;
            try { text = File.ReadAllText(path); }
            catch (IOException) { return; }
            catch (UnauthorizedAccessException) { return; }
            var front = ParseFrontmatter(text, out var body);
            var stem = Path.GetFileNameWithoutExtension(path);
            var kind = front.GetValueOrDefault("type", fallbackKind);
            var id = front.GetValueOrDefault("id") ?? (fallbackKind switch
            {
                "task" => "task-" + stem,
                "decision" => "decision-" + stem,
                "conversation" => "conversation-" + stem,
                _ => stem,
            });
            var title = Unquote(front.GetValueOrDefault("title") ?? stem);
            var relative = Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/');
            var note = new MemoryNote(id, kind, title, relative, body, ParseTags(front.GetValueOrDefault("tags")),
                ExtractLinks(text), [], true);
            if (!byId.ContainsKey(id)) order.Add(id);
            byId[id] = note;
        }

        foreach (var name in new[] { "map.md", "index.md", "preferences.md" })
            Ingest(Path.Combine(root, name), "note");

        var learnedBody = WorkspaceLessons.RulesText(workspace, userRoot);
        AddLearned("learned_rules", "rule", "Learned rules", "learned_rules.md",
            learnedBody.Length == 0 ? "# Learned rules" : learnedBody);

        var review = ProjectDecisions.Proposals(workspace, userRoot).Select(item => item.Key).ToHashSet(StringComparer.Ordinal);
        foreach (var fact in WorkspaceFacts.Read(workspace)
            .Where(item => item.Kind is "project" or "preference" or "decision")
            .OrderBy(item => item.Kind, StringComparer.Ordinal).ThenBy(item => item.Key, StringComparer.Ordinal))
            AddLearned(fact.Kind == "decision" ? ProjectDecisions.NoteId(fact.Key) : ProjectPrefix + fact.Key,
                fact.Kind, fact.Key, fact.Kind == "decision" ? ".mem/facts.md" : "", fact.Text,
                fact.Kind != "decision" ? [] : ProjectDecisions.PlatformsOf(fact.Text).Concat(review.Contains(fact.Key) ? [ReviewTag] : []));

        var profile = WorkspaceFacts.UserText(userRoot, workspace);
        if (profile.Length > 0) AddLearned("user-profile", "profile", "User profile", "", profile);

        foreach (var (folder, kind) in new[] { ("tasks", "task"), ("decisions", "decision"), ("conversations", "conversation") })
        {
            var directory = Path.Combine(root, folder);
            if (!Directory.Exists(directory)) continue;
            string[] files;
            try { files = Directory.GetFiles(directory, "*.md").OrderByDescending(Path.GetFileName, StringComparer.Ordinal).ToArray(); }
            catch (IOException) { continue; }
            catch (UnauthorizedAccessException) { continue; }
            foreach (var file in files) Ingest(file, kind);
        }

        foreach (var insight in insights)
        {
            var id = InsightPrefix + insight.Id;
            byId[id] = new MemoryNote(id, "insight", insight.Text.Length > 60 ? insight.Text[..60] : insight.Text, "", insight.Text,
                [insight.Kind], insight.Files.Select(file => "file:" + file).Concat(byId.ContainsKey("index") ? ["index"] : []).ToList(), [], true);
            order.Add(id);
        }
        foreach (var tool in tools)
        {
            var id = ToolPrefix + tool.Name;
            byId[id] = new MemoryNote(id, "tool", tool.Name, "", $"Used {tool.Calls} times in {tool.Tasks} tasks.", ["tool"], [], [], true);
            order.Add(id);
        }

        for (var index = 0; index < order.Count; index++)
        {
            var source = byId[order[index]];
            foreach (var link in source.Links)
            {
                if (byId.ContainsKey(link)) continue;
                var isFile = link.StartsWith("file:", StringComparison.Ordinal);
                byId[link] = new MemoryNote(link, isFile ? "file" : "missing",
                    isFile ? link[5..] : link, "", "", [], [], [], isFile);
                order.Add(link);
            }
        }

        var backlinks = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        var edges = new List<MemoryVaultEdge>();
        foreach (var id in order)
        {
            foreach (var link in byId[id].Links)
            {
                if (!backlinks.TryGetValue(link, out var sources)) backlinks[link] = sources = [];
                sources.Add(id);
                edges.Add(new MemoryVaultEdge(id, link));
            }
        }
        var notes = order.Select(id => byId[id] with
            { Backlinks = backlinks.GetValueOrDefault(id, []).OrderBy(item => item, StringComparer.Ordinal).ToList() }).ToList();
        return new MemoryVault(notes, edges);

        void AddLearned(string id, string kind, string title, string path, string body, IEnumerable<string>? tags = null)
        {
            if (string.IsNullOrWhiteSpace(body)) return;
            byId[id] = new MemoryNote(id, kind, title, path, body, [kind, .. tags ?? []], ["index"], [], true);
            order.Add(id);
            if (byId.TryGetValue("index", out var indexNote) && !indexNote.Links.Contains(id, StringComparer.Ordinal))
                byId["index"] = indexNote with { Links = indexNote.Links.Append(id).ToList() };
        }
    }

    public static bool Edit(string? workspace, string? userRoot, MemoryEdit edit)
    {
        var value = edit.Value;
        if (value.Length > 0 && WorkspaceFacts.IsSecret(new WorkspaceFact("project", edit.Key.Length > 0 ? edit.Key : "note", value)))
            return false;
        return edit.Kind switch
        {
            MemoryEditKind.SetProject => string.IsNullOrWhiteSpace(value)
                ? WorkspaceFacts.ForgetProject(workspace, edit.Key)
                : WorkspaceFacts.SetProject(workspace, edit.Key, value),
            MemoryEditKind.ForgetProject => WorkspaceFacts.ForgetProject(workspace, edit.Key),
            MemoryEditKind.PinLesson => WorkspaceLessons.Pin(workspace, edit.Id, userRoot),
            MemoryEditKind.ForgetLesson => WorkspaceLessons.Forget(workspace, edit.Id, userRoot),
            MemoryEditKind.EditLesson => WorkspaceLessons.EditRule(workspace, edit.Id, value, userRoot),
            MemoryEditKind.SetManualRules => WorkspaceLessons.SetManualRules(workspace, value, userRoot),
            MemoryEditKind.EditInsight => WorkspaceInsights.EditInsight(workspace, userRoot, edit.Id, value),
            MemoryEditKind.ForgetInsight => WorkspaceInsights.ForgetInsight(workspace, userRoot, edit.Id),
            MemoryEditKind.ForgetDecision => ProjectDecisions.Forget(workspace, userRoot, edit.Key),
            MemoryEditKind.KeepDecision => ProjectDecisions.Keep(workspace, userRoot, edit.Key),
            _ => false,
        };
    }

    private static Dictionary<string, string> ParseFrontmatter(string text, out string body)
    {
        body = text;
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!text.StartsWith("---\n", StringComparison.Ordinal) && !text.StartsWith("---\r\n", StringComparison.Ordinal)) return result;
        var start = text.IndexOf('\n') + 1;
        var end = text.IndexOf("\n---", start, StringComparison.Ordinal);
        if (end < 0) return result;
        foreach (var line in text[start..end].Split('\n'))
        {
            var colon = line.IndexOf(':');
            if (colon <= 0) continue;
            result[line[..colon].Trim()] = line[(colon + 1)..].Trim();
        }
        var after = text.IndexOf('\n', end + 1);
        body = after < 0 ? "" : text[(after + 1)..].TrimStart('\r', '\n');
        return result;
    }

    private static IReadOnlyList<string> ParseTags(string? value) => string.IsNullOrWhiteSpace(value)
        ? []
        : value.Trim().Trim('[', ']').Split([',', ' '], StringSplitOptions.RemoveEmptyEntries)
            .Select(Unquote).Where(item => item.Length > 0).ToList();

    private static IReadOnlyList<string> ExtractLinks(string text) =>
        WikiLink.Matches(text).Select(match => match.Groups[1].Value.Trim()).Where(value => value.Length > 0)
            .Distinct(StringComparer.Ordinal).ToList();

    private static string Unquote(string value) => value.Trim().Trim('"', '\'');

    private static string ReadText(string path)
    {
        try { return File.Exists(path) ? File.ReadAllText(path) : ""; }
        catch (IOException) { return ""; }
        catch (UnauthorizedAccessException) { return ""; }
    }
}
