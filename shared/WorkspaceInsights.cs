// Copyright (c) 2026 DOTS
// What the work in a project taught, kept as short findings instead of chat text: what
// was decided, what went wrong, what was learned and where each concern lives. A scan on
// a light model indexes finished tasks into findings while their compact task notes remain
// available as source evidence. The project is also read a part at a time in the background,
// and findings are consolidated once enough have piled up. They are the person's, so the app
// keeps them under the project's id in its support folder, never in the repository.
//
// Mirrors WorkspaceMemory+Insights, +Study and +Compaction on macOS, and reads and
// writes the same insights.json.

using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace DotsHarnessCore;

public sealed class MemoryInsight
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("kind")] public string Kind { get; set; } = "lesson";
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("files")] public List<string> Files { get; set; } = [];
    [JsonPropertyName("tools")] public List<string> Tools { get; set; } = [];
    /// <summary>
    /// Words a request about it would use, in English and the requests' language: what recall
    /// matches when a request names the same thing in other words.
    /// </summary>
    [JsonPropertyName("keywords")] public List<string> Keywords { get; set; } = [];
    /// <summary>The tasks it was learned from.</summary>
    [JsonPropertyName("runs")] public List<string> Runs { get; set; } = [];
    /// <summary>How many scans found it. A finding met again counts for more when recalled.</summary>
    [JsonPropertyName("strength")] public int Strength { get; set; } = 1;
    [JsonPropertyName("updatedAt")] public string UpdatedAt { get; set; } = "";
    /// <summary>"user" when the person wrote or corrected it; absent when a scan drew it.</summary>
    [JsonPropertyName("source")] public string? Source { get; set; }

    public const string UserSource = "user";

    /// <summary>
    /// A decision, or what the person wrote, is a rule: no scan, consolidation or cap
    /// rewrites or removes it. Only the person forgets one.
    /// </summary>
    [JsonIgnore] public bool IsRule => Kind == "decision" || Source == UserSource;
}

public sealed class InsightFile
{
    [JsonPropertyName("insights")] public List<MemoryInsight> Insights { get; set; } = [];
    /// <summary>Tasks a scan has already read, whether or not they taught anything.</summary>
    [JsonPropertyName("scannedRuns")] public List<string> ScannedRuns { get; set; } = [];
    [JsonPropertyName("lastScan")] public string? LastScan { get; set; }
    /// <summary>Parts of the project a study has read.</summary>
    [JsonPropertyName("studied")] public List<string>? Studied { get; set; }
    /// <summary>How many findings the last consolidation left.</summary>
    [JsonPropertyName("consolidatedCount")] public int? ConsolidatedCount { get; set; }
}

public static class WorkspaceInsights
{
    /// <summary>area: where one concern of the project lives and what was last done there.</summary>
    public static readonly string[] Kinds = ["decision", "error", "lesson", "area"];

    public const int MaxInsights = 300;
    public const int MaxKeywords = 12;
    /// <summary>Findings one `recall` call returns.</summary>
    public const int RecallLimit = 12;
    public const int ScanBatch = 12;
    /// <summary>What the findings may take of a prompt, in characters: about 750 tokens.</summary>
    public const int InsightBudget = 3_000;
    /// <summary>Findings are consolidated each time this many have been added since the last time.</summary>
    public const int ConsolidationStep = 60;
    public const int StudyAreas = 12;
    public const int StudyDocuments = 5;
    public const string StudyRoot = ".";

    public const string ScanSystemPrompt =
        "You maintain the long-term memory of one software project. You are given tasks that were finished in it - "
        + "the request, the outcome, the files changed and the tool calls made - and the findings already known.\n"
        + "Their compact notes remain available as source evidence after a scan, including when the scan finds no lasting insight. "
        + "Keep only what a later task in this same project must "
        + "know and could not read from the code. Never retell the conversation or list what was built: a finished "
        + "change is in the code, not in memory.\n"
        + "Each finding has a kind:\n"
        + "- decision: a choice made for this project and the reason - an approach, a library, a convention, something ruled out.\n"
        + "  A decision not to make a requested change is still a decision when its lasting tradeoff is stated.\n"
        + "- error: a mistake or failure - what went wrong, why, and what fixed it.\n"
        + "- lesson: what the work taught - the exact command that builds, tests or deploys, a limit of the "
        + "environment, a way of working the user asked for.\n"
        + "- area: where one concern of the project lives, so a later task opens it without searching - the concern "
        + "in the words the requests use for it, the files and functions that hold it, and in a few words what was "
        + "last changed there. One per concern: a task that worked in a known area returns that area's id with the "
        + "text brought up to date, never a second area.\n"
        + "Rules:\n"
        + "- One fact per finding, at most 200 characters, in the language of the requests.\n"
        + "- Name real files and commands from the input. Never invent one. Never include a credential.\n"
        + "- When a task repeats a known finding, return that finding with its \"id\" instead of a new one; correct its "
        + "text if the new task shows more. Put a known finding's id under \"drop\" only when a task proves it wrong.\n"
        + "- Capture every lasting decision stated in the task outcome, including a rejected change and its reason. "
        + "Do not replace it with an area summary. When the outcome does not state a lasting reason, do not invent one.\n"
        + "- Also put under \"drop\" a known finding that is none of the four kinds: one that only says what was "
        + "built or how large it came out.\n"
        + "- Most tasks teach nothing lasting. A task that changed files still yields its area, and no more than one.\n"
        + "- Give each finding up to 8 \"keywords\": words a later request about it would use, in English and in the "
        + "language of the requests, with common synonyms - lowercase, one or two words each. Recall matches on them.\n"
        + "Reply with JSON only:\n"
        + "{\"insights\":[{\"id\":\"<known id, or omit>\",\"kind\":\"decision|error|lesson|area\",\"text\":\"...\",\"files\":[\"path\"],"
        + "\"tools\":[\"name\"],\"keywords\":[\"word\"],\"runs\":[\"<task id>\"]}],\"drop\":[\"<known id>\"]}";

