// Copyright (c) 2026 DOTS
// Durable project facts: the values that do not change between runs - the
// backend address, the VPS host, a settled project choice, a lasting user
// preference. The model writes them with the `remember` tool; they are read
// back into every later prompt, so the next conversation starts knowing them.
//
// The store is <workspace>/.mem/facts.md: one file, keyed lines, readable and
// editable by hand. A credential never belongs here - the file is committed
// with the repository - so secret-shaped facts are refused, see IsSecret.
//
// Mirrors macos/DotsHarness/Sources/DotsHarnessCore/RememberTool.swift.

using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace DotsHarnessCore;

public sealed record WorkspaceFact(string Kind, string Key, string Text);

public static class WorkspaceFacts
{
    public const string Name = "remember";

    public static readonly string[] Kinds = ["project", "preference", "decision"];

    public const int MaxTextLength = 240;
    public const int MaxKeyLength = 60;

    /// <summary>A vault this long is a context leak, not a memory.</summary>
    public const int MaxFacts = 60;

    public const string Description =
        "Record something that must outlive this conversation: a value that never changes (the backend "
        + "address, the VPS host, a port, a region), a lasting user preference (\"always reply in Turkish\"), "
        + "or a settled project choice (\"we ship SQLite, not Postgres\"). One call per fact, with a short "
        + "stable key so a later fact on the same subject replaces it instead of piling up. Never record a "
        + "secret - an API key, token, or password - the store is a file committed with the repository; record "
        + "where the secret lives instead. Do not record what the repository already states, what only matters "
        + "to the current request, or anything you inferred rather than were told.";

    public const string MalformedNotice =
        "That call was not usable. Send kind (\"project\", \"preference\" or \"decision\"), a short key naming "
        + "the subject, and a one-sentence text. Continue with the work either way.";

    public const string SecretNotice =
        "Not recorded: that looks like a credential, and this store is a file committed with the repository. "
        + "Keep secrets in the keychain or the environment and record only the non-secret fact - which "
        + "provider, which variable name, where it is stored. Continue with the work.";

    public const string UnavailableNotice =
        "Durable memory is not available here, so nothing was recorded. Continue with the work; do not retry.";

