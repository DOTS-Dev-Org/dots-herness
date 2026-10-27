// Copyright (c) 2026 DOTS
// The repository's files named like a request, so the agent opens them instead of
// sweeping the workspace for where to start: file paths by the words of their names and
// of what they declare, each with its latest commit. Built on this machine from git's
// index with no model and no file written; a request carries at most twelve names.
//
// Mirrors FileIndex and WorkspaceMemory.relevantFiles on macOS.

using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace DotsHarnessCore;

/// <summary>
/// ponytail: declarations are found by keyword, not parsed, and word overlap, not
/// embeddings; a request in other words than the code's own finds nothing.
/// </summary>
public sealed class FileIndex
{
    /// <summary>ponytail: the first 20,000 files; a larger repository is indexed in part.</summary>
    public const int Limit = 20_000;

    private readonly List<(string Path, HashSet<string> Tokens, IReadOnlyList<string> Symbols, HashSet<string> SymbolTokens)> _names;
    private readonly Dictionary<string, int> _frequency = new(StringComparer.Ordinal);
    private readonly Dictionary<string, int> _symbolFrequency = new(StringComparer.Ordinal);

    /// <summary>
    /// `learned` adds, per path, the words of the requests that changed that file.
    /// ponytail: a word counts the same from a request as from the name.
    /// </summary>
    public FileIndex(
        IEnumerable<string> paths,
        IReadOnlyDictionary<string, IReadOnlyList<string>>? symbols = null,
        IReadOnlyDictionary<string, HashSet<string>>? learned = null)
    {
        // Git quotes a path it had to escape; such a name is not worth showing a model.
        _names = paths.Where(path => !path.StartsWith('"') && path.Length <= 200).Take(Limit).Select(path =>
        {
            IReadOnlyList<string> declared = symbols is not null && symbols.TryGetValue(path, out var found) ? found : [];
            var words = Words(Path.GetFileNameWithoutExtension(path));
            if (learned is not null && learned.TryGetValue(path, out var taught)) words.UnionWith(taught);
            return (path, words, declared, declared.SelectMany(Words).ToHashSet(StringComparer.Ordinal));
        }).ToList();
        foreach (var entry in _names)
        {
            foreach (var token in entry.Tokens) _frequency[token] = _frequency.GetValueOrDefault(token) + 1;
            foreach (var token in entry.SymbolTokens) _symbolFrequency[token] = _symbolFrequency.GetValueOrDefault(token) + 1;
        }
    }

    /// <summary>"MemoryVaultView" is found by "memory", "vault" and by its whole name.</summary>
    public static HashSet<string> Words(string name)
    {
        var spaced = new StringBuilder();
        var previous = ' ';
        foreach (var character in name)
        {
            if (char.IsUpper(character) && (char.IsLower(previous) || char.IsDigit(previous))) spaced.Append(' ');
            spaced.Append(character);
            previous = character;
        }
        var words = WorkspaceInsights.Tokens(name);
        words.UnionWith(WorkspaceInsights.Tokens(spaced.ToString()));
        return words;
    }

    public IReadOnlyList<string> Matching(string prompt, int limit = 12) => Hits(prompt, limit).Select(hit => hit.Path).ToList();

    /// <summary>The best files for a request, each with the declarations the request names.</summary>
    public IReadOnlyList<(string Path, IReadOnlyList<string> Symbols)> Hits(string prompt, int limit = 12)
    {
        var terms = WorkspaceInsights.Tokens(prompt);
        if (terms.Count == 0) return [];
        return _names.Select(entry =>
            {
                // A word many files are named after ("view", "tests") points nowhere.
                var score = entry.Tokens.Where(terms.Contains).Sum(token =>
                    _frequency[token] > 30 ? 0 : 1 + 1.0 / _frequency[token]);
                // A declaration says less about a file than its name does: half the weight.
                score += entry.SymbolTokens.Where(token => terms.Contains(token) && !entry.Tokens.Contains(token)).Sum(token =>
                    _symbolFrequency[token] > 30 ? 0 : 0.5 + 1.0 / _symbolFrequency[token]);
                return (Score: score, entry.Path, entry.Symbols);
            })
            .Where(hit => hit.Score > 0)
            .OrderByDescending(hit => hit.Score).ThenBy(hit => hit.Path, StringComparer.Ordinal)
            .Take(limit)
            .Select(hit => (hit.Path, (IReadOnlyList<string>)hit.Symbols.Where(symbol => Words(symbol).Overlaps(terms)).Take(4).ToList()))
            .ToList();
    }
}

