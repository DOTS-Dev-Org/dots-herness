// Copyright (c) 2026 DOTS
// A local Tree-sitter graph for project structure and request-specific memory retrieval.

using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using TreeSitter;

namespace DotsHarnessCore;

/// <summary>
/// The JSON shape is shared with macOS ProjectCodeGraph so either desktop can
/// read the other's index. Personal preferences and user profiles are never stored here.
/// </summary>
public static class WorkspaceCodeGraph
{
    private const int SchemaVersion = 3;
    private const string DirectoryName = "code-graph";
    private const string QueryIndexFileName = "query.json";
    private const int MaxFiles = 12_000;
    private const int MaxFileBytes = 300_000;
    private const int MaxSymbolsPerFile = 2_000;
    private const int MaxReferencesPerFile = 20_000;
    private static readonly HashSet<string> Extensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".swift", ".cs", ".ts", ".tsx", ".js", ".jsx", ".py", ".go", ".rs", ".java", ".php", ".rb",
        ".c", ".h", ".cpp", ".cc", ".cxx", ".hpp", ".hh",
    };

    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.Default,
    };

    private static readonly object Gate = new();
    private static readonly Dictionary<string, ProjectGraph> Cache = new(StringComparer.Ordinal);
    private static readonly HashSet<string> Refreshing = new(StringComparer.Ordinal);

    private sealed record FileStamp(
        [property: JsonPropertyName("path")] string Path,
        [property: JsonPropertyName("size")] long Size,
        [property: JsonPropertyName("modifiedAtNanoseconds")] long ModifiedAtNanoseconds);

    private sealed record Node(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("kind")] string Kind,
        [property: JsonPropertyName("name")] string Name,
        [property: JsonPropertyName("path")] string Path,
        [property: JsonPropertyName("line")] int Line,
        [property: JsonPropertyName("language")] string Language,
        [property: JsonPropertyName("signature")] string? Signature);

    private sealed record Edge(
        [property: JsonPropertyName("from")] string From,
        [property: JsonPropertyName("to")] string To,
        [property: JsonPropertyName("relation")] string Relation,
        [property: JsonPropertyName("provenance")] string Provenance,
        [property: JsonPropertyName("confidence")] double Confidence);

    private sealed record Reference(
        [property: JsonPropertyName("from")] string From,
        [property: JsonPropertyName("name")] string Name,
        [property: JsonPropertyName("relation")] string Relation);

    private sealed record ParsedFile(
        [property: JsonPropertyName("stamp")] FileStamp Stamp,
        [property: JsonPropertyName("sha256")] string Sha256,
        [property: JsonPropertyName("nodes")] List<Node> Nodes,
        [property: JsonPropertyName("extractedEdges")] List<Edge> ExtractedEdges,
        [property: JsonPropertyName("references")] List<Reference> References);

    private sealed class ProjectGraph
    {
        [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; set; }
        [JsonPropertyName("generatedAt")] public string GeneratedAt { get; set; } = "";
        [JsonPropertyName("inventoryFingerprint")] public string InventoryFingerprint { get; set; } = "";
        [JsonPropertyName("inventory")] public List<FileStamp> Inventory { get; set; } = [];
        [JsonPropertyName("coverageComplete")] public bool CoverageComplete { get; set; }
        [JsonPropertyName("skippedFiles")] public int SkippedFiles { get; set; }
        [JsonPropertyName("files")] public List<ParsedFile> Files { get; set; } = [];
        [JsonPropertyName("nodes")] public List<Node> Nodes { get; set; } = [];
        [JsonPropertyName("edges")] public List<Edge> Edges { get; set; } = [];
    }

    private sealed record PendingReference(string From, string Name, string Relation);
    private sealed record Finding(string Id, string Kind, string Text, string Evidence, List<string> Paths, int Score, string UpdatedAt);

    /// <summary>
    /// Returns a small, current subgraph or null. Missing or stale graphs refresh in the
    /// background; a partial graph is used only when none of its skipped paths match the query.
    /// </summary>
    public static string? Text(string? workspace, string? userRoot, string prompt, bool includeMemory = true)
    {
        if (string.IsNullOrWhiteSpace(workspace) || string.IsNullOrWhiteSpace(prompt) || !Directory.Exists(workspace)) return null;
        var root = Path.GetFullPath(workspace);
        var directory = Path.Combine(root, ".mem", DirectoryName);
        if (HasUnsafePathComponent(directory, root)) return null;

        ProjectGraph? graph;
        lock (Gate) Cache.TryGetValue(root, out graph);
        graph ??= LoadQueryIndex(directory);
        if (graph is null || !IsCurrent(graph, root))
        {
            lock (Gate) Cache.Remove(root);
            ScheduleRefresh(root, directory, previous: null);
            return null;
        }
        if (graph.SchemaVersion != SchemaVersion) return null;
        lock (Gate) Cache[root] = graph;
        return Query(graph, root, userRoot, prompt, includeMemory);
    }

    private static ProjectGraph? Load(string directory)
    {
        var path = Path.Combine(directory, "graph.json");
        if (HasUnsafePathComponent(path, Path.GetDirectoryName(directory) ?? directory)) return null;
        try
        {
            return File.Exists(path) ? JsonSerializer.Deserialize<ProjectGraph>(File.ReadAllText(path), Json) : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    private static ProjectGraph? LoadQueryIndex(string directory)
    {
        var path = Path.Combine(directory, QueryIndexFileName);
        if (HasUnsafePathComponent(path, Path.GetDirectoryName(directory) ?? directory)) return null;
        try
        {
            return File.Exists(path) ? JsonSerializer.Deserialize<ProjectGraph>(File.ReadAllText(path), Json) : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    private static List<FileStamp> Inventory(string root)
    {
        var output = new List<FileStamp>();
        foreach (var path in NativeWorkspaceTools.ScanFiles(root))
        {
            if (!Extensions.Contains(Path.GetExtension(path))) continue;
            try
            {
                var info = new FileInfo(path);
                if (!info.Exists || info.Length < 0 || IsSymlink(info.FullName)) continue;
                var relative = Path.GetRelativePath(root, info.FullName).Replace(Path.DirectorySeparatorChar, '/');
                var nanos = (info.LastWriteTimeUtc.Ticks - DateTime.UnixEpoch.Ticks) * 100;
                output.Add(new FileStamp(relative, info.Length, nanos));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException) { }
        }
        return output.OrderBy(file => file.Path, StringComparer.Ordinal).ToList();
    }

    private static string Fingerprint(IReadOnlyList<FileStamp> inventory) => Hash(string.Join("\n", inventory.Select(file =>
        $"{file.Path}\t{file.Size}\t{file.ModifiedAtNanoseconds}")));

    private static bool IsCurrent(ProjectGraph graph, string root)
    {
        if (graph.SchemaVersion != SchemaVersion) return false;
        var current = Inventory(root);
        return graph.Inventory.SequenceEqual(current) && graph.InventoryFingerprint == Fingerprint(current);
    }

    private static void ScheduleRefresh(string root, string directory, ProjectGraph? previous)
    {
        lock (Gate)
        {
            if (!Refreshing.Add(root)) return;
        }
        _ = Task.Run(() =>
        {
            try
            {
                var reusable = previous is { Files.Count: > 0 } ? previous : Load(directory);
                var graph = Rebuild(root, reusable);
                if (HasUnsafePathComponent(directory, root)) return;
                Directory.CreateDirectory(directory);
                var jsonPath = Path.Combine(directory, "graph.json");
                var reportPath = Path.Combine(directory, "GRAPH_REPORT.md");
                var htmlPath = Path.Combine(directory, "graph.html");
                var queryIndexPath = Path.Combine(directory, QueryIndexFileName);
                if (HasUnsafePathComponent(jsonPath, root) || HasUnsafePathComponent(queryIndexPath, root)
                    || HasUnsafePathComponent(reportPath, root) || HasUnsafePathComponent(htmlPath, root)) return;
                WorkspaceLessons.WriteAtomic(jsonPath, JsonSerializer.Serialize(graph, Json));
                WorkspaceLessons.WriteAtomic(queryIndexPath, JsonSerializer.Serialize(QueryIndex(graph), Json));
                WorkspaceLessons.WriteAtomic(reportPath, Report(graph));
                WorkspaceLessons.WriteAtomic(htmlPath, Html(graph));
                lock (Gate) Cache[root] = QueryIndex(graph);
            }
            catch (Exception)
            {
                // This graph is optional; parser/runtime/artifact failures must leave the
                // established file-name index available for the current and next request.
            }
            finally { lock (Gate) Refreshing.Remove(root); }
        });
    }

    private static ProjectGraph Rebuild(string root, ProjectGraph? previous)
    {
        var inventory = Inventory(root);
        var old = previous?.SchemaVersion == SchemaVersion
            ? previous.Files.ToDictionary(file => file.Stamp.Path, StringComparer.Ordinal)
            : new Dictionary<string, ParsedFile>(StringComparer.Ordinal);
        var files = new List<ParsedFile>();
        var skipped = 0;
        var complete = inventory.Count <= MaxFiles;

        foreach (var stamp in inventory.Take(MaxFiles))
        {
            if (stamp.Size > MaxFileBytes)
            {
                skipped++;
                complete = false;
                continue;
            }
            try
            {
                var fullPath = Path.Combine(root, stamp.Path.Replace('/', Path.DirectorySeparatorChar));
                var bytes = File.ReadAllBytes(fullPath);
                var digest = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
                if (old.TryGetValue(stamp.Path, out var cached) && cached.Sha256 == digest)
                {
                    files.Add(cached with { Stamp = stamp });
                    continue;
                }
                var source = new UTF8Encoding(false, true).GetString(bytes);
                if (Parse(stamp, digest, source) is { } parsed) files.Add(parsed);
                else { skipped++; complete = false; }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or DecoderFallbackException or ArgumentException)
            {
                skipped++;
                complete = false;
            }
        }

        var nodes = files.SelectMany(file => file.Nodes).ToList();
        var edges = files.SelectMany(file => file.ExtractedEdges).ToList();
        edges.AddRange(Resolve(files, nodes));
        return new ProjectGraph
        {
            SchemaVersion = SchemaVersion,
            GeneratedAt = DateTimeOffset.UtcNow.ToString("O"),
            InventoryFingerprint = Fingerprint(inventory),
            Inventory = inventory,
            CoverageComplete = complete,
            SkippedFiles = skipped,
            Files = files,
            Nodes = nodes,
            Edges = edges,
        };
    }

    private static ParsedFile? Parse(FileStamp stamp, string digest, string source)
    {
        var extension = Path.GetExtension(stamp.Path).ToLowerInvariant();
        var language = LanguageFor(extension);
        if (language is null) return null;
        using var grammar = new Language(language);
        using var parser = new Parser(grammar);
        using var tree = parser.Parse(source);
        if (tree is null) return null;

        var fileId = "file:" + stamp.Path;
        var file = new Node(fileId, "file", Path.GetFileName(stamp.Path), stamp.Path, 1, language, null);
        var nodes = new List<Node> { file };
        var edges = new List<Edge>();
        var references = new List<Reference>();
        var pending = new Stack<(TreeSitter.Node Syntax, string? ParentSymbol)>();
        pending.Push((tree.RootNode, null));
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var seenNodeIds = new HashSet<string>(StringComparer.Ordinal) { fileId };

        while (pending.Count > 0)
        {
            var (syntax, parentSymbol) = pending.Pop();
            var type = syntax.Type ?? "";
            var kind = DeclarationKind(type);
            var currentParent = parentSymbol;
            if (kind is not null && DeclarationName(syntax) is { Length: > 0 } name)
            {
                var line = syntax.StartPosition.Row + 1;
                var identity = $"{line}|{name}|{kind}";
                var id = $"symbol:{stamp.Path}#{line}:{name}:{kind}";
                if (seen.Add(identity) && nodes.Count < MaxSymbolsPerFile + 1 && seenNodeIds.Add(id))
                {
                    nodes.Add(new Node(id, kind, name, stamp.Path, line, language, null));
                    edges.Add(new Edge(currentParent ?? fileId, id, "CONTAINS", "EXTRACTED", 1));
                    currentParent = id;
                }
            }

            if (IsImport(type) && ImportSource(syntax.Text) is { Length: > 0 } importName)
            {
                var line = syntax.StartPosition.Row + 1;
                var importId = $"import:{stamp.Path}#{line}:{importName}";
                if (seenNodeIds.Add(importId))
                {
                    nodes.Add(new Node(importId, "import", importName, stamp.Path, line, language, null));
                    edges.Add(new Edge(fileId, importId, "IMPORTS", "EXTRACTED", 1));
                    if (references.Count < MaxReferencesPerFile) references.Add(new Reference(importId, importName, "RESOLVES_TO"));
                }
            }

            if (IsInheritance(type) && currentParent is not null)
                foreach (var baseName in Identifiers(syntax).Distinct(StringComparer.Ordinal))
                    if (references.Count < MaxReferencesPerFile) references.Add(new Reference(currentParent, baseName, "INHERITS"));

            if (references.Count < MaxReferencesPerFile && IsCall(type) && currentParent is not null && CallName(syntax) is { Length: > 0 } called)
                references.Add(new Reference(currentParent, called, "CALLS"));

            foreach (var child in syntax.NamedChildren.Reverse()) pending.Push((child, currentParent));
        }
        if (references.Count > MaxReferencesPerFile) references.RemoveRange(MaxReferencesPerFile, references.Count - MaxReferencesPerFile);
        return new ParsedFile(stamp, digest, nodes, edges, references);
    }

    private static string? LanguageFor(string extension) => extension switch
    {
        ".swift" => "swift",
        ".cs" => "c-sharp",
        ".ts" => "typescript",
        ".tsx" => "tsx",
        ".js" or ".jsx" => "javascript",
        ".py" => "python",
        ".go" => "go",
        ".rs" => "rust",
        ".java" => "java",
        ".php" => "php",
        ".rb" => "ruby",
        ".c" or ".h" => "c",
        ".cpp" or ".cc" or ".cxx" or ".hpp" or ".hh" => "cpp",
        _ => null,
    };

    private static string? DeclarationKind(string type) => type switch
    {
        "class_declaration" or "class_definition" or "class_item" or "class_specifier" or "class_declaration_statement" => "class",
        "interface_declaration" or "trait_item" or "protocol_declaration" or "trait_declaration" => "interface",
        "struct_declaration" or "struct_item" or "struct_specifier" => "struct",
        "enum_declaration" or "enum_item" or "enum_specifier" or "enum_declaration_statement" => "enum",
        "record_declaration" or "record_definition" or "record_declaration_statement" => "record",
        "function_declaration" or "function_definition" or "function_item" or "function_signature_item" => "function",
        "method_declaration" or "method_definition" or "method_item" or "method_signature" or "local_function_statement" => "method",
        "constructor_declaration" or "constructor_definition" or "constructor_declaration_statement" => "constructor",
        "type_alias_declaration" or "type_item" or "type_declaration" => "type",
        "actor_declaration" => "actor",
        _ => null,
    };

    private static bool IsImport(string type) => type is
        "import_declaration" or "import_statement" or "import_from_statement" or "use_declaration" or "use_item"
        or "using_directive" or "package_import_declaration" or "import_declaration_statement";

    private static bool IsInheritance(string type)
    {
        var value = type.ToLowerInvariant();
        return value.Contains("base_clause", StringComparison.Ordinal) || value.Contains("base_list", StringComparison.Ordinal)
            || value.Contains("base_class", StringComparison.Ordinal) || value.Contains("extends_clause", StringComparison.Ordinal)
            || value.Contains("superclass", StringComparison.Ordinal) || value.Contains("super_class", StringComparison.Ordinal)
            || value.Contains("super_interfaces", StringComparison.Ordinal) || value.Contains("implements_interfaces", StringComparison.Ordinal)
            || value == "extends_interfaces";
    }

    private static bool IsCall(string type) => type is
        "call_expression" or "invocation_expression" or "method_invocation" or "call" or "function_call";

    private static string? DeclarationName(TreeSitter.Node node)
    {
        var named = node.GetChildrenForField("name").FirstOrDefault();
        if (named is not null && !string.IsNullOrWhiteSpace(named.Text)) return CleanName(named.Text);
        return node.NamedChildren.FirstOrDefault(child => IsIdentifier(child.Type)) is { } childNode
            && !string.IsNullOrWhiteSpace(childNode.Text) ? CleanName(childNode.Text) : null;
    }

    private static IEnumerable<string> Identifiers(TreeSitter.Node node)
    {
        var pending = new Stack<TreeSitter.Node>();
        pending.Push(node);
        while (pending.Count > 0)
        {
            var current = pending.Pop();
            if (IsIdentifier(current.Type) && !string.IsNullOrWhiteSpace(current.Text)) yield return CleanName(current.Text);
            else foreach (var child in current.NamedChildren) pending.Push(child);
        }
    }

    private static bool IsIdentifier(string? type) => type is
        "identifier" or "type_identifier" or "field_identifier" or "property_identifier" or "constant" or "namespace_name";

    private static string? CallName(TreeSitter.Node node)
    {
        var target = node.GetChildrenForField("function").FirstOrDefault();
        if (target is null || string.IsNullOrWhiteSpace(target.Text)) target = node.GetChildrenForField("name").FirstOrDefault();
        if (target is not null && !string.IsNullOrWhiteSpace(target.Text))
        {
            var names = Identifiers(target).ToList();
            if (names.Count > 0) return names[^1];
        }
        var nested = Identifiers(node).ToList();
        return nested.Count == 0 ? null : nested[0];
    }

    private static string? ImportSource(string? source)
    {
        if (string.IsNullOrWhiteSpace(source)) return null;
        var value = source.Trim();
        var quoted = Regex.Match(value, "['\"](?<name>[^'\"]+)['\"]");
        if (quoted.Success) return CleanImport(quoted.Groups["name"].Value);
        value = Regex.Replace(value, @"^\s*(?:import|from|using|use|package)\s+", "", RegexOptions.IgnoreCase);
        value = Regex.Replace(value, @"\s+as\s+.*$", "", RegexOptions.IgnoreCase);
        value = value.Trim().TrimEnd(';', ',');
        return CleanImport(value);
    }

    private static string CleanImport(string value)
    {
        var name = value.Trim().TrimStart('.').TrimEnd(';', ',');
        var alias = name.IndexOf(" as ", StringComparison.OrdinalIgnoreCase);
        if (alias >= 0) name = name[..alias].Trim();
        return name.Length <= 240 ? name : name[..240];
    }

    private static string CleanName(string value) => value.Trim().Trim('@', '`');

    private static List<Edge> Resolve(IReadOnlyList<ParsedFile> files, IReadOnlyList<Node> nodes)
    {
        var output = new List<Edge>();
        var symbolsByName = nodes.Where(node => node.Kind != "file" && node.Kind != "import" && node.Name.Length > 0)
            .GroupBy(node => node.Name, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.ToList(), StringComparer.Ordinal);
        var fileNodes = nodes.Where(node => node.Kind == "file").ToList();
        var filesByReversedPath = fileNodes
            .Select(file => (
                File: file,
                ReversedPath: Reverse(Path.ChangeExtension(file.Path, null)?.Replace(Path.DirectorySeparatorChar, '/') ?? file.Path)))
            .OrderBy(item => item.ReversedPath, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var filesByBaseName = fileNodes
            .GroupBy(file => Path.GetFileNameWithoutExtension(file.Path), StringComparer.OrdinalIgnoreCase)
            .ToDictionary(group => group.Key, group => group.ToList(), StringComparer.OrdinalIgnoreCase);

        List<Node> ImportCandidates(string suffix)
        {
            var candidates = new List<Node>(2);
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var reversedSuffix = Reverse(suffix);
            var lower = 0;
            var upper = filesByReversedPath.Length;
            while (lower < upper)
            {
                var middle = lower + (upper - lower) / 2;
                if (StringComparer.OrdinalIgnoreCase.Compare(filesByReversedPath[middle].ReversedPath, reversedSuffix) < 0)
                    lower = middle + 1;
                else
                    upper = middle;
            }

            for (var index = lower; index < filesByReversedPath.Length
                && filesByReversedPath[index].ReversedPath.StartsWith(reversedSuffix, StringComparison.OrdinalIgnoreCase); index++)
            {
                var file = filesByReversedPath[index].File;
                if (!seen.Add(file.Id)) continue;
                candidates.Add(file);
                if (candidates.Count == 2) return candidates;
            }

            var baseName = Path.GetFileName(suffix) ?? "";
            if (filesByBaseName.TryGetValue(baseName, out var sameName))
            {
                foreach (var file in sameName)
                {
                    if (!seen.Add(file.Id)) continue;
                    candidates.Add(file);
                    if (candidates.Count == 2) return candidates;
                }
            }
            return candidates;
        }

        foreach (var reference in files.SelectMany(file => file.References))
        {
            if (reference.Relation == "RESOLVES_TO")
            {
                var suffix = reference.Name.Replace('.', '/').TrimStart('/');
                // The reversed-path index turns an EndsWith scan of every source file
                // into a prefix lookup; cap candidates because only uniqueness matters.
                var candidates = ImportCandidates(suffix);
                if (candidates.Count == 1) output.Add(new Edge(reference.From, candidates[0].Id, "RESOLVES_TO", "INFERRED", 0.82));
                continue;
            }
            if (symbolsByName.TryGetValue(reference.Name, out var targets) && targets.Count == 1 && targets[0].Id != reference.From)
                output.Add(new Edge(reference.From, targets[0].Id, reference.Relation, "INFERRED", 0.82));
        }
        return output.DistinctBy(edge => (edge.From, edge.To, edge.Relation, edge.Provenance)).ToList();
    }

    private static string Reverse(string value) => new(value.Reverse().ToArray());

    private static string? Query(ProjectGraph graph, string workspace, string? userRoot, string prompt, bool includeMemory)
    {
        var terms = WorkspaceInsights.Tokens(prompt);
        if (terms.Count == 0) return null;
        var fileNodes = graph.Nodes.Where(node => node.Kind == "file").ToList();
        var parsedPaths = fileNodes.Select(node => node.Path).ToHashSet(StringComparer.Ordinal);
        var unparsedPaths = graph.Inventory.Select(file => file.Path).Where(path => !parsedPaths.Contains(path)).ToList();
        var requestNamesAnUnparsedFile = unparsedPaths.Any(path =>
            FileIndex.Words(path).Overlaps(terms) || prompt.Contains(path, StringComparison.OrdinalIgnoreCase));
        // Use partial coverage only for queries whose words do not point at an omitted file.
        // A likely match to an omitted path leaves the established file index in charge.
        if (requestNamesAnUnparsedFile) return null;

        var scores = new Dictionary<string, double>(StringComparer.Ordinal);
        var nodeScores = new Dictionary<string, double>(StringComparer.Ordinal);
        foreach (var node in graph.Nodes.Where(node => node.Kind != "import"))
        {
            var overlap = FileIndex.Words(node.Name).Intersect(terms).Count();
            var pathOverlap = FileIndex.Words(node.Path).Intersect(terms).Count();
            var score = overlap + pathOverlap * 0.35;
            if (node.Name.Length > 0 && prompt.Contains(node.Name, StringComparison.OrdinalIgnoreCase)) score += 4;
            if (score <= 0) continue;
            nodeScores[node.Id] = score;
            scores[node.Path] = Math.Max(scores.GetValueOrDefault(node.Path), score);
        }

        var findings = includeMemory ? MemoryFindings(graph, workspace, userRoot, prompt, terms) : [];
        foreach (var finding in findings.Where(item => item.Score > 0))
            foreach (var path in finding.Paths.Where(parsedPaths.Contains))
                scores[path] = scores.GetValueOrDefault(path) + finding.Score * 1.4;

        var ranked = scores.OrderByDescending(pair => pair.Value).ThenBy(pair => pair.Key, StringComparer.Ordinal).ToList();
        if (ranked.Count == 0 || ranked[0].Value < 1) return null;
        if (ranked.Count > 1 && ranked[0].Value - ranked[1].Value < 0.2) return null;
        var selectedPaths = ranked.Where(pair => pair.Value >= ranked[0].Value * 0.48).Take(3).Select(pair => pair.Key).ToList();
        if (selectedPaths.Count == 0) return null;
        var selected = selectedPaths.ToHashSet(StringComparer.Ordinal);
        var visibleNodes = new List<Node>();
        var includedIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var path in selectedPaths)
        {
            var file = fileNodes.FirstOrDefault(node => node.Path == path);
            if (file is not null && includedIds.Add(file.Id)) visibleNodes.Add(file);
            foreach (var symbol in graph.Nodes.Where(node => node.Path == path && node.Kind != "file" && node.Kind != "import")
                         .OrderByDescending(node => nodeScores.GetValueOrDefault(node.Id)).ThenBy(node => node.Id, StringComparer.Ordinal).Take(8))
                if (includedIds.Add(symbol.Id)) visibleNodes.Add(symbol);
        }

        var linked = findings.Where(item => item.Paths.Any(selected.Contains))
            .OrderByDescending(item => item.Score).ThenByDescending(item => item.UpdatedAt, StringComparer.Ordinal).Take(4).ToList();
        var memoryEdges = new List<Edge>();
        foreach (var item in linked)
        {
            visibleNodes.Add(new Node(item.Id, "memory-" + item.Kind, item.Text, "", 0, "memory", null));
            foreach (var path in item.Paths.Where(selected.Contains))
            {
                var fileId = "file:" + path;
                memoryEdges.Add(new Edge(item.Id, fileId, "RELATES_TO", "MEMORY", 1));
                var mentions = new Mentions(item.Evidence);
                var mentioned = graph.Nodes.Where(node => node.Path == path && node.Kind != "file" && node.Kind != "import"
                    && mentions.Contains(node.Name)).ToList();
                if (mentioned.Count == 1)
                    memoryEdges.Add(new Edge(item.Id, mentioned[0].Id, "RELATES_TO", "MEMORY", 1));
            }
        }

        // Two hops preserve local import/call context while keeping the request bounded.
        var byId = graph.Nodes.ToDictionary(node => node.Id, StringComparer.Ordinal);
        var frontier = visibleNodes.Select(node => node.Id).ToHashSet(StringComparer.Ordinal);
        for (var hop = 0; hop < 2; hop++)
        {
            var next = new HashSet<string>(StringComparer.Ordinal);
            foreach (var edge in graph.Edges.Where(edge => frontier.Contains(edge.From) || frontier.Contains(edge.To)))
                foreach (var endpoint in new[] { edge.From, edge.To })
                    if (includedIds.Count < 35 && includedIds.Add(endpoint) && byId.TryGetValue(endpoint, out var neighbour))
                    {
                        visibleNodes.Add(neighbour);
                        next.Add(endpoint);
                    }
            frontier = next;
            if (frontier.Count == 0) break;
        }

        var visibleIds = visibleNodes.Select(node => node.Id).ToHashSet(StringComparer.Ordinal);
        var edges = graph.Edges.Where(edge => visibleIds.Contains(edge.From) && visibleIds.Contains(edge.To))
            .Concat(memoryEdges.Where(edge => visibleIds.Contains(edge.From) && visibleIds.Contains(edge.To)))
            .DistinctBy(edge => (edge.From, edge.To, edge.Relation, edge.Provenance)).Take(70).ToList();
        var code = visibleNodes.Where(node => node.Kind != "memory-decision" && node.Kind != "memory-lesson" && node.Kind != "memory-error" && node.Kind != "memory-area");
        var filesText = string.Join("\n", selectedPaths.Select(path =>
        {
            var symbols = code.Where(node => node.Path == path && node.Kind != "file" && node.Kind != "import")
                .OrderBy(node => node.Line).Take(8).Select(node => $"  - {node.Kind} `{node.Name}` (line {node.Line})");
            return $"- `{path}`\n" + string.Join("\n", symbols);
        }));
        var relationText = string.Join("\n", edges.Select(edge =>
        {
            var from = visibleNodes.FirstOrDefault(node => node.Id == edge.From)?.Name ?? edge.From;
            var to = visibleNodes.FirstOrDefault(node => node.Id == edge.To)?.Name ?? edge.To;
            return $"- `{from}` --{edge.Relation} [{edge.Provenance}, {edge.Confidence:0.00}]--> `{to}`";
        }));
        var memoryText = string.Join("\n", linked.Select(item => $"- [{item.Kind}] {item.Text}"));
        var coverageNote = unparsedPaths.Count == 0 ? "" : $"\nCoverage note: {unparsedPaths.Count} source files were not parsed. Their filenames do not match this request, but inspect them if source review suggests they are relevant. Omitted paths: {string.Join(", ", unparsedPaths.Take(8).Select(path => $"`{path}`"))}.";
        return "## Relevant project code subgraph\nOnly this request's current local subgraph is shown. The graph stores names and relationships, not source lines or signatures. User preferences stay in the separate personal-memory store. EXTRACTED relationships come from source syntax; INFERRED relationships are unique local name matches with confidence. Verify inferred links in source.\n"
            + filesText
            + (relationText.Length == 0 ? "" : "\nRelationships:\n" + relationText)
            + (memoryText.Length == 0 ? "" : "\nRelated project decisions and lessons:\n" + memoryText)
            + coverageNote;
    }

    private static ProjectGraph QueryIndex(ProjectGraph graph) => new()
    {
        SchemaVersion = graph.SchemaVersion,
        GeneratedAt = graph.GeneratedAt,
        InventoryFingerprint = graph.InventoryFingerprint,
        Inventory = graph.Inventory,
        CoverageComplete = graph.CoverageComplete,
        SkippedFiles = graph.SkippedFiles,
        Files = [],
        Nodes = graph.Nodes,
        // CONTAINS is recoverable from node paths and duplicates much of the full graph.
        Edges = graph.Edges.Where(edge => edge.Relation != "CONTAINS").ToList(),
    };

    private static List<Finding> MemoryFindings(ProjectGraph graph, string workspace, string? userRoot, string prompt, HashSet<string> terms)
    {
        var available = graph.Nodes.Where(node => node.Kind == "file").Select(node => node.Path).ToHashSet(StringComparer.Ordinal);
        var output = new List<Finding>();
        foreach (var insight in WorkspaceInsights.Read(workspace, userRoot).Insights)
        {
            var evidence = string.Join(" ", new[] { insight.Text }.Concat(insight.Keywords ?? []).Concat(insight.Files).Concat(insight.Tools));
            var linkedPaths = LinkPaths(insight.Files, evidence, graph.Nodes, workspace, available);
            if (linkedPaths.Count == 0) continue;
            var insightTerms = WorkspaceInsights.Tokens(evidence);
            var score = Math.Min(terms.Intersect(insightTerms).Count(), 4);
            if (score > 0) output.Add(new Finding("insight:" + insight.Id, insight.Kind, insight.Text, evidence, linkedPaths, score, insight.UpdatedAt));
        }

        foreach (var fact in WorkspaceFacts.Read(workspace))
        {
            var evidence = fact.Key + " " + fact.Text;
            var linkedPaths = LinkPaths([], evidence, graph.Nodes, workspace, available);
            if (linkedPaths.Count == 0) continue;
            var score = Math.Min(terms.Intersect(WorkspaceInsights.Tokens(evidence)).Count(), 4);
            if (score > 0) output.Add(new Finding($"project-fact:{fact.Key}", fact.Kind, evidence, evidence, linkedPaths, score, ""));
        }

        foreach (var lesson in WorkspaceLessons.Read(workspace, userRoot).Where(lesson => lesson.Paths.Count > 0 && lesson.IsActive(DateTimeOffset.UtcNow)))
        {
            var linkedPaths = lesson.Paths.SelectMany(scope => available.Where(path => AppliesTo(scope, path)))
                .Distinct(StringComparer.Ordinal).OrderBy(path => path, StringComparer.Ordinal).ToList();
            if (linkedPaths.Count == 0) continue;
            var text = lesson.Line;
            var evidence = text + " " + string.Join(" ", lesson.Paths);
            var score = Math.Min(terms.Intersect(WorkspaceInsights.Tokens(evidence)).Count(), 4);
            if (score > 0) output.Add(new Finding("lesson:" + lesson.Id, "lesson", lesson.Cited, evidence, linkedPaths, score, lesson.LastSeen.ToString("O")));
        }
        return output;
    }

    private static List<string> LinkPaths(IReadOnlyList<string> explicitPaths, string evidence, IReadOnlyList<Node> nodes, string workspace, HashSet<string> available)
    {
        static string Normalize(string path, string root)
        {
            if (Path.IsPathRooted(path) && path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                path = Path.GetRelativePath(root, path);
            path = path.Replace('\\', '/');
            return path.StartsWith("./", StringComparison.Ordinal) ? path[2..] : path;
        }

        var saved = explicitPaths.Select(path => Normalize(path, workspace)).Where(available.Contains).Distinct(StringComparer.Ordinal).ToList();
        if (saved.Count > 0) return saved;
        var mentions = new Mentions(evidence);
        var fileMatches = nodes.Where(node => node.Kind == "file"
            && (mentions.Contains(node.Path) || mentions.Contains(node.Name))).ToList();
        if (fileMatches.Count == 1) return [fileMatches[0].Path];
        if (fileMatches.Count > 1) return [];
        var symbols = nodes.Where(node => node.Kind != "file" && node.Kind != "import" && mentions.Contains(node.Name)).ToList();
        return symbols.Count == 1 ? [symbols[0].Path] : [];
    }

    private static bool AppliesTo(string scope, string path)
    {
        var normalizedScope = scope.Replace('\\', '/').TrimEnd('/');
        var normalizedPath = path.Replace('\\', '/');
        return normalizedPath == normalizedScope || normalizedPath.StartsWith(normalizedScope + "/", StringComparison.Ordinal);
    }

    /// <summary>
    /// Whole-word, case-insensitive mentions in one text, built once and asked per graph
    /// node. A regex built per node name made each prompt findings x nodes regex runs (macOS: ExplicitMentions).
    /// </summary>
    private sealed class Mentions
    {
        private readonly string _text;
        private readonly HashSet<string> _words = new(StringComparer.OrdinalIgnoreCase);

        public Mentions(string text)
        {
            _text = text;
            var start = -1;
            for (var i = 0; i <= text.Length; i++)
            {
                if (i < text.Length && IsWordCharacter(text[i])) { if (start < 0) start = i; }
                else if (start >= 0) { _words.Add(text[start..i]); start = -1; }
            }
        }

        public bool Contains(string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return false;
            if (IsWord(value)) return _words.Contains(value);
            // Paths and dotted names span several words: bounded substring search.
            for (var at = _text.IndexOf(value, StringComparison.OrdinalIgnoreCase); at >= 0;
                 at = _text.IndexOf(value, at + 1, StringComparison.OrdinalIgnoreCase))
            {
                var end = at + value.Length;
                if ((at == 0 || !IsWordCharacter(_text[at - 1])) && (end == _text.Length || !IsWordCharacter(_text[end])))
                    return true;
            }
            return false;
        }

        private static bool IsWord(string value)
        {
            foreach (var character in value)
                if (!IsWordCharacter(character)) return false;
            return true;
        }

        private static bool IsWordCharacter(char character) => character == '_' || char.IsLetter(character) || char.IsNumber(character);
    }

    private static string Report(ProjectGraph graph)
    {
        var degrees = graph.Edges.SelectMany(edge => new[] { edge.From, edge.To }).GroupBy(id => id)
            .ToDictionary(group => group.Key, group => group.Count(), StringComparer.Ordinal);
        var names = graph.Nodes.ToDictionary(node => node.Id, node => node.Name, StringComparer.Ordinal);
        var central = degrees.OrderByDescending(pair => pair.Value).ThenBy(pair => pair.Key, StringComparer.Ordinal).Take(20);
        var extracted = graph.Edges.Count(edge => edge.Provenance == "EXTRACTED");
        var inferred = graph.Edges.Count(edge => edge.Provenance == "INFERRED");
        return "# Project code graph\n\n"
            + $"Generated: {graph.GeneratedAt}\n\nFiles: {graph.Inventory.Count}\nParsed: {graph.Files.Count}\nNodes: {graph.Nodes.Count}\nEdges: {graph.Edges.Count} ({extracted} EXTRACTED, {inferred} INFERRED)\nCoverage complete: {graph.CoverageComplete}\nSkipped files: {graph.SkippedFiles}\nPrompt-time index: `{QueryIndexFileName}`\n\n"
            + "## Most connected nodes\n\n"
            + string.Join("\n", central.Select(pair => $"- `{names.GetValueOrDefault(pair.Key, pair.Key)}` — {pair.Value} relationships"))
            + "\n\nThe interactive graph is in `graph.html`. This report describes syntax-derived and uniquely resolved local relationships; verify INFERRED links in source.\n";
    }

    private static string Html(ProjectGraph graph)
    {
        var data = JsonSerializer.Serialize(new { nodes = graph.Nodes, edges = graph.Edges }, Json);
        return "<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>HerNess project code graph</title>"
            + "<style>body{margin:0;background:#10151b;color:#e7edf4;font:14px system-ui}header{padding:12px 16px;display:flex;gap:12px;align-items:center}input{background:#1c2631;color:inherit;border:1px solid #465565;border-radius:6px;padding:8px;min-width:260px}svg{width:100vw;height:calc(100vh - 58px)}line{stroke:#5b6875;stroke-opacity:.5}circle{stroke:#10151b;stroke-width:2}.file{fill:#67b7f7}.class,.struct,.interface,.enum,.record,.actor{fill:#f5b85d}.function,.method,.constructor{fill:#8bd49c}.import{fill:#b69cf3}.memory{fill:#ff8297}text{fill:#d9e2ec;font-size:11px;pointer-events:none}.muted{opacity:.12}</style>"
            + "<header><b>Project code graph</b><input id=\"q\" placeholder=\"Filter nodes\"><span id=\"count\"></span></header><svg id=\"g\"></svg><script>const d=" + data + ";"
            + "const s=document.getElementById('g'),ns='http://www.w3.org/2000/svg',w=()=>innerWidth,h=()=>innerHeight-58;let n=d.nodes.filter(x=>x.kind!=='import').slice(0,1800);let ix=new Map(n.map((x,i)=>[x.id,i]));let cx=w()/2,cy=h()/2,R=Math.min(w(),h())*.42;let pos=n.map((x,i)=>({x:cx+R*Math.cos(i*2.399),y:cy+R*Math.sin(i*2.399)}));let lines=[];for(const e of d.edges){if(ix.has(e.from)&&ix.has(e.to)){let a=pos[ix.get(e.from)],b=pos[ix.get(e.to)],l=document.createElementNS(ns,'line');l.setAttribute('x1',a.x);l.setAttribute('y1',a.y);l.setAttribute('x2',b.x);l.setAttribute('y2',b.y);l.dataset=edge=e.relation;s.appendChild(l);lines.push([l,e])}}let els=[];n.forEach((x,i)=>{let p=pos[i],g=document.createElementNS(ns,'g'),c=document.createElementNS(ns,'circle'),t=document.createElementNS(ns,'text'),title=document.createElementNS(ns,'title');c.setAttribute('cx',p.x);c.setAttribute('cy',p.y);c.setAttribute('r',x.kind==='file'?7:5);c.setAttribute('class',x.kind.startsWith('memory-')?'memory':x.kind);title.textContent=x.path+(x.line?':'+x.line:'')+' · '+x.kind; c.appendChild(title);t.setAttribute('x',p.x+9);t.setAttribute('y',p.y+4);t.textContent=x.name;g.append(c,t);g.dataset.search=(x.name+' '+x.path+' '+x.kind).toLowerCase();s.appendChild(g);els.push(g)});document.getElementById('count').textContent=n.length+' nodes · '+lines.length+' links';document.getElementById('q').oninput=e=>{let q=e.target.value.toLowerCase();els.forEach(g=>g.classList.toggle('muted',!!q&&!g.dataset.search.includes(q)));lines.forEach(([l])=>l.classList.toggle('muted',!!q))};onresize=()=>location.reload();</script>";
    }

    private static bool IsSymlink(string path)
    {
        if (!File.Exists(path) && !Directory.Exists(path)) return false;
        try { return new FileInfo(path).LinkTarget is not null || new DirectoryInfo(path).LinkTarget is not null; }
        catch (IOException) { return true; }
        catch (UnauthorizedAccessException) { return true; }
    }

    private static bool HasUnsafePathComponent(string target, string root)
    {
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullTarget = Path.GetFullPath(target);
        if (!fullTarget.StartsWith(fullRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return true;
        var relative = Path.GetRelativePath(fullRoot, fullTarget);
        var cursor = fullRoot;
        foreach (var component in relative.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            cursor = Path.Combine(cursor, component);
            if (IsSymlink(cursor)) return true;
        }
        return false;
    }

    private static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
}