    public static NativeToolDefinition Definition { get; } = new(
        Name,
        Description,
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["kind"] = new JsonObject
                {
                    ["type"] = "string",
                    ["enum"] = new JsonArray("project", "preference", "decision"),
                    ["description"] = "project: a standing fact about the project - an address, a constraint, "
                        + "its goal, what is out of scope. preference: how the user wants work done. "
                        + "decision: a settled project choice.",
                },
                ["key"] = new JsonObject
                {
                    ["type"] = "string",
                    ["description"] = "Short stable subject, e.g. \"backend-url\", \"vps-host\", \"language\".",
                },
                ["text"] = new JsonObject
                {
                    ["type"] = "string",
                    ["description"] = "The fact itself, one sentence, written so it stands alone months later.",
                },
            },
            ["required"] = new JsonArray("kind", "key", "text"),
        });

    /// <summary>Tolerant parse: a malformed call is reported to the model, never fails the run.</summary>
    public static WorkspaceFact? Parse(string arguments)
    {
        JsonNode? node;
        try { node = JsonNode.Parse(arguments); }
        catch (System.Text.Json.JsonException) { return null; }
        var kind = (node?["kind"]?.GetValue<string>() ?? "").Trim().ToLowerInvariant();
        var text = Collapse(node?["text"]?.GetValue<string>() ?? "", MaxTextLength);
        var key = Collapse(node?["key"]?.GetValue<string>() ?? "", MaxKeyLength).ToLowerInvariant();
        if (!Kinds.Contains(kind) || text.Length == 0) return null;
        if (key.Length == 0) key = kind == "decision" ? "decision" : "note";
        return new WorkspaceFact(kind, key, text);
    }

    /// <summary>
    /// Credential shapes, by key name and by value. Deliberately eager: a
    /// refused fact costs a sentence, a committed key costs a rotation.
    /// </summary>
    public static bool IsSecret(WorkspaceFact fact)
    {
        if (Regex.IsMatch(fact.Key, @"api[_-]?key|apikey|secret|token|password|passwd|credential|private[_-]?key",
            RegexOptions.IgnoreCase)) return true;
        string[] values =
        [
            @"\b(sk|pk|rk)[_-][A-Za-z0-9_\-]{16,}",
            @"\b(gh[pousr]|github_pat)_[A-Za-z0-9_]{16,}",
            @"\bAKIA[0-9A-Z]{12,}",
            @"\bxox[abposr]-[A-Za-z0-9-]{10,}",
            @"-----BEGIN [A-Z ]*PRIVATE KEY-----",
            @"(api[_-]?key|token|password|secret)\s*[:=]\s*\S+",
        ];
        return values.Any(pattern => Regex.IsMatch(fact.Text, pattern, RegexOptions.IgnoreCase));
    }

    /// <summary>Writes one fact, replacing any earlier fact with the same kind and key.</summary>
    public static string Record(string? workspace, string arguments)
    {
        var fact = Parse(arguments);
        if (fact is null) return MalformedNotice;
        if (IsSecret(fact)) return SecretNotice;
        var path = StorePath(workspace);
        if (path is null) return UnavailableNotice;

        var facts = Read(workspace).Where(item => item.Kind != fact.Kind || item.Key != fact.Key).ToList();
        facts.Add(fact);
        if (facts.Count > MaxFacts) facts = facts.Skip(facts.Count - MaxFacts).ToList();
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, Render(facts));
        }
        catch (IOException) { return UnavailableNotice; }
        catch (UnauthorizedAccessException) { return UnavailableNotice; }
        return $"Recorded {fact.Kind} {fact.Key}: {fact.Text}";
    }

    public static IReadOnlyList<WorkspaceFact> Read(string? workspace)
    {
        var path = StorePath(workspace);
        if (path is null || !File.Exists(path)) return [];
        string body;
        try { body = File.ReadAllText(path); }
        catch (IOException) { return []; }
        catch (UnauthorizedAccessException) { return []; }

        var facts = new List<WorkspaceFact>();
        var kind = "";
        foreach (var raw in body.Split('\n'))
        {
            var line = raw.TrimEnd('\r').Trim();
            if (line.StartsWith("## ", StringComparison.Ordinal))
            {
                kind = line[3..].Trim().ToLowerInvariant();
                continue;
            }
            if (!line.StartsWith("- ", StringComparison.Ordinal) || kind.Length == 0) continue;
            var separator = line.IndexOf(" — ", StringComparison.Ordinal);
            if (separator < 0) continue;
            var key = line[2..separator].Trim().Trim('`');
            var text = line[(separator + 3)..].Trim();
            if (key.Length > 0 && text.Length > 0) facts.Add(new WorkspaceFact(kind, key, text));
        }
        return facts;
    }

    /// <summary>
    /// The prompt section: what is already known, plus the standing instruction
    /// to record the next such fact. The instruction is always present - without
    /// it a workspace that has recorded nothing never records a first fact.
    /// </summary>
    public static string Text(string? workspace)
    {
        if (StorePath(workspace) is null) return "";
        var facts = Read(workspace);
        var known = facts.Count == 0
            ? "Nothing recorded yet."
            : Render(facts);
        return $"""
            Durable project facts (authoritative unless the user says otherwise)
            {known}
            When the user states a value that will not change - a backend address, a host, a port - a lasting preference, or a settled choice, record it with `{Name}`. One fact per call, with a stable key. Never record a secret. Recording never replaces doing the work now.
            """;
    }

    private static string Render(IReadOnlyList<WorkspaceFact> facts) =>
        string.Join("\n\n", Kinds
            .Select(kind => (Kind: kind, Items: facts.Where(fact => fact.Kind == kind).ToList()))
            .Where(group => group.Items.Count > 0)
            .Select(group => $"## {group.Kind}\n"
                + string.Join("\n", group.Items.Select(fact => $"- {fact.Key} — {fact.Text}")))) + "\n";

    private static string? StorePath(string? workspace) =>
        string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)
            ? null
            : Path.Combine(workspace, ".mem", "facts.md");

    private static string Collapse(string text, int limit)
    {
        var value = Regex.Replace(text, @"\s+", " ").Trim();
        return value.Length <= limit ? value : value[..limit];
    }
}
