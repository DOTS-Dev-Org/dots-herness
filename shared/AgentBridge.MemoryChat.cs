// Copyright (c) 2026 DOTS
// The chat beside the memory vault: a question is answered from the notes of the open
// project, and the model may add to or correct them. Additions and corrections are
// applied as it answers; a deletion is only proposed, and the person confirms it.
//
// Mirrors AgentBridge+MemoryChat.swift on macOS.

using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace DotsHarnessCore;

public sealed class MemoryChatTurn
{
    [JsonPropertyName("id")] public string Id { get; set; } = Guid.NewGuid().ToString();
    /// <summary>"user" or "assistant".</summary>
    [JsonPropertyName("role")] public string Role { get; set; } = "user";
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    /// <summary>What the answer changed in memory, as short lines for the person.</summary>
    [JsonPropertyName("applied")] public List<string> Applied { get; set; } = [];
    /// <summary>Deletions the model asked for and the person has not confirmed. Not kept on disk.</summary>
    [JsonIgnore] public List<MemoryChatDeletion> Deletions { get; set; } = [];
}

public sealed record MemoryChatDeletion(string Id, string Title, MemoryEdit Edit);

public sealed partial class AgentBridge
{
    private const int MemoryChatNotes = 60;
    private const int MemoryChatTurns = 8;
    private const int MemoryChatKept = 200;

    public const string MemoryChatSystemPrompt =
        "You are the keeper of one software project's memory. The notes below are everything remembered about " +
        "the project and about the person working on it. Answer from them only; when they do not hold the answer, " +
        "say so instead of guessing. Refer to a note as [[its id]] so the person can open it.\n" +
        "You can also change memory when asked to add, correct or remove something. Reply with JSON only:\n" +
        "{\"answer\":\"<what you tell the person, in their language>\",\"actions\":[ ... ]}\n" +
        "Actions:\n" +
        "- {\"op\":\"set_project\",\"key\":\"<short-key>\",\"value\":\"...\"}  a fact about the project itself; shared with the team.\n" +
        "- {\"op\":\"set_preference\",\"key\":\"<short-key>\",\"value\":\"...\",\"scope\":\"everywhere|project\"}  how the person likes to work.\n" +
        "- {\"op\":\"add_rule\",\"text\":\"...\"}  a rule to follow in every request in this project.\n" +
        "- {\"op\":\"add_finding\",\"kind\":\"decision|error|lesson|area\",\"text\":\"...\"}  something learned from work done here; area is where a concern lives.\n" +
        "- {\"op\":\"edit_finding\",\"id\":\"insight:<id>\",\"text\":\"...\"}  correct a finding.\n" +
        "- {\"op\":\"delete\",\"id\":\"<note id>\"}  remove a note; the person is asked to confirm.\n" +
        "Use an action only when the person asks for a change. Never store a credential. \"actions\" may be empty.";

    /// <summary>The edit that takes a note out of memory; null for what cannot be removed.</summary>
    public static MemoryEdit? MemoryRemoval(MemoryNote note) => note.Kind switch
    {
        "project" => new MemoryEdit(MemoryEditKind.ForgetProject, Key: note.Title),
        "insight" when note.Id.StartsWith(WorkspaceMemoryVault.InsightPrefix, StringComparison.Ordinal) =>
            new MemoryEdit(MemoryEditKind.ForgetInsight, Id: note.Id[WorkspaceMemoryVault.InsightPrefix.Length..]),
        _ => null,
    };

    /// <summary>The notes handed to the model: what describes the project and the person always, the rest by overlap with the question.</summary>
    public static string MemoryChatContext(string question, MemoryVault vault)
    {
        var terms = WorkspaceInsights.Tokens(question);
        string[] always = ["project", "preference", "rule", "profile", "map", "technology"];
        var notes = vault.Notes.Where(n => n.Kind is not ("file" or "missing" or "index")).ToList();
        var pinned = notes.Where(n => always.Contains(n.Kind)).ToList();
        var recalled = notes.Where(n => !always.Contains(n.Kind))
            .Select(n => (Score: terms.Intersect(WorkspaceInsights.Tokens(n.Title + " " + n.Body + " " + string.Join(" ", n.Tags))).Count(), Note: n))
            .OrderByDescending(pair => pair.Score)
            .Take(Math.Max(0, MemoryChatNotes - pinned.Count))
            .Select(pair => pair.Note);
        return string.Join("\n", pinned.Concat(recalled).Select(note =>
        {
            var body = note.Body.Replace("\n", " ");
            var limit = note.Kind == "project" ? 1_200 : 400;
            var tags = note.Tags.Skip(1).ToList();
            return $"- id: {note.Id} | {note.Kind}{(tags.Count == 0 ? "" : " (" + string.Join(", ", tags) + ")")} | {note.Title}\n  {(body.Length > limit ? body[..limit] : body)}";
        }));
    }

    /// <summary>The chat is the person's own, so it is kept beside their other records for the project, never in the repository.</summary>
    private string? MemoryChatPath(string? workspace) =>
        WorkspaceInsights.Folder(workspace, _paths.Root) is { } folder ? Path.Combine(folder, "memory-chat.json") : null;

    public List<MemoryChatTurn> MemoryChatHistory(string? workspace)
    {
        try
        {
            return MemoryChatPath(workspace) is { } path && File.Exists(path)
                ? JsonSerializer.Deserialize<List<MemoryChatTurn>>(File.ReadAllText(path)) ?? []
                : [];
        }
        catch (Exception) { return []; }
    }