    public const string StudySystemPrompt =
        "You are building the long-term memory of one software project before any work was done in it. You are "
        + "given one part of the project - its file names, its own documents and manifests, and for the root its "
        + "recent commit subjects - and the findings already known.\n"
        + "Extract only what someone starting a task here must know and would not see at a glance:\n"
        + "- decision: a choice the project made and holds to - an architecture, a library, a convention, something "
        + "ruled out - with the reason when it is stated.\n"
        + "- error: a failure the documents or commits record, and its fix.\n"
        + "- lesson: the exact command that builds, tests, runs or deploys; a limit of the environment; a rule the "
        + "documents set for whoever works here.\n"
        + "- area: where one concern of this part lives (packaging, tests, a feature) - the concern, then the files "
        + "that hold it. Only when the file names or documents show it plainly.\n"
        + "Rules:\n"
        + "- One fact per finding, at most 200 characters, in the language of the documents. At most 6 findings.\n"
        + "- Name real files and commands from the input. Never invent one. Never include a credential.\n"
        + "- When the part repeats a known finding, return that finding with its \"id\" instead of a new one.\n"
        + "- A part that states nothing lasting yields nothing.\n"
        + "- Give each finding up to 8 \"keywords\": words a later request about it would use, in English and in the "
        + "language of the documents, with common synonyms - lowercase, one or two words each. Recall matches on them.\n"
        + "Reply with JSON only:\n"
        + "{\"insights\":[{\"id\":\"<known id, or omit>\",\"kind\":\"decision|error|lesson|area\",\"text\":\"...\",\"files\":[\"path\"],\"keywords\":[\"word\"]}]}";

    public const string ConsolidationSystemPrompt =
        "You compact the long-term memory of one software project, the way a long conversation is compacted: "
        + "nothing still true is lost, it only takes less room. You are given every finding, with how often it was "
        + "met and when it was last met.\n"
        + "- Findings that say the same thing, or parts of one thing, become one: return it under the id of the one "
        + "you keep, its text rewritten to hold what the others added, and put the other ids under \"drop\".\n"
        + "- Where two findings contradict each other, keep the one met last and drop the other.\n"
        + "- Drop a finding that only says what was built or how large it came out. An area - where a concern "
        + "lives - is kept, one per concern.\n"
        + "- A finding that stands alone and still holds is left out of your reply: it stays exactly as it is. "
        + "Never reword one for style.\n"
        + "- One fact per finding, at most 200 characters, in the language it is written in. Never invent a file, "
        + "a command or a fact.\n"
        + "- A finding you keep for others takes over their keywords: list them under \"keywords\". A finding with "
        + "none yet is returned with up to 8, its text unchanged - words a request about it would use, in English and "
        + "in its own language.\n"
        + "Reply with JSON only:\n"
        + "{\"insights\":[{\"id\":\"<the id kept>\",\"kind\":\"decision|error|lesson|area\",\"text\":\"...\",\"keywords\":[\"word\"]}],\"drop\":[\"<id>\"]}";

    private static readonly object Gate = new();
    // Findings are written in the person's language and name commands: kept readable on disk.
    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private static readonly HashSet<string> StopWords = new(StringComparer.Ordinal)
    {
        "the", "and", "for", "with", "that", "this", "from", "are", "was", "were", "have", "has", "not", "you", "your",
        "bir", "ve", "ile", "için", "icin", "bu", "şu", "su", "olan", "olarak", "çok", "cok", "ama", "de", "da", "mi",
    };

    /// <summary>Content words of a text, lowercased without diacritics, so "arayüzü" and "arayuzu" are one word.</summary>
    public static HashSet<string> Tokens(string text)
    {
        var words = new HashSet<string>(StringComparer.Ordinal);
        var current = new StringBuilder();
        foreach (var character in text.Normalize(NormalizationForm.FormD).ToLowerInvariant() + " ")
        {
            if (char.GetUnicodeCategory(character) == System.Globalization.UnicodeCategory.NonSpacingMark) continue;
            if (char.IsLetterOrDigit(character)) { current.Append(character == 'ı' ? 'i' : character); continue; }
            if (current.Length >= 3 && !StopWords.Contains(current.ToString())) words.Add(current.ToString());
            current.Clear();
        }
        return words;
    }

    /// <summary>One line, credentials masked, bounded.</summary>
    public static string Clean(string? text, int limit)
    {
        var value = Regex.Replace(PromptAssembly.Mask(text ?? ""), @"\s+", " ").Trim();
        return value.Length <= limit ? value : value[..limit];
    }

    /// <summary>
    /// The person's folder for this project: `user-memory/<id>` under the app's support
    /// folder, named by <see cref="ProjectId"/>.
    /// </summary>
    public static string? Folder(string? workspace, string? userRoot)
    {
        if (string.IsNullOrWhiteSpace(workspace) || string.IsNullOrWhiteSpace(userRoot) || !Directory.Exists(workspace)) return null;
        return Path.Combine(userRoot, "user-memory", ProjectId(workspace));
    }

