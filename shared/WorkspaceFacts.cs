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

public sealed record WorkspaceFact(string Kind, string Key, string Text, string Scope = "project");

public static class WorkspaceFacts
{
    public const string Name = "remember";

    public static readonly string[] Kinds = ["project", "preference", "decision"];

    /// <summary>Scope of a fact that follows the user into every project.</summary>
    public const string UserScope = "user";

    public const int MaxTextLength = 240;

    /// <summary>
    /// Project facts learned from the code rather than told by the user: how it
    /// is laid out, the conventions it follows, the design system its interface
    /// is built from. They describe a codebase, so they may be longer than one
    /// sentence. Mirrors ProjectKnowledge.swift on macOS.
    /// </summary>
    public static readonly string[] KnowledgeKeys = ["architecture", "conventions", "design-system"];
    public const int MaxKnowledgeLength = 1200;
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
                ["scope"] = new JsonObject
                {
                    ["type"] = "string",
                    ["enum"] = new JsonArray("project", "user"),
                    ["description"] = "project (default): holds in this repository. user: describes the user in "
                        + "every project - their language, preferred stack, working style.",
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
        var key = Collapse(node?["key"]?.GetValue<string>() ?? "", MaxKeyLength).ToLowerInvariant();
        var text = Collapse(
            node?["text"]?.GetValue<string>() ?? "",
            kind == "project" && KnowledgeKeys.Contains(key) ? MaxKnowledgeLength : MaxTextLength);
        if (!Kinds.Contains(kind) || text.Length == 0) return null;
        if (key.Length == 0) key = kind == "decision" ? "decision" : "note";
        var scope = (node?["scope"]?.GetValue<string>() ?? "").Trim().ToLowerInvariant() == UserScope
            ? UserScope
            : "project";
        return new WorkspaceFact(kind, key, text, scope);
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

    /// <summary>
    /// Writes one fact, replacing any earlier fact with the same kind and key. A
    /// fact with scope "user" goes to <paramref name="userRoot"/> (the app's
    /// support folder) instead of the repository, so every project reads it.
    /// </summary>
    public static string Record(string? workspace, string arguments, string? userRoot = null)
    {
        var fact = Parse(arguments);
        if (fact is null) return MalformedNotice;
        if (IsSecret(fact)) return SecretNotice;
        var path = fact.Scope == UserScope ? UserStorePath(userRoot) : StorePath(workspace);
        if (path is null) return UnavailableNotice;

        var facts = ReadFile(path).Where(item => item.Kind != fact.Kind || item.Key != fact.Key).ToList();
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

    public static IReadOnlyList<WorkspaceFact> Read(string? workspace) => ReadFile(StorePath(workspace));

    /// <summary>Upserts one project fact while retaining unrelated facts in the shared Markdown file.</summary>
    public static bool SetProject(string? workspace, string key, string text)
    {
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return false;
        key = Collapse(key, MaxKeyLength).ToLowerInvariant();
        text = Collapse(text, KnowledgeKeys.Contains(key) ? MaxKnowledgeLength : MaxTextLength);
        var fact = new WorkspaceFact("project", key, text);
        if (key.Length == 0 || text.Length == 0 || IsSecret(fact)) return false;
        return WriteProjectFacts(workspace, facts =>
        {
            facts.RemoveAll(item => item.Kind == "project" && item.Key == key);
            facts.Add(fact);
        });
    }

    public static bool ForgetProject(string? workspace, string key)
    {
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return false;
        key = Collapse(key, MaxKeyLength).ToLowerInvariant();
        if (key.Length == 0) return false;
        return WriteProjectFacts(workspace, facts => facts.RemoveAll(item => item.Kind == "project" && item.Key == key));
    }

    private static bool WriteProjectFacts(string workspace, Action<List<WorkspaceFact>> update)
    {
        var path = StorePath(workspace)!;
        try
        {
            var facts = ReadFile(path).ToList();
            update(facts);
            var kinds = Kinds.Concat(facts.Select(item => item.Kind).Where(kind => !Kinds.Contains(kind))
                .Distinct(StringComparer.Ordinal).OrderBy(kind => kind, StringComparer.Ordinal));
            var sections = kinds.Select(kind => (Kind: kind, Items: facts.Where(item => item.Kind == kind).ToList()))
                .Where(group => group.Items.Count > 0)
                .Select(group => $"## {group.Kind}\n" + string.Join("\n", group.Items.Select(item => $"- {item.Key} — {item.Text}")));
            var body = string.Join("\n\n", sections);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, body.Length == 0 ? "" : body + "\n");
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    /// <summary>
    /// What is known about the user across all projects. Empty until something
    /// is recorded, and free of dates or counters, so a conversation captures it
    /// once and again only when a fact changes.
    /// </summary>
    public static string UserText(string? userRoot, string? workspace = null)
    {
        var facts = ReadFile(UserStorePath(userRoot));
        var stack = WorkspaceStack.Current(workspace, userRoot);
        var parts = new[]
        {
            facts.Count == 0 ? "" : Render(facts).TrimEnd(),
            WorkspaceStack.UserText(userRoot),
            WorkspaceLessons.SharedUserText(userRoot, workspace, stack),
        }
            .Where(part => part.Length > 0)
            .ToList();
        return parts.Count == 0
            ? ""
            : "What HerNess has learned about this user across all their projects. Apply it without asking "
                + "again; the user's current message and this project's own rules win over it.\n\n"
                + string.Join("\n\n", parts);
    }

    private static IReadOnlyList<WorkspaceFact> ReadFile(string? path)
    {
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
    public static string Text(string? workspace, bool explore = true)
    {
        if (StorePath(workspace) is null) return "";
        var facts = Read(workspace);
        var known = facts.Count == 0
            ? "Nothing recorded yet."
            : Render(facts);
        var missing = KnowledgeKeys
            .Where(key => !facts.Any(fact => fact.Kind == "project" && fact.Key == key))
            .ToList();
        // Asked only while an entry is missing, so a project is studied once.
        var knowledge = missing.Count == 0
            ? ""
            : $"\nNo project fact yet for: {string.Join(", ", missing)}. Before the first real change to this project, learn the missing ones from the code{(explore ? " - delegate the sweep to explore -" : "")} and record each with `{Name}` (kind \"project\", that key) in at most {MaxKnowledgeLength} characters, naming the files it comes from: architecture is the modules and how a request flows through them; conventions is naming, file layout, error handling and how tests are run; design-system is where colors, typography, spacing and shared components are defined, with their names and values (record \"none\" for a project without an interface). Skip this for a one-off question or a trivial edit.";
        return $"""
            Durable project facts (authoritative unless the user says otherwise)
            {known}
            When the user states a value that will not change - a backend address, a host, a port - a lasting preference, or a settled choice, or when work you just finished changed the project for good (a framework or dependency adopted or replaced, a convention introduced), record it with `{Name}`. Use scope "user" for what describes the user in every project (language, preferred stack). One fact per call, with a stable key. Never record a secret. Never ask again for what is recorded here or in <user_memory>. Recording never replaces doing the work now. Interface work reuses the colors, type and components the design-system fact names and never hard-codes a value it defines; when the code disagrees with a recorded fact, record the corrected one under the same key.{knowledge}
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

    private static string? UserStorePath(string? userRoot) =>
        string.IsNullOrWhiteSpace(userRoot) ? null : Path.Combine(userRoot, "user-facts.md");

    private static string Collapse(string text, int limit)
    {
        var value = Regex.Replace(text, @"\s+", " ").Trim();
        return value.Length <= limit ? value : value[..limit];
    }
}

/// <summary>
/// What a project is built with, read from its manifests instead of asked of the
/// user, and which technologies the user's projects share - so a brand new
/// project starts on the stack they already use.
///
/// Mirrors WorkspaceMemory.detectTechnologies and UserProfile.swift on macOS.
/// </summary>
public static class WorkspaceStack
{
    private static readonly HashSet<string> Ignored = new(StringComparer.Ordinal)
    {
        ".git", ".mem", "node_modules", "vendor", "build", "dist", ".build", "bin", "obj", "target", "Pods",
    };

    private static readonly HashSet<string> Manifests = new(StringComparer.Ordinal)
    {
        "pubspec.yaml", "Package.swift", "package.json", "wrangler.toml", "wrangler.json", "wrangler.jsonc",
        "Cargo.toml", "go.mod", "pyproject.toml", "requirements.txt", "build.gradle", "build.gradle.kts",
        "pom.xml", "composer.json", "Gemfile",
    };

    private static readonly Dictionary<string, string> PackageFrameworks = new(StringComparer.Ordinal)
    {
        ["react-native"] = "React Native",
        ["expo"] = "Expo",
        ["next"] = "Next.js",
        ["react"] = "React",
        ["vue"] = "Vue",
        ["nuxt"] = "Nuxt",
        ["svelte"] = "Svelte",
        ["@angular/core"] = "Angular",
        ["hono"] = "Hono",
        ["express"] = "Express",
        ["electron"] = "Electron",
        ["tailwindcss"] = "Tailwind CSS",
    };

    public const int MaxTechnologies = 12;

    private static readonly object Gate = new();
    private static readonly Dictionary<string, (string Listing, IReadOnlyList<string> Stack)> Cache =
        new(StringComparer.Ordinal);

    public static bool IsManifest(string name) =>
        Manifests.Contains(name)
        || name.EndsWith(".csproj", StringComparison.Ordinal)
        || name.EndsWith(".sln", StringComparison.Ordinal);

    /// <summary>
    /// Scans the manifests. Monorepos keep them a level or two down
    /// (mobile/android/), so the walk is breadth-first, two levels, 200
    /// directories at most; a deeper layout is missed until a run touches its
    /// manifest.
    /// </summary>
    public static IReadOnlyList<string> Detect(string? workspace)
    {
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return [];
        var found = new SortedSet<string>(StringComparer.Ordinal);
        var level = new List<string> { workspace };
        var listed = 0;
        for (var depth = 0; depth <= 2; depth++)
        {
            var next = new List<string>();
            foreach (var directory in level)
            {
                if (listed++ >= 200) break;
                foreach (var entry in Entries(directory))
                {
                    var name = Path.GetFileName(entry);
                    if (name.Length == 0 || name[0] == '.') continue;
                    if (Directory.Exists(entry))
                    {
                        if (name.EndsWith(".xcodeproj", StringComparison.Ordinal)) found.Add("Swift");
                        else if (depth < 2 && !Ignored.Contains(name)) next.Add(entry);
                    }
                    else if (IsManifest(name))
                    {
                        foreach (var technology in InManifest(entry)) found.Add(technology);
                    }
                }
            }
            level = next;
        }
        return found.ToList();
    }

    /// <summary>
    /// The stack of a workspace. The root listing is compared on every call; the
    /// scan runs only when that listing changed or <paramref name="rescan"/> says
    /// a finished run touched a manifest. Each scan also updates what this
    /// project contributes to the user's technologies.
    /// </summary>
    public static IReadOnlyList<string> Current(string? workspace, string? userRoot, bool rescan = false)
    {
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return [];
        var listing = string.Join(
            "\n",
            Entries(workspace).Select(entry => Path.GetFileName(entry)).OrderBy(name => name, StringComparer.Ordinal));
        lock (Gate)
        {
            if (!rescan && Cache.TryGetValue(workspace, out var cached) && cached.Listing == listing)
            {
                return cached.Stack;
            }
        }
        var stack = Detect(workspace);
        Record(stack, workspace, userRoot);
        lock (Gate)
        {
            Cache[workspace] = (listing, stack);
        }
        return stack;
    }

    /// <summary>Prompt text for the project. It changes only when the stack does.</summary>
    public static string Text(string? workspace, string? userRoot)
    {
        var stack = Current(workspace, userRoot);
        return stack.Count == 0 ? "" : "Stack, read from this project's manifests: " + string.Join(", ", stack);
    }

    /// <summary>The technologies part of the user memory; no dates, no moving counters.</summary>
    public static string UserText(string? userRoot)
    {
        var ranked = ReadStore(userRoot)
            .Where(pair => pair.Value.Count > 0)
            .OrderByDescending(pair => pair.Value.Count)
            .ThenBy(pair => pair.Key, StringComparer.Ordinal)
            .Take(MaxTechnologies)
            .ToList();
        return ranked.Count == 0
            ? ""
            : "## Technologies the user's projects use (project count)\n"
                + string.Join("\n", ranked.Select(pair => $"- {pair.Key} ({pair.Value.Count})"))
                + "\nWhen a new project leaves the stack open, use the most used one that fits instead of asking.";
    }

    private static string[] Entries(string directory)
    {
        try { return Directory.GetFileSystemEntries(directory); }
        catch (IOException) { return []; }
        catch (UnauthorizedAccessException) { return []; }
    }

    private static string Body(string path)
    {
        try { return File.ReadAllText(path); }
        catch (IOException) { return ""; }
        catch (UnauthorizedAccessException) { return ""; }
    }

    private static IReadOnlyList<string> InManifest(string path)
    {
        switch (Path.GetFileName(path))
        {
            case "pubspec.yaml":
                return [Body(path).Contains("sdk: flutter", StringComparison.Ordinal) ? "Flutter" : "Dart"];
            case "Package.swift": return ["Swift"];
            case "package.json": return Package(Body(path));
            case "wrangler.toml" or "wrangler.json" or "wrangler.jsonc": return ["Cloudflare Workers"];
            case "Cargo.toml": return ["Rust"];
            case "go.mod": return ["Go"];
            case "pyproject.toml" or "requirements.txt": return ["Python"];
            case "build.gradle" or "build.gradle.kts":
                return [Body(path).Contains("com.android", StringComparison.Ordinal) ? "Android" : "JVM (Gradle)"];
            case "pom.xml": return ["Java (Maven)"];
            case "composer.json": return ["PHP"];
            case "Gemfile": return ["Ruby"];
            default: return [".NET"];
        }
    }

    private static IReadOnlyList<string> Package(string body)
    {
        JsonObject? root = null;
        try { root = JsonNode.Parse(body) as JsonObject; }
        catch (System.Text.Json.JsonException) { }
        var names = new List<string>();
        foreach (var section in new[] { "dependencies", "devDependencies" })
        {
            if (root?[section] is JsonObject dependencies) names.AddRange(dependencies.Select(pair => pair.Key));
        }
        var result = new List<string> { names.Contains("typescript") ? "TypeScript" : "JavaScript" };
        result.AddRange(names.Where(PackageFrameworks.ContainsKey).Select(name => PackageFrameworks[name]));
        return result;
    }

    private static string? StorePath(string? userRoot) =>
        string.IsNullOrWhiteSpace(userRoot) ? null : Path.Combine(userRoot, "user-stack.json");

    /// <summary>Technology name to the projects (full paths) that use it.</summary>
    private static Dictionary<string, List<string>> ReadStore(string? userRoot)
    {
        var result = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        var path = StorePath(userRoot);
        if (path is null || !File.Exists(path)) return result;
        try
        {
            if (JsonNode.Parse(File.ReadAllText(path)) is not JsonObject root) return result;
            foreach (var pair in root)
            {
                if (pair.Value is not JsonArray projects) continue;
                result[pair.Key] = projects
                    .Select(item => item?.ToString() ?? "")
                    .Where(item => item.Length > 0)
                    .ToList();
            }
        }
        catch (System.Text.Json.JsonException) { }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        return result;
    }

    /// <summary>
    /// Replaces what this project contributes: a project that moved off a
    /// technology stops counting toward it.
    /// </summary>
    private static void Record(IReadOnlyList<string> technologies, string workspace, string? userRoot)
    {
        var path = StorePath(userRoot);
        if (path is null) return;
        var project = Path.GetFullPath(workspace);
        var store = ReadStore(userRoot);
        var before = Serialize(store);
        foreach (var projects in store.Values) projects.Remove(project);
        foreach (var technology in technologies)
        {
            if (!store.TryGetValue(technology, out var users))
            {
                users = new List<string>();
                store[technology] = users;
            }
            users.Add(project);
        }
        var after = Serialize(store);
        if (after == before) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, after);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static string Serialize(Dictionary<string, List<string>> store)
    {
        var root = new JsonObject();
        foreach (var pair in store.Where(pair => pair.Value.Count > 0).OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            root[pair.Key] = new JsonArray(pair.Value
                .OrderBy(item => item, StringComparer.Ordinal)
                .Select(item => (JsonNode?)JsonValue.Create(item))
                .ToArray());
        }
        return root.ToJsonString();
    }
}
