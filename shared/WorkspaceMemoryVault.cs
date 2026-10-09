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

public enum MemoryEditKind { SetProject, ForgetProject, PinLesson, ForgetLesson, EditLesson, SetManualRules }
public sealed record MemoryEdit(MemoryEditKind Kind, string Key = "", string Id = "", string Value = "");

public static class WorkspaceMemoryVault
{
    private static readonly Regex WikiLink = new(@"\[\[([^\]]+)\]\]", RegexOptions.Compiled);
    private const string ProjectPrefix = "project:";

    public static MemoryVault Read(string? workspace, string? userRoot = null)
    {
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return MemoryVault.Empty;
        var root = Path.Combine(workspace, ".mem");
        if (!Directory.Exists(root)) return MemoryVault.Empty;

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

        var learnedPath = Path.Combine(root, "learned_rules.md");
        var learnedBody = ReadText(learnedPath);
        AddLearned("learned_rules", "rule", "Learned rules", "learned_rules.md",
            learnedBody.Length == 0 ? "# Learned rules" : learnedBody);

        foreach (var fact in WorkspaceFacts.Read(workspace).Where(item => item.Kind == "project").OrderBy(item => item.Key, StringComparer.Ordinal))
            AddLearned(ProjectPrefix + fact.Key, "project", fact.Key, "", fact.Text);

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

        void AddLearned(string id, string kind, string title, string path, string body)
        {
            if (string.IsNullOrWhiteSpace(body)) return;
            byId[id] = new MemoryNote(id, kind, title, path, body, [kind], ["index"], [], true);
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
        var hasManifest = !string.IsNullOrWhiteSpace(workspace)
            && File.Exists(Path.Combine(workspace, ".mem", "manifest.json"));
        WorkspaceAccessStore? access = null;
        if (hasManifest && !string.IsNullOrWhiteSpace(userRoot))
        {
            access = new WorkspaceAccessStore(workspace!, userRoot!);
            if (edit.Kind is MemoryEditKind.SetProject or MemoryEditKind.ForgetProject && !access.CanEditProjectDefaults()) return false;
        }
        return edit.Kind switch
        {
            MemoryEditKind.SetProject => string.IsNullOrWhiteSpace(value)
                ? hasManifest ? access!.ForgetProjectDefault(edit.Key) : WorkspaceFacts.ForgetProject(workspace, edit.Key)
                : hasManifest ? access!.SetProjectDefault(edit.Key, value) : WorkspaceFacts.SetProject(workspace, edit.Key, value),
            MemoryEditKind.ForgetProject => hasManifest
                ? access!.ForgetProjectDefault(edit.Key)
                : WorkspaceFacts.ForgetProject(workspace, edit.Key),
            MemoryEditKind.PinLesson => WorkspaceLessons.Pin(workspace, edit.Id),
            MemoryEditKind.ForgetLesson => WorkspaceLessons.Forget(workspace, edit.Id),
            MemoryEditKind.EditLesson => WorkspaceLessons.EditRule(workspace, edit.Id, value),
            MemoryEditKind.SetManualRules => WorkspaceLessons.SetManualRules(workspace, value),
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