public static class WorkspaceFileIndex
{
    private static readonly HashSet<string> SourceExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".swift", ".ts", ".tsx", ".js", ".jsx", ".cs", ".py", ".go", ".rs", ".kt", ".java", ".dart", ".c", ".h", ".cpp", ".m", ".mm", ".rb", ".php",
    };

    private static readonly Regex Declaration = new(
        @"\b(?:class|struct|enum|protocol|extension|interface|trait|actor|func|fun|fn|def|function|type|record|namespace)\s+([A-Za-z_]\w{2,})",
        RegexOptions.Compiled);

    private sealed record Built(string Workspace, string Stamp, bool Complete, FileIndex Index, Dictionary<string, string> Changes,
        Dictionary<string, (DateTime Modified, IReadOnlyList<string> Names)> Symbols);

    private static readonly object Gate = new();
    private static Built? _built;
    private static string? _building;

    /// <summary>Lines of one git command's output; empty when git fails or the folder is not a repository.</summary>
    public static IReadOnlyList<string> Git(string workspace, params string[] arguments)
    {
        try
        {
            var start = new ProcessStartInfo("git")
            {
                WorkingDirectory = workspace,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
            };
            foreach (var argument in arguments) start.ArgumentList.Add(argument);
            using var process = Process.Start(start);
            if (process is null) return [];
            // Errors are discarded as they arrive, so a large one cannot fill its pipe and block git.
            process.ErrorDataReceived += (_, _) => { };
            process.BeginErrorReadLine();
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit();
            return process.ExitCode == 0 ? output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(line => line.TrimEnd('\r')).ToList() : [];
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or IOException or InvalidOperationException) { return []; }
    }

    /// <summary>
    /// The names a source text declares, in order, each once.
    /// ponytail: a keyword followed by a name; a C# or Java method has no keyword and is
    /// missed, and a keyword inside a comment or a string is taken.
    /// </summary>
    public static IReadOnlyList<string> Symbols(string text) =>
        Declaration.Matches(text).Select(match => match.Groups[1].Value).Distinct(StringComparer.Ordinal).Take(200).ToList();

    /// <summary>
    /// Reads the project into an index: its files from the shared scan policy, what each source file
    /// declares (a file whose date has not moved keeps what was read before), and each
    /// file's latest commit as "date subject" when Git history is available.
    /// ponytail: the first 5,000 source files, none over 300 KB, and the last 300 commits.
    /// An unmanaged workspace still gets file paths and declarations, but no commit subjects.
    /// </summary>
    public static void Build(string workspace, IReadOnlyDictionary<string, HashSet<string>>? learned = null)
    {
        if (!Directory.Exists(workspace)) return;
        workspace = Path.GetFullPath(workspace);
        Dictionary<string, (DateTime Modified, IReadOnlyList<string> Names)> known;
        lock (Gate) known = _built?.Workspace == workspace ? _built.Symbols : [];
        var files = NativeWorkspaceTools.ScanFiles(workspace).ToList();
        var paths = files.Select(path => Path.GetRelativePath(workspace, path).Replace(Path.DirectorySeparatorChar, '/')).ToList();
        var stamp = WorkspaceScanPolicy.Revision(workspace, files);
        var symbols = new Dictionary<string, (DateTime Modified, IReadOnlyList<string> Names)>(StringComparer.Ordinal);
        foreach (var path in paths.Where(path => SourceExtensions.Contains(Path.GetExtension(path))).Take(5_000))
        {
            try
            {
                var info = new FileInfo(Path.Combine(workspace, path));
                if (!info.Exists || info.Length > 300_000) continue;
                symbols[path] = known.TryGetValue(path, out var kept) && kept.Modified == info.LastWriteTimeUtc
                    ? kept
                    : (info.LastWriteTimeUtc, Symbols(File.ReadAllText(info.FullName)));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException) { }
        }
        var changes = new Dictionary<string, string>(StringComparer.Ordinal);
        var commit = "";
        foreach (var line in Git(workspace, "log", "-n", "300", "--name-only", "--format=%x01%cs %s"))
        {
            if (line.StartsWith('\u0001')) commit = line[1..];
            else changes.TryAdd(line, commit);
        }
        var index = new FileIndex(paths, symbols.ToDictionary(pair => pair.Key, pair => pair.Value.Names, StringComparer.Ordinal), learned);
        lock (Gate) _built = new Built(workspace, stamp, true, index, changes, symbols);
    }

    /// <summary>
    /// The prompt text for a request. Reading a repository would hold the request up, so a
    /// stale or missing index is refreshed in the background. A path-only index is
    /// available immediately on the first request while symbols and change notes load.
    /// </summary>
    public static string Text(string? workspace, string prompt, string? userRoot = null)
    {
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return "";
        workspace = Path.GetFullPath(workspace);
        var files = NativeWorkspaceTools.ScanFiles(workspace).ToList();
        var paths = files.Select(path => Path.GetRelativePath(workspace, path).Replace(Path.DirectorySeparatorChar, '/')).ToList();
        var stamp = WorkspaceScanPolicy.Revision(workspace, files);
        Built? built;
        lock (Gate)
        {
            built = _built?.Workspace == workspace ? _built : null;
            if (built is null)
            {
                built = new Built(workspace, stamp, false, new FileIndex(paths), new Dictionary<string, string>(StringComparer.Ordinal), []);
                _built = built;
            }
            if (built.Stamp != stamp && _building != workspace)
            {
                _building = workspace;
                _ = Task.Run(() =>
                {
                    try { Build(workspace, userRoot is null ? null : WorkspaceInsights.TaskFileTerms(workspace, userRoot)); }
                    finally { lock (Gate) _building = null; }
                });
            }
            else if (built.Stamp == stamp && !built.Complete && _building != workspace)
            {
                _building = workspace;
                _ = Task.Run(() =>
                {
                    try { Build(workspace, userRoot is null ? null : WorkspaceInsights.TaskFileTerms(workspace, userRoot)); }
                    finally { lock (Gate) _building = null; }
                });
            }
        }
        if (built is null) return "";
        var lines = built.Index.Hits(prompt).Select(hit =>
            $"- `{hit.Path}`"
            + (hit.Symbols.Count == 0 ? "" : $" ({string.Join(", ", hit.Symbols)})")
            + (built.Changes.TryGetValue(hit.Path, out var change) ? $" - last changed {WorkspaceInsights.Clean(change, 100)}" : "")).ToList();
        return lines.Count == 0
            ? ""
            : "## Files named like this request\nIn brackets: what the file declares that the request names. Start from these instead of listing or searching the workspace or its git log; search only when they do not hold what the request needs.\n"
                + string.Join("\n", lines);
    }
}