    /// <summary>
    /// The project's one id on every platform: the UUID in the repository's manifest (the id
    /// macOS uses), otherwise a hash of the path until <see cref="EnsureProject"/> writes one.
    /// </summary>
    public static string ProjectId(string workspace) =>
        ManifestId(workspace) ?? Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(workspace))))[..32].ToLowerInvariant();

    private static string ManifestPath(string workspace) => Path.Combine(workspace, ".mem", "manifest.json");

    private static string? ManifestId(string workspace)
    {
        try
        {
            var manifest = ManifestPath(workspace);
            var id = File.Exists(manifest) ? JsonNode.Parse(File.ReadAllText(manifest))?["projectId"]?.GetValue<string>() : null;
            // The id comes from the repository, so it is untrusted: only a UUID may name a folder.
            return Guid.TryParse(id, out _) ? id : null;
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException or InvalidOperationException) { return null; }
    }

    /// <summary>
    /// Writes the manifest macOS writes on a project's first prompt, so every platform names
    /// the person's folder by the same id, then moves what was kept under the path hash (and
    /// the profile entries keyed by the path or the hash) to that id. A manifest that exists
    /// without a usable id, or a linked `.mem`, is left alone.
    /// </summary>
    public static void EnsureProject(string workspace, string userRoot)
    {
        if (!Directory.Exists(workspace) || !IsProjectFolder(workspace)) return;
        var hash = "";
        var id = Guid.NewGuid().ToString().ToUpperInvariant();
        lock (Gate)
        {
            var manifest = ManifestPath(workspace);
            var memory = Path.GetDirectoryName(manifest)!;
            if (File.Exists(manifest) || (Directory.Exists(memory) && new DirectoryInfo(memory).LinkTarget is not null)) return;
            hash = ProjectId(workspace);
            try
            {
                Directory.CreateDirectory(memory);
                WorkspaceLessons.WriteAtomic(manifest, new JsonObject
                {
                    ["schemaVersion"] = 1,
                    ["projectId"] = id,
                    ["createdAt"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                }.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
                var from = Path.Combine(userRoot, "user-memory", hash);
                var to = Path.Combine(userRoot, "user-memory", id);
                if (Directory.Exists(from) && !Directory.Exists(to)) Directory.Move(from, to);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return; }
        }
        // Outside the lock: the profile has its own.
        WorkspaceLessons.RenameProject(userRoot, [Path.GetFullPath(workspace), hash], id);
    }

    public static InsightFile Read(string? workspace, string? userRoot)
    {
        if (Folder(workspace, userRoot) is not { } folder) return new InsightFile();
        lock (Gate)
        {
            try { return JsonSerializer.Deserialize<InsightFile>(File.ReadAllText(Path.Combine(folder, "insights.json")), Json) ?? new InsightFile(); }
            catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { return new InsightFile(); }
        }
    }

    private static void Save(string folder, InsightFile file)
    {
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(folder);
                WorkspaceLessons.WriteAtomic(Path.Combine(folder, "insights.json"), JsonSerializer.Serialize(file, Json));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    // MARK: finished tasks

    private sealed record TaskNote(string Id, string Status, string Completed, string Request, string Outcome, List<string> Files, List<string> Calls);

    /// <summary>
    /// Notes one finished run for the next scan and later recall: a bounded request and
    /// outcome, the files changed and the calls made. Only runs that used a tool are noted.
    /// </summary>
    public static void RecordTask(
        string? workspace, string? userRoot, string runId, string prompt, string? finalText, string outcome,
        IEnumerable<string> changedFiles, IEnumerable<string> calls, string? controlText = null)
    {
        // A call arrives as "✓ name `what it asked for`" or "✕ ..."; one still running ("→ ...")
        // never finished. What the call printed is the conversation, not memory, and is not here.
        var callList = new List<string>();
        var names = new List<string>();
        foreach (var call in calls.Select(call => call.Trim()))
        {
            if (!call.StartsWith('✓') && !call.StartsWith('✕')) continue;
            var name = Clean(call[1..], 200);
            if (name.Length == 0) continue;
            names.Add(name.Split(' ', 2)[0]);
            // The note lists a run of the same call once; the counts below keep every call.
            var entry = name + (call.StartsWith('✕') ? " [FAILED]" : "");
            if (callList.LastOrDefault() != entry) callList.Add(entry);
        }
        if (Folder(workspace, userRoot) is not { } folder || string.IsNullOrWhiteSpace(runId) || callList.Count == 0) return;
        CountTools(folder, names);
        callList = callList.Take(30).ToList();
        var status = outcome != "completed" ? "failed" : WorkspaceBacklog.OpenItems(controlText ?? finalText).Count == 0 ? "completed" : "unfinished";
        var note = new TaskNote(runId, status, DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"), Clean(prompt, 240), Clean(WorkspaceBacklog.VisibleText(finalText), 600),
            changedFiles.Select(SafePath).Where(path => path.Length > 0).Distinct(StringComparer.Ordinal).Take(40).ToList(), callList);
        try
        {
            Directory.CreateDirectory(Path.Combine(folder, "tasks"));
            WorkspaceLessons.WriteAtomic(Path.Combine(folder, "tasks", runId + ".json"), JsonSerializer.Serialize(note, Json));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>Every retained task note on disk, oldest first; scan status does not affect later recall.</summary>
    private static List<TaskNote> TaskNotes(string folder)
    {
        var tasks = Path.Combine(folder, "tasks");
        if (!Directory.Exists(tasks)) return [];
        var notes = new List<TaskNote>();
        foreach (var path in Directory.EnumerateFiles(tasks, "*.json").OrderBy(File.GetLastWriteTimeUtc))
        {
            try { if (JsonSerializer.Deserialize<TaskNote>(File.ReadAllText(path), Json) is { } note) notes.Add(note); }
            catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { }
        }
        return notes;
    }

    /// <summary>
    /// One call as the scan reads it: the tool and what was asked of it - the command, the
    /// path, the query - never what it returned. `running` is the row's text while the
    /// call runs: "→ name", then the argument on the next line.
    /// </summary>
    public static string CallSummary(string name, string running)
    {
        var lines = running.Split('\n', 2);
        var detail = lines.Length > 1 ? Clean(lines[1], 160) : "";
        return detail.Length == 0 || detail == name ? name : $"{name} `{detail}`";
    }

    private static List<TaskNote> UnscannedTasks(string folder, InsightFile file) =>
        TaskNotes(folder).Where(note => !file.ScannedRuns.Contains(note.Id)).ToList();

    /// <summary>
    /// How often each tool was called and in how many tasks: all that is ever read of the
    /// calls of finished work, so only the counts are kept (macOS folds its activity log
    /// into the same counts).
    /// </summary>
    public sealed record ToolUse(string Name, int Calls, int Tasks);

    private static string ToolsPath(string folder) => Path.Combine(folder, "tools.json");

    public static IReadOnlyList<ToolUse> ToolUses(string? workspace, string? userRoot)
    {
        if (Folder(workspace, userRoot) is not { } folder) return [];
        try { return JsonSerializer.Deserialize<List<ToolUse>>(File.ReadAllText(ToolsPath(folder)), Json) ?? []; }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { return []; }
    }

    private static void CountTools(string folder, IReadOnlyList<string> names)
    {
        lock (Gate)
        {
            List<ToolUse> uses;
            try { uses = JsonSerializer.Deserialize<List<ToolUse>>(File.ReadAllText(ToolsPath(folder)), Json) ?? []; }
            catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { uses = []; }
            foreach (var group in names.GroupBy(name => name, StringComparer.Ordinal))
            {
                var known = uses.FirstOrDefault(use => use.Name == group.Key) ?? new ToolUse(group.Key, 0, 0);
                uses.Remove(known);
                uses.Add(known with { Calls = known.Calls + group.Count(), Tasks = known.Tasks + 1 });
            }
            try
            {
                Directory.CreateDirectory(folder);
                WorkspaceLessons.WriteAtomic(ToolsPath(folder), JsonSerializer.Serialize(uses.OrderBy(use => use.Name, StringComparer.Ordinal).ToList(), Json));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    /// <summary>
    /// Up to three earlier tasks whose notes are kept, best term overlap first and
    /// newest first among equals. Only tasks sharing a word are included. Each is one compact
    /// entry - the request, the files and the outcome.
    /// </summary>
    public static string RelevantTasks(string? workspace, string? userRoot, string prompt)
    {
        if (Folder(workspace, userRoot) is not { } folder) return "";
        var terms = Tokens(prompt);
        var scored = TaskNotes(folder).Select(note =>
        {
            var entry = $"- {(note.Completed.Length >= 10 ? note.Completed[..10] : note.Completed)} [{note.Status}] {note.Request} (task {note.Id})";
            if (note.Files.Count > 0) entry += "\n  Files: " + string.Join(", ", note.Files.Take(8));
            if (note.Outcome.Length > 0) entry += "\n  Result: " + Clean(note.Outcome, 600);
            return (Score: terms.Intersect(Tokens(note.Request + " " + note.Outcome + " " + string.Join(" ", note.Files))).Count(), note.Completed, Entry: entry);
        }).ToList();
        var matched = scored.Where(item => item.Score > 0).ToList();
        return string.Join("\n", matched
            .OrderByDescending(item => item.Score).ThenByDescending(item => item.Completed, StringComparer.Ordinal)
            .Take(3).Select(item => item.Entry));
    }

    /// <summary>
    /// The words of each earlier request, by the files that request changed: "the payment
    /// flow" then finds `paytr.ts`, which its name alone never would.
    /// </summary>
    public static Dictionary<string, HashSet<string>> TaskFileTerms(string? workspace, string? userRoot)
    {
        var terms = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
        if (Folder(workspace, userRoot) is not { } folder) return terms;
        foreach (var note in TaskNotes(folder))
        {
            var words = Tokens(note.Request);
            foreach (var file in note.Files)
            {
                if (!terms.TryGetValue(file, out var known)) terms[file] = known = new HashSet<string>(StringComparer.Ordinal);
                known.UnionWith(words);
            }
        }
        return terms;
    }

    /// <summary>A finding the person corrected by hand. An empty text is refused; use Forget.</summary>
    public static bool EditInsight(string? workspace, string? userRoot, string id, string text)
    {
        text = Clean(text, 240);
        if (Folder(workspace, userRoot) is not { } folder || text.Length == 0) return false;
        var file = Read(workspace, userRoot);
        if (file.Insights.FirstOrDefault(item => item.Id == id) is not { } known) return false;
        known.Text = text;
        known.UpdatedAt = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
        known.Source = MemoryInsight.UserSource;
        Save(folder, file);
        return true;
    }

    /// <summary>A finding the person stated directly, through the memory chat.</summary>
    public static bool AddInsight(string? workspace, string? userRoot, string kind, string text)
    {
        text = Clean(text, 240);
        if (Folder(workspace, userRoot) is not { } folder || text.Length == 0 || !Kinds.Contains(kind)) return false;
        var file = Read(workspace, userRoot);
        file.Insights.Add(new MemoryInsight
        {
            Id = Guid.NewGuid().ToString("N")[..8], Kind = kind, Text = text, Strength = 1,
            UpdatedAt = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"), Source = MemoryInsight.UserSource,
        });
        Save(folder, file);
        return true;
    }

    public static bool ForgetInsight(string? workspace, string? userRoot, string id)
    {
        if (Folder(workspace, userRoot) is not { } folder) return false;
        var file = Read(workspace, userRoot);
        if (file.Insights.RemoveAll(item => item.Id == id) == 0) return false;
        Save(folder, file);
        return true;
    }

    /// <summary>
    /// True when the interval has passed and there is finished work no scan has read.
    /// With nothing new, no model is called however long it has been.
    /// </summary>
    public static bool ScanDue(string? workspace, string? userRoot, TimeSpan interval, DateTime? now = null)
    {
        if (Folder(workspace, userRoot) is not { } folder) return false;
        var file = Read(workspace, userRoot);
        if (UnscannedTasks(folder, file).Count == 0) return false;
        return !DateTime.TryParse(file.LastScan, null, System.Globalization.DateTimeStyles.AdjustToUniversal, out var last)
            || (now ?? DateTime.UtcNow) - last >= interval;
    }

    private static string Known(InsightFile file) =>
        file.Insights.Count == 0 ? "None" : string.Join("\n", file.Insights.Select(item => $"- {item.Id} [{item.Kind}] {item.Text}"));

    /// <summary>The next batch for the model: the tasks' ids and the text describing them.</summary>
    public static (IReadOnlyList<string> RunIds, string Payload)? NextScanBatch(string? workspace, string? userRoot)
    {
        if (Folder(workspace, userRoot) is not { } folder) return null;
        var file = Read(workspace, userRoot);
        var notes = UnscannedTasks(folder, file).Take(ScanBatch).ToList();
        if (notes.Count == 0) return null;
        var tasks = notes.Select(note => string.Join("\n",
            $"### Task {note.Id} [{note.Status}] {(note.Completed.Length >= 10 ? note.Completed[..10] : note.Completed)}",
            $"Request: {note.Request}",
            $"Outcome: {note.Outcome}",
            "Changed files:\n" + string.Join("\n", note.Files.Select(path => $"- {path}")),
            "Calls:\n" + string.Join("\n", note.Calls.Select(call => $"- {call}"))));
        return (notes.Select(note => note.Id).ToList(),
            $"## Known findings\n{Known(file)}\n\n## Finished tasks\n\n" + string.Join("\n\n", tasks));
    }

    /// <summary>A path inside the project, or nothing: the model may not point memory outside it.</summary>
    private static string SafePath(string path)
    {
        var value = Clean(path, 300).Replace('\\', '/');
        return value.StartsWith('/') || value.Contains("..") || value.Contains(':') ? "" : value;
    }

    private static JsonObject? ReplyObject(string reply)
    {
        var start = reply.IndexOf('{');
        var end = reply.LastIndexOf('}');
        if (start < 0 || end <= start) return null;
        try { return JsonNode.Parse(reply[start..(end + 1)]) as JsonObject; }
        catch (JsonException) { return null; }
    }

    private static string Text(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : "";

    private static List<string> Strings(JsonNode? node, int limit) =>
        node is JsonArray array
            ? array.Select(item => Clean(Text(item), limit)).Where(item => item.Length > 0).Take(8).ToList()
            : [];

    /// <summary>Every id the reply lists, uncapped: a reply that would drop too much must be seen whole.</summary>
    private static HashSet<string> Ids(JsonNode? node) =>
        node is JsonArray array ? array.Select(Text).Where(id => id.Length > 0).ToHashSet(StringComparer.Ordinal) : [];

    /// <summary>A text without case or diacritics, to tell when two findings say the same words.</summary>
    private static string Folded(string text) => new(text.Normalize(NormalizationForm.FormD).ToLowerInvariant()
        .Where(character => char.GetUnicodeCategory(character) != System.Globalization.UnicodeCategory.NonSpacingMark).ToArray());

    /// <summary>
    /// Folds the model's reply into the findings and marks the batch as read. A reply
    /// that is not the asked JSON changes nothing, so the same tasks are tried again at
    /// the next scan.
    /// </summary>
    public static bool ApplyScan(string? workspace, string? userRoot, string reply, IReadOnlyList<string> runIds, DateTime? now = null)
    {
        if (Folder(workspace, userRoot) is not { } folder) return false;
        if (ReplyObject(reply) is not { } root || root["insights"] is not JsonArray rows) return false;
        var file = Read(workspace, userRoot);
        var stamp = (now ?? DateTime.UtcNow).ToString("yyyy-MM-ddTHH:mm:ssZ");
        foreach (var row in rows.OfType<JsonObject>())
        {
            var text = Clean(Text(row["text"]), 240);
            var kind = Text(row["kind"]);
            if (!Kinds.Contains(kind) || text.Length == 0) continue;
            var files = Strings(row["files"], 300).Select(SafePath).Where(path => path.Length > 0).ToList();
            var tools = Strings(row["tools"], 80);
            var keywords = Strings(row["keywords"], 40).Select(word => word.ToLowerInvariant()).ToList();
            // The model may only name tasks it was shown in this batch.
            var runs = Strings(row["runs"], 60).Where(runIds.Contains).ToList();
            // Met again: the known finding is strengthened, by its id or by saying the same thing.
            var id = Text(row["id"]);
            var known = file.Insights.FirstOrDefault(item => id.Length > 0 && item.Id == id)
                ?? file.Insights.FirstOrDefault(item => item.Kind == kind && Folded(item.Text) == Folded(text));
            if (known is not null)
            {
                // A rule keeps its words; meeting it again only strengthens it.
                if (!known.IsRule)
                {
                    known.Text = text;
                    known.Kind = kind;
                }
                known.Files = known.Files.Union(files).ToList();
                known.Tools = known.Tools.Union(tools).ToList();
                known.Keywords = known.Keywords.Union(keywords).Take(MaxKeywords).ToList();
                known.Runs = known.Runs.Union(runs).ToList();
                known.Strength += 1;
                known.UpdatedAt = stamp;
            }
            else
            {
                file.Insights.Add(new MemoryInsight
                {
                    Id = Guid.NewGuid().ToString("N")[..8], Kind = kind, Text = text,
                    Files = files, Tools = tools, Keywords = keywords, Runs = runs, Strength = 1, UpdatedAt = stamp,
                });
            }
        }
        // A reply that would drop more than half is not believed, as in consolidation.
        var dropped = Ids(root["drop"]);
        dropped.IntersectWith(file.Insights.Where(item => !item.IsRule).Select(item => item.Id));
        if (dropped.Count * 2 <= file.Insights.Count) file.Insights.RemoveAll(item => dropped.Contains(item.Id));
        // Past the cap the weakest go first, and among equals the ones not met for longest.
        // Rules are never counted out.
        if (file.Insights.Count > MaxInsights)
        {
            var ranked = file.Insights.OrderByDescending(item => item.Strength)
                .ThenByDescending(item => item.UpdatedAt, StringComparer.Ordinal).ToList();
            var rules = ranked.Where(item => item.IsRule).ToList();
            file.Insights = rules.Concat(ranked.Where(item => !item.IsRule).Take(Math.Max(0, MaxInsights - rules.Count))).ToList();
        }
        // Keep the compact task note as source evidence. The scan is a helpful index,
        // not the only copy of a decision or its reason.
        file.ScannedRuns = file.ScannedRuns.Union(runIds).ToList();
        file.LastScan = stamp;
        Save(folder, file);
        return true;
    }

    // MARK: recall

    /// <summary>
    /// The findings a request carries. They are few and short, so while they fit the budget
    /// all of them go, in an order the request does not change: a request in other words or
    /// another language than a finding still meets it, and the text is the same from one
    /// request to the next. Past the budget the findings the request names go first - scored
    /// by the words they share, in text, files, tools or keywords, a word few findings use
    /// counting for more and a word matching a longer form of itself ("hafıza" finds
    /// "hafızada") - then the decisions, then the strongest: whole lines until the budget is
    /// full. What is left out the model can still reach with `recall`, in words of its own.
    /// </summary>
    public static string Text(string? workspace, string? userRoot, string prompt)
    {
        var all = Sorted(workspace, userRoot);
        if (all.Sum(item => Line(item).Length + 1) <= InsightBudget) return string.Join("\n", all.Select(Line));
        var scored = Ranked(all, prompt);
        var used = 0;
        var kept = scored.Concat(all.Where(item => !scored.Contains(item))).Select(Line)
            .TakeWhile(line => (used += line.Length + 1) <= InsightBudget)
            .ToList();
        return string.Join("\n", kept.Append($"[{all.Count - kept.Count} weaker findings not shown; search them with {RecallTool.Name}]"));
    }

    /// <summary>Findings and concise task outcomes that share words with the recall query.</summary>
    public static string Recall(string? workspace, string? userRoot, string query)
    {
        var findings = string.Join("\n", Ranked(Sorted(workspace, userRoot), query).Take(RecallLimit).Select(Line));
        var tasks = RelevantTasks(workspace, userRoot, query);
        return string.Join("\n\n", new[]
        {
            findings.Length == 0 ? "" : "Findings:\n" + findings,
            tasks.Length == 0 ? "" : "Earlier task outcomes:\n" + tasks,
        }.Where(section => section.Length > 0));
    }

    private static List<MemoryInsight> Sorted(string? workspace, string? userRoot) => Read(workspace, userRoot).Insights
        .OrderByDescending(item => item.Kind == "decision")
        .ThenByDescending(item => item.Strength)
        .ThenByDescending(item => item.UpdatedAt, StringComparer.Ordinal)
        .ToList();

    private static string Line(MemoryInsight item) =>
        $"- [{item.Kind}] {item.Text}" + (item.Files.Count == 0 ? "" : $" ({string.Join(", ", item.Files.Take(4))})");

    /// <summary>The findings sharing a word with `text`, best first; the ones sharing none are left out.</summary>
    private static List<MemoryInsight> Ranked(List<MemoryInsight> all, string text)
    {
        var terms = Tokens(text);
        static bool Matches(string term, string token) =>
            term == token || (Math.Min(term.Length, token.Length) >= 5 && (term.StartsWith(token, StringComparison.Ordinal) || token.StartsWith(term, StringComparison.Ordinal)));
        var indexed = all.Select(item => (Insight: item, Tokens: Tokens(string.Join(" ", item.Files.Concat(item.Tools).Concat(item.Keywords).Prepend(item.Text))))).ToList();
        // How many findings each of the request's words is found in.
        var spread = terms.ToDictionary(term => term, term => indexed.Count(item => item.Tokens.Any(token => Matches(term, token))));
        return indexed
            .Select(item => (item.Insight, Score: terms.Where(term => item.Tokens.Any(token => Matches(term, token)))
                .Sum(term => 1 + Math.Log((double)all.Count / Math.Max(1, spread[term])))))
            .Where(item => item.Score > 0)
            .OrderByDescending(item => item.Score * 4 + Math.Min(item.Insight.Strength, 5))
            .ThenByDescending(item => item.Insight.UpdatedAt, StringComparer.Ordinal)
            .Select(item => item.Insight)
            .ToList();
    }

    /// <summary>
    /// What is recalled for one request: the findings that bear on it and the repository's
    /// files named like it. Empty for a request that matches nothing.
    /// </summary>
    public static string HistoryText(string? workspace, string? userRoot, string prompt, bool memoryEnabled = true)
    {
        if (string.IsNullOrWhiteSpace(workspace) || string.IsNullOrWhiteSpace(prompt)) return "";
        // The source graph is not personal memory. When memory is off, query only code nodes;
        // decisions, lessons and user preferences stay out. A stale or uncertain graph falls
        // back to the established file-name index, which also works with memory switched off.
        var code = WorkspaceCodeGraph.Text(workspace, userRoot, prompt, includeMemory: memoryEnabled)
            ?? WorkspaceFileIndex.Text(workspace, prompt, memoryEnabled ? userRoot : null);
        if (!memoryEnabled) return code;
        var known = Text(workspace, userRoot, prompt);
        var tasks = RelevantTasks(workspace, userRoot, prompt);
        return string.Join("\n\n", new[]
        {
            known.Length == 0 ? "" : "## What earlier work in this project taught\nFindings recalled for this request. Trust the code over them when the two disagree.\n" + known,
            code,
            tasks.Length == 0 ? "" : "## Relevant task history\n" + tasks,
        }.Where(section => section.Length > 0));
    }

    // MARK: study

    /// <summary>
    /// A folder that is a project, not the home folder, a volume or a temporary directory:
    /// the background work studies nothing in those.
    /// </summary>
    public static bool IsProjectFolder(string workspace)
    {
        var path = Path.GetFullPath(workspace).TrimEnd(Path.DirectorySeparatorChar);
        var temporary = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar);
        return path.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries).Length >= 3
            && path != Environment.GetFolderPath(Environment.SpecialFolder.UserProfile).TrimEnd(Path.DirectorySeparatorChar)
            && !path.StartsWith(temporary, StringComparison.Ordinal)
            && !path.StartsWith("/tmp", StringComparison.Ordinal);
    }

    /// <summary>
    /// The next unread part of the project for the model - its root, then each top-level
    /// folder - as its name and the text describing it. A project no task was run in has
    /// no memory folder and is never read.
    /// ponytail: file names two levels down and the first documents found, not the source.
    /// </summary>
    public static (string Area, string Payload)? NextStudyBatch(string? workspace, string? userRoot)
    {
        if (Folder(workspace, userRoot) is not { } folder || !Directory.Exists(folder) || !IsProjectFolder(workspace!)) return null;
        var file = Read(workspace, userRoot);
        var studied = (file.Studied ?? []).ToHashSet(StringComparer.Ordinal);
        var scanned = NativeWorkspaceTools.ScanFiles(workspace!).Select(path =>
            Path.GetRelativePath(workspace!, path).Replace(Path.DirectorySeparatorChar, '/'))
            .Take(3_000).ToList();
        var folders = scanned.Where(path => path.Contains('/'))
            .Select(path => path[..path.IndexOf('/')])
            .Distinct(StringComparer.Ordinal)
            .OrderBy(name => name, StringComparer.Ordinal)
            .Take(StudyAreas).ToArray();
        var area = folders.Prepend(StudyRoot).FirstOrDefault(name => !studied.Contains(name));
        if (area is null) return null;

        var isRoot = area == StudyRoot;
        var areaDepth = isRoot ? 0 : area.Count(character => character == '/') + 1;
        var names = new List<string>();
        var documents = new List<string>();
        foreach (var path in scanned)
        {
            if (names.Count >= 150) break;
            var parts = path.Split('/');
            var partDepth = parts.Length - areaDepth;
            if (isRoot ? partDepth != 1 : !path.StartsWith(area + "/", StringComparison.Ordinal) || partDepth < 1 || partDepth > 3) continue;
            names.Add(path);
            var name = parts[^1];
            var lower = name.ToLowerInvariant();
            if ((partDepth == 1 && lower.EndsWith(".md", StringComparison.Ordinal)) || lower.StartsWith("readme", StringComparison.Ordinal)
                || WorkspaceStack.IsManifest(name) || name == "Makefile")
                documents.Add(Path.Combine(workspace!, path.Replace('/', Path.DirectorySeparatorChar)));
        }

        // A part with nothing in it still counts as read, so the study moves on.
        var sections = new List<string>
        {
            $"## Part: {(isRoot ? "the project root" : area + "/")}",
            "## Files\n" + string.Join("\n", names.Select(name => $"- {name}")),
        };
        if (isRoot)
        {
            var commits = WorkspaceFileIndex.Git(workspace!, "log", "-n", "40", "--pretty=%s");
            if (commits.Count > 0) sections.Add("## Recent commits\n" + string.Join("\n", commits.Select(subject => $"- {Clean(subject, 160)}")));
        }
        // Shallowest first: a part's own README says more than one three folders down.
        foreach (var document in documents.OrderBy(path => path.Count(character => character is '/' or '\\')).Take(StudyDocuments))
        {
            try
            {
                if (new FileInfo(document).Length >= 400_000) continue;
                sections.Add($"## {Path.GetRelativePath(workspace!, document).Replace('\\', '/')}\n{Clean(File.ReadAllText(document), 3_000)}");
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        return (area, $"## Known findings\n{Known(file)}\n\n" + string.Join("\n\n", sections));
    }

    /// <summary>
    /// Folds the model's reply into the findings and marks the part as read. The part is
    /// marked whatever the reply says: a model that cannot answer for it is not asked again.
    /// </summary>
    public static void ApplyStudy(string? workspace, string? userRoot, string reply, string area)
    {
        if (Folder(workspace, userRoot) is not { } folder) return;
        var lastScan = Read(workspace, userRoot).LastScan;
        ApplyScan(workspace, userRoot, reply, []);
        var file = Read(workspace, userRoot);
        file.Studied = (file.Studied ?? []).Append(area).Distinct(StringComparer.Ordinal).ToList();
        // A study is not a scan of finished tasks, and must not put that one off.
        file.LastScan = lastScan;
        Save(folder, file);
    }

    // MARK: consolidation

    /// <summary>
    /// Every finding, for the model to consolidate, once enough new ones have been added.
    /// Rules are not shown: they are never merged, reworded or dropped.
    /// </summary>
    public static string? ConsolidationPayload(string? workspace, string? userRoot)
    {
        var file = Read(workspace, userRoot);
        if (file.Insights.Count < (file.ConsolidatedCount ?? 0) + ConsolidationStep) return null;
        var open = file.Insights.Where(item => !item.IsRule).ToList();
        if (open.Count == 0) return null;
        return "## Findings\n" + string.Join("\n", open.Select(item =>
            $"- {item.Id} [{item.Kind}] met {item.Strength}x, last {(item.UpdatedAt.Length >= 10 ? item.UpdatedAt[..10] : item.UpdatedAt)}: {item.Text}"
            + $" {{keywords: {string.Join(", ", item.Keywords)}}}"));
    }

    /// <summary>
    /// Folds the model's reply into the findings. Only a known finding can be rewritten and
    /// nothing is added. A reply that would drop more than half is not believed. The count
    /// is noted whatever the reply says, so the model is asked again only after more is learned.
    /// </summary>
    public static void ApplyConsolidation(string? workspace, string? userRoot, string reply)
    {
        if (Folder(workspace, userRoot) is not { } folder) return;
        var file = Read(workspace, userRoot);
        if (ReplyObject(reply) is { } root)
        {
            var rows = (root["insights"] as JsonArray ?? []).OfType<JsonObject>().ToList();
            var rewritten = rows.Select(row => Text(row["id"])).ToHashSet(StringComparer.Ordinal);
            var open = file.Insights.Where(item => !item.IsRule).ToList();
            var dropped = Ids(root["drop"]).Where(id => !rewritten.Contains(id) && open.Any(item => item.Id == id))
                .ToHashSet(StringComparer.Ordinal);
            if (dropped.Count * 2 <= open.Count)
            {
                foreach (var row in rows)
                {
                    var text = Clean(Text(row["text"]), 240);
                    if (text.Length == 0 || open.FirstOrDefault(item => item.Id == Text(row["id"])) is not { } known) continue;
                    known.Text = text;
                    if (Kinds.Contains(Text(row["kind"]))) known.Kind = Text(row["kind"]);
                    known.Keywords = known.Keywords.Union(Strings(row["keywords"], 40).Select(word => word.ToLowerInvariant())).Take(MaxKeywords).ToList();
                }
                file.Insights.RemoveAll(item => dropped.Contains(item.Id));
            }
        }
        file.ConsolidatedCount = file.Insights.Count;
        Save(folder, file);
    }
}

/// <summary>
/// The reading side of memory: a search of findings and retained task outcomes the prompt had no room for.
/// Mirrors RecallTool in macos/DotsHarness/Sources/DotsHarnessCore/RememberTool.swift.
/// </summary>
public static class RecallTool
{
    public const string Name = "recall";

    public const string MalformedNotice = "That call was not usable. Send a query of a few words. Continue with the work either way.";
    public const string UnavailableNotice = "Workspace memory is not available here. Continue from the code; do not retry.";
    public const string EmptyNotice = "No finding or task outcome matches. Continue from the code; do not retry with the same words.";

    public static NativeToolDefinition Definition { get; } = new(
        Name,
        "Search what earlier work in this project taught - decisions, errors, lessons, task outcomes and where each concern "
        + "lives - when <task_history> does not cover the request or says some findings were not shown. "
        + "Use the words the finding would use: name the concern, the file or the command, in English or the "
        + "user's language. Read-only, and only this project's memory.",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["query"] = new JsonObject
                {
                    ["type"] = "string",
                    ["description"] = "A few words naming what to find, e.g. \"build command\", \"login screen\", \"cache\".",
                },
            },
            ["required"] = new JsonArray("query"),
        });

    public static string Execute(string? workspace, string? userRoot, string arguments, bool memoryEnabled)
    {
        string query;
        try { query = (JsonNode.Parse(arguments)?["query"]?.GetValue<string>() ?? "").Trim(); }
        catch (Exception error) when (error is JsonException or InvalidOperationException) { query = ""; }
        if (query.Length == 0) return MalformedNotice;
        if (!memoryEnabled || WorkspaceInsights.Folder(workspace, userRoot) is null) return UnavailableNotice;
        var found = WorkspaceInsights.Recall(workspace, userRoot, query);
        return found.Length == 0 ? EmptyNotice : $"Memory matching \"{query}\". Trust the code over it when the two disagree.\n{found}";
    }
}
