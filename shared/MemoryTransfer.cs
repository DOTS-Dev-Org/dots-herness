// Copyright (c) 2026 DOTS
// Portable, explicit import/export for personal and project memory.

using System.Text.Json;
using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public static class MemoryTransfer
{
    private const string Format = "dots-memory-transfer";
    private const int Version = 1;
    private const string ProfileFile = "user_profile.json";
    private static readonly string[] ProfileFields = ["preferences", "technologies", "lessons", "projectPreferences", "projectNames"];
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public static string ExportProject(string? workspace)
    {
        EnsureWorkspace(workspace);
        var facts = WorkspaceFacts.Read(workspace)
            .Where(fact => fact.Scope != WorkspaceFacts.UserScope && (fact.Kind is "project" or "decision"))
            .GroupBy(fact => (fact.Kind, fact.Key))
            .ToDictionary(group => group.Key, group => group.Last());
        foreach (var decision in ReadDecisionNotes(workspace!))
            facts.TryAdd((decision.Kind, decision.Key), decision);
        var portableFacts = facts.Values.OrderBy(fact => fact.Kind, StringComparer.Ordinal)
            .ThenBy(fact => fact.Key, StringComparer.Ordinal).Take(WorkspaceFacts.MaxFacts).Select(ToNode);
        return Bundle("project", portableFacts).ToJsonString(Json);
    }

    public static string ExportPersonal(string? userRoot)
    {
        EnsureUserRoot(userRoot);
        var facts = WorkspaceFacts.ReadPersonal(userRoot)
            .OrderBy(fact => fact.Key, StringComparer.Ordinal).Take(WorkspaceFacts.MaxFacts).Select(ToNode);
        var bundle = ParseBundle(Bundle("personal", facts).ToJsonString(Json));
        var profilePath = Path.Combine(userRoot!, ProfileFile);
        if (File.Exists(profilePath))
        {
            var profile = JsonNode.Parse(File.ReadAllText(profilePath)) as JsonObject
                ?? throw new InvalidDataException("The personal memory profile is not valid JSON.");
            var filtered = new JsonObject();
            foreach (var field in ProfileFields)
                if (profile[field] is { } value) filtered[field] = value.DeepClone();
            bundle["profile"] = filtered;
        }
        return bundle.ToJsonString(Json);
    }

    public static int ImportProject(string? workspace, string contents)
    {
        EnsureWorkspace(workspace);
        var bundle = ParseAndValidate(contents, "project");
        var facts = ParseFacts(bundle, personal: false);
        if (!WorkspaceFacts.MergeProject(workspace, facts)) throw new IOException("Project memory could not be written.");
        return facts.Count;
    }

    public static int ImportPersonal(string? userRoot, string contents)
    {
        EnsureUserRoot(userRoot);
        var bundle = ParseAndValidate(contents, "personal");
        var facts = ParseFacts(bundle, personal: true);
        if (!WorkspaceFacts.MergePersonal(userRoot, facts)) throw new IOException("Personal memory could not be written.");
        if (bundle["profile"] is JsonObject imported)
            MergeProfile(userRoot!, imported);
        return facts.Count + CountProfileEntries(bundle["profile"]);
    }

    private static JsonObject Bundle(string scope, IEnumerable<JsonNode?> facts) => new()
    {
        ["format"] = Format,
        ["version"] = Version,
        ["scope"] = scope,
        ["facts"] = new JsonArray(facts.ToArray()),
    };

    private static JsonNode ToNode(WorkspaceFact fact) => new JsonObject
    {
        ["kind"] = fact.Kind,
        ["key"] = fact.Key,
        ["text"] = fact.Text,
    };

    private static List<WorkspaceFact> ReadDecisionNotes(string workspace)
    {
        var decisions = new List<WorkspaceFact>();
        var directory = Path.Combine(workspace, ".mem", "decisions");
        if (!Directory.Exists(directory)) return decisions;
        string[] paths;
        try { paths = Directory.GetFiles(directory, "*.md").OrderBy(path => path, StringComparer.Ordinal).ToArray(); }
        catch (IOException) { return decisions; }
        catch (UnauthorizedAccessException) { return decisions; }

        foreach (var path in paths)
        {
            string contents;
            try { contents = File.ReadAllText(path); }
            catch (IOException) { continue; }
            catch (UnauthorizedAccessException) { continue; }
            var front = ParseFrontmatter(contents, out var body);
            var id = front.GetValueOrDefault("id") ?? Path.GetFileNameWithoutExtension(path);
            var key = id.StartsWith("decision-", StringComparison.Ordinal) ? id["decision-".Length..] : id;
            key = key.Trim();
            if (key.Length > WorkspaceFacts.MaxKeyLength) key = key[..WorkspaceFacts.MaxKeyLength];
            if (key.Length == 0) continue;

            var summary = ExtractSummary(body);
            if (summary.Length == 0) summary = front.GetValueOrDefault("title")?.Trim().Trim('"', '\'') ?? "";
            summary = string.Join(' ', summary.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
            if (summary.Length > WorkspaceFacts.MaxTextLength) summary = summary[..WorkspaceFacts.MaxTextLength];
            if (summary.Length > 0) decisions.Add(new WorkspaceFact("decision", key, summary));
        }
        return decisions;
    }

    private static Dictionary<string, string> ParseFrontmatter(string text, out string body)
    {
        body = text;
        var front = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!text.StartsWith("---\n", StringComparison.Ordinal) && !text.StartsWith("---\r\n", StringComparison.Ordinal)) return front;
        var start = text.IndexOf('\n') + 1;
        var end = text.IndexOf("\n---", start, StringComparison.Ordinal);
        if (end < 0) return front;
        foreach (var line in text[start..end].Split('\n'))
        {
            var colon = line.IndexOf(':');
            if (colon > 0) front[line[..colon].Trim()] = line[(colon + 1)..].Trim();
        }
        var after = text.IndexOf('\n', end + 1);
        body = after < 0 ? "" : text[(after + 1)..].TrimStart('\r', '\n');
        return front;
    }

    private static string ExtractSummary(string body)
    {
        const string heading = "## Summary";
        var start = body.IndexOf(heading, StringComparison.OrdinalIgnoreCase);
        if (start < 0) return "";
        start += heading.Length;
        while (start < body.Length && (body[start] == '\r' || body[start] == '\n' || body[start] == ' ')) start++;
        var end = body.IndexOf("\n## ", start, StringComparison.Ordinal);
        return (end < 0 ? body[start..] : body[start..end]).Trim();
    }

    private static int CountProfileEntries(JsonNode? node)
    {
        if (node is not JsonObject profile) return 0;
        var count = 0;
        foreach (var field in new[] { "preferences", "technologies", "lessons", "projectNames" })
            count += profile[field] switch
            {
                JsonObject values => values.Count,
                JsonArray values => values.Count,
                _ => 0,
            };
        if (profile["projectPreferences"] is JsonObject projects)
            count += projects.Select(pair => pair.Value is JsonObject values ? values.Count : 0).Sum();
        return count;
    }

    private static JsonObject ParseBundle(string contents) =>
        JsonNode.Parse(contents) as JsonObject ?? throw new InvalidDataException("This is not a DOTS memory archive.");

    private static JsonObject ParseAndValidate(string contents, string expectedScope)
    {
        if (contents.Length > 5_000_000) throw new InvalidDataException("The memory archive is too large.");
        var bundle = ParseBundle(contents);
        if (bundle["format"]?.GetValue<string>() != Format
            || bundle["version"]?.GetValue<int>() != Version
            || bundle["scope"]?.GetValue<string>() != expectedScope
            || bundle["facts"] is not JsonArray)
            throw new InvalidDataException("This archive is incompatible or has the wrong memory scope.");
        return bundle;
    }

    private static List<WorkspaceFact> ParseFacts(JsonObject bundle, bool personal)
    {
        var result = new List<WorkspaceFact>();
        foreach (var item in (JsonArray)bundle["facts"]!)
        {
            if (item is not JsonObject fact) throw new InvalidDataException("The archive contains an invalid memory entry.");
            var kind = fact["kind"]?.GetValue<string>()?.Trim().ToLowerInvariant() ?? "";
            var key = fact["key"]?.GetValue<string>()?.Trim() ?? "";
            var text = fact["text"]?.GetValue<string>()?.Trim() ?? "";
            var allowed = personal ? kind == "preference" : kind is "project" or "decision";
            if (!allowed || key.Length is 0 or > WorkspaceFacts.MaxKeyLength || text.Length is 0 or > WorkspaceFacts.MaxKnowledgeLength)
                throw new InvalidDataException("The archive contains a memory entry outside its declared scope.");
            var parsed = new WorkspaceFact(kind, key, text, personal ? WorkspaceFacts.UserScope : "project");
            if (WorkspaceFacts.IsSecret(parsed)) throw new InvalidDataException("The archive contains a credential-shaped memory entry.");
            result.Add(parsed);
            if (result.Count > WorkspaceFacts.MaxFacts)
                throw new InvalidDataException("The archive contains too many memory entries.");
        }
        return result;
    }

    private static void MergeProfile(string userRoot, JsonObject imported)
    {
        var path = Path.Combine(userRoot, ProfileFile);
        JsonObject current;
        try
        {
            current = File.Exists(path)
                ? JsonNode.Parse(File.ReadAllText(path)) as JsonObject ?? throw new InvalidDataException("The existing personal memory profile is not valid JSON.")
                : new JsonObject();
        }
        catch (JsonException error) { throw new InvalidDataException("The existing personal memory profile is not valid JSON.", error); }

        foreach (var field in ProfileFields)
            if (imported[field] is { } value)
                current[field] = MergeNode(current[field], value);

        Directory.CreateDirectory(userRoot);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, current.ToJsonString(Json));
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); } catch (IOException) { }
        }
    }

    private static JsonNode? MergeNode(JsonNode? current, JsonNode incoming)
    {
        if (current is JsonObject currentObject && incoming is JsonObject incomingObject)
        {
            var merged = (JsonObject)currentObject.DeepClone();
            foreach (var (key, value) in incomingObject)
            {
                if (value is null) continue;
                merged[key] = MergeNode(merged[key], value);
            }
            return merged;
        }
        if (current is JsonArray currentArray && incoming is JsonArray incomingArray)
        {
            var merged = (JsonArray)currentArray.DeepClone();
            var known = merged.Select(node => node?.ToJsonString() ?? "null").ToHashSet(StringComparer.Ordinal);
            foreach (var value in incomingArray)
            {
                var serialized = value?.ToJsonString() ?? "null";
                if (known.Add(serialized)) merged.Add(value?.DeepClone());
            }
            return merged;
        }
        return incoming.DeepClone();
    }

    private static void EnsureWorkspace(string? workspace)
    {
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace))
            throw new InvalidOperationException("Choose an open project before transferring project memory.");
    }

    private static void EnsureUserRoot(string? userRoot)
    {
        if (string.IsNullOrWhiteSpace(userRoot)) throw new InvalidOperationException("The personal memory location is unavailable.");
    }
}