    public void SaveMemoryChat(string? workspace, IReadOnlyList<MemoryChatTurn> history)
    {
        if (MemoryChatPath(workspace) is not { } path) return;
        try
        {
            if (history.Count == 0) { File.Delete(path); return; }
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, JsonSerializer.Serialize(history.TakeLast(MemoryChatKept).ToList()));
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    /// <summary>Answers the last turn of <paramref name="history"/> and applies what the model was asked to change.</summary>
    public async Task<MemoryChatTurn> MemoryChatAsync(string? workspace, IReadOnlyList<MemoryChatTurn> history, CancellationToken ct = default)
    {
        if (history.LastOrDefault(t => t.Role == "user")?.Text is not { } question) return new MemoryChatTurn { Role = "assistant" };
        var vault = WorkspaceMemoryVault.Read(workspace, _paths.Root);
        var messages = new List<NativeMessage> { new("system", MemoryChatSystemPrompt + "\n\n## Notes\n" + MemoryChatContext(question, vault)) };
        messages.AddRange(history.TakeLast(MemoryChatTurns).Select(t => new NativeMessage(t.Role == "user" ? "user" : "assistant", t.Text)));
        string reply;
        try { reply = (await _router.CompleteAsync(messages, [], ct: ct)).Message.Content; }
        catch (Exception ex) { return new MemoryChatTurn { Role = "assistant", Text = ex.Message }; }

        // A model that ignores the format still gave an answer; it just changed nothing.
        var start = reply.IndexOf('{');
        var end = reply.LastIndexOf('}');
        JsonObject? root = null;
        if (start >= 0 && end > start)
        {
            try { root = JsonNode.Parse(reply[start..(end + 1)]) as JsonObject; }
            catch (JsonException) { }
        }
        if (root?["answer"] is not JsonValue answerValue || !answerValue.TryGetValue<string>(out var answer))
            return new MemoryChatTurn { Role = "assistant", Text = reply.Trim() };
        var (applied, deletions) = ApplyMemoryChatActions(workspace, root["actions"] as JsonArray ?? [], vault);
        return new MemoryChatTurn { Role = "assistant", Text = answer, Applied = applied, Deletions = deletions };
    }

    private (List<string>, List<MemoryChatDeletion>) ApplyMemoryChatActions(string? workspace, JsonArray actions, MemoryVault vault)
    {
        var copy = LocalizationService.Current;
        var turkish = copy.Culture.TwoLetterISOLanguageName == "tr";
        var applied = new List<string>();
        var deletions = new List<MemoryChatDeletion>();
        var root = _paths.Root;
        foreach (var action in actions.OfType<JsonObject>().Take(12))
        {
            string S(string key) => action[key] is JsonValue v && v.TryGetValue<string>(out var text) ? text.Trim() : "";
            static string Short(string text) => text.Length > 60 ? text[..60] : text;
            bool ok;
            string line;
            switch (S("op"))
            {
                case "set_project" when S("key").Length > 0 && S("value").Length > 0:
                    ok = WorkspaceMemoryVault.Edit(workspace, root, new MemoryEdit(MemoryEditKind.SetProject, Key: S("key"), Value: S("value")));
                    line = (turkish ? "Proje bilgisi: " : "Project entry: ") + S("key");
                    break;
                case "set_preference" when S("key").Length > 0 && S("value").Length > 0:
                    var fact = new JsonObject { ["kind"] = "preference", ["key"] = S("key"), ["text"] = S("value"), ["scope"] = S("scope") == "project" ? "project" : "user" };
                    ok = WorkspaceFacts.Record(workspace, fact.ToJsonString(), root).StartsWith("Recorded", StringComparison.Ordinal);
                    line = (turkish ? "Tercih: " : "Preference: ") + S("key");
                    break;
                case "add_rule" when S("text").Length > 0:
                    var rules = WorkspaceLessons.ManualRules(workspace, root).TrimEnd();
                    ok = !WorkspaceFacts.IsSecret(new WorkspaceFact("project", "rule", S("text")))
                        && WorkspaceLessons.SetManualRules(workspace, (rules.Length == 0 ? "" : rules + "\n") + S("text"), root);
                    line = (turkish ? "Kural: " : "Rule: ") + Short(S("text"));
                    break;
                case "add_finding" when S("text").Length > 0:
                    ok = !WorkspaceFacts.IsSecret(new WorkspaceFact("project", "finding", S("text")))
                        && WorkspaceInsights.AddInsight(workspace, root, S("kind"), S("text"));
                    line = (turkish ? "Çıkarım: " : "Finding: ") + Short(S("text"));
                    break;
                case "edit_finding" when S("text").Length > 0:
                    var id = S("id").StartsWith(WorkspaceMemoryVault.InsightPrefix, StringComparison.Ordinal) ? S("id")[WorkspaceMemoryVault.InsightPrefix.Length..] : S("id");
                    ok = WorkspaceMemoryVault.Edit(workspace, root, new MemoryEdit(MemoryEditKind.EditInsight, Id: id, Value: S("text")));
                    line = (turkish ? "Çıkarım düzeltildi: " : "Finding corrected: ") + Short(S("text"));
                    break;
                case "delete":
                    if (vault.Notes.FirstOrDefault(n => n.Id == S("id")) is { } note && MemoryRemoval(note) is { } removal
                        && deletions.All(d => d.Id != note.Id))
                        deletions.Add(new MemoryChatDeletion(note.Id, note.Title, removal));
                    continue;
                default:
                    continue;
            }
            applied.Add(ok ? line : (turkish ? "Kaydedilmedi: " : "Not saved: ") + line);
        }
        return (applied, deletions);
    }
}
