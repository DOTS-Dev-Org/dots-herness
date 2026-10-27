// Copyright (c) 2026 DOTS
// One project-relative inclusion policy for maps, indexes, graphs and memory study.

using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace DotsHarnessCore;

/// <summary>
/// Gives every automatic project scan the same file set. Git supplies its own ignore
/// semantics in repositories; non-repositories use the same basic gitignore patterns.
/// Explicit includes can admit one otherwise-ignored file, while built-in private paths
/// are always excluded.
/// </summary>
internal static class WorkspaceScanPolicy
{
    internal const string IgnoreFileName = ".hernessignore";
    internal const string IncludeFileName = ".hernessinclude";

    private sealed record Rule(string Base, string Pattern, bool Negated, bool DirectoryOnly, Regex Matcher, bool HasSlash);
    private static readonly object CacheGate = new();
    private static readonly Dictionary<string, (DateTime Updated, IReadOnlyList<string> Files)> Cache = new(StringComparer.Ordinal);
    private static readonly TimeSpan CacheLifetime = TimeSpan.FromSeconds(1);

    private static readonly HashSet<string> SensitiveExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".db", ".sqlite", ".sqlite3", ".pem", ".key", ".p8", ".p12", ".pfx", ".jks", ".keystore", ".mobileprovision",
    };

    private static readonly HashSet<string> SensitiveNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "provider-state.json", "conversations.json", "state.sqlite", "state.db", ".netrc", ".npmrc", ".pypirc",
        "credentials", "credentials.json", "secrets", "secrets.json", "id_rsa", "id_ed25519", "id_ecdsa",
    };

    internal static IReadOnlyList<string> ScanFiles(string root)
    {
        if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root)) return [];
        root = Path.GetFullPath(root);
        lock (CacheGate)
        {
            if (Cache.TryGetValue(root, out var cached) && DateTime.UtcNow - cached.Updated < CacheLifetime) return cached.Files;
        }
        var files = ScanFilesUncached(root);
        lock (CacheGate)
        {
            if (Cache.Count > 32) Cache.Clear();
            Cache[root] = (DateTime.UtcNow, files);
        }
        return files;
    }

    private static IReadOnlyList<string> ScanFilesUncached(string root)
    {
        var rootIgnoreRules = ReadRules(Path.Combine(root, IgnoreFileName), "");
        var hernessRules = rootIgnoreRules;
        List<string> candidates;
        HashSet<string> gitIgnored = new(StringComparer.Ordinal);

        if (IsGitWorkspace(root))
        {
            candidates = WorkspaceFileIndex.Git(root, "-c", "core.quotePath=false", "ls-files", "--cached", "--others", "--exclude-standard")
                .Where(path => !path.StartsWith('"')).ToList();
            gitIgnored = WorkspaceFileIndex.Git(root, "-c", "core.quotePath=false", "ls-files", "--cached", "--ignored", "--exclude-standard")
                .Where(path => !path.StartsWith('"')).ToHashSet(StringComparer.Ordinal);
        }
        else
        {
            candidates = Walk(root, root, []).ToList();
        }

        var included = ReadIncludes(root);
        var paths = new HashSet<string>(StringComparer.Ordinal);
        foreach (var candidate in candidates)
        {
            var relative = Normalize(candidate);
            if (relative.Length == 0 || IsPrivateExcluded(relative) || IsDefaultSkippedDirectory(relative) || !IsRegularFile(root, relative)) continue;
            var explicitInclude = included.Contains(relative);
            if (!explicitInclude && (gitIgnored.Contains(candidate) || IsIgnored(relative, hernessRules))) continue;
            paths.Add(relative);
        }

        // Includes are exact paths rather than globs, so a project can opt in one generated
        // source file without making its build output visible to every scanner.
        foreach (var relative in included)
        {
            if (IsPrivateExcluded(relative) || !IsRegularFile(root, relative)) continue;
            paths.Add(relative);
        }

        return paths.Order(StringComparer.Ordinal)
            .Select(relative => Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)))
            .ToList();
    }

    internal static string Revision(string root, IReadOnlyList<string> files)
    {
        var rootPath = Path.GetFullPath(root);
        var value = new StringBuilder();
        foreach (var path in files)
        {
            var relative = Path.GetRelativePath(rootPath, path).Replace(Path.DirectorySeparatorChar, '/');
            try
            {
                var info = new FileInfo(path);
                value.Append(relative).Append('\t').Append(info.Length).Append('\t')
                    .Append(info.LastWriteTimeUtc.Ticks).Append('\n');
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
            {
                value.Append(relative).Append("\tmissing\n");
            }
        }
        foreach (var name in new[] { ".gitignore", IgnoreFileName, IncludeFileName })
        {
            var path = Path.Combine(rootPath, name);
            try
            {
                var info = new FileInfo(path);
                value.Append(name).Append('\t').Append(info.Length).Append('\t').Append(info.LastWriteTimeUtc.Ticks).Append('\n');
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException) { }
        }
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value.ToString())));
    }

    private static bool IsGitWorkspace(string root) =>
        WorkspaceFileIndex.Git(root, "rev-parse", "--is-inside-work-tree").Any(line => line == "true");

    private static IEnumerable<string> Walk(string root, string directory, IReadOnlyList<Rule> inherited)
    {
        var relativeDirectory = Path.GetRelativePath(root, directory).Replace(Path.DirectorySeparatorChar, '/');
        if (relativeDirectory == ".") relativeDirectory = "";
        var rules = new List<Rule>(inherited);
        rules.AddRange(ReadRules(Path.Combine(directory, ".gitignore"), relativeDirectory));
        string[] entries;
        try { entries = Directory.EnumerateFileSystemEntries(directory).Order(StringComparer.Ordinal).ToArray(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { entries = []; }

        foreach (var entry in entries)
        {
            if (NativeWorkspaceTools.IsSymlink(entry)) continue;
            var relative = Normalize(Path.GetRelativePath(root, entry));
            if (relative.Length == 0 || IsPrivateExcluded(relative) || IsDefaultSkippedDirectory(relative)) continue;
            if (Directory.Exists(entry))
            {
                // Descend through user ignore rules so a later negation can re-include a
                // child. Fixed build, dependency and private directories are stopped above;
                // one exact .hernessinclude path can still opt into a generated file.
                foreach (var child in Walk(root, entry, rules)) yield return child;
            }
            else if (File.Exists(entry) && !IsIgnored(relative, rules))
            {
                yield return relative;
            }
        }
    }

    private static List<Rule> ReadRules(string path, string basePath)
    {
        var rules = new List<Rule>();
        string[] lines;
        try { lines = File.ReadAllLines(path, Encoding.UTF8); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return rules; }
        foreach (var raw in lines)
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var negated = line[0] == '!';
            if (negated) line = line[1..];
            if (line.Length == 0) continue;
            var directoryOnly = line.EndsWith('/');
            var anchored = line.StartsWith('/');
            line = line.Trim('/');
            if (line.Length == 0) continue;
            var hasSlash = line.Contains('/') || anchored;
            rules.Add(new Rule(basePath, line, negated, directoryOnly, Glob(line), hasSlash));
        }
        return rules;
    }

    private static bool IsIgnored(string path, IReadOnlyList<Rule> rules)
    {
        var ignored = false;
        foreach (var rule in rules)
        {
            var candidate = rule.Base.Length == 0 ? path
                : path.StartsWith(rule.Base + "/", StringComparison.Ordinal) ? path[(rule.Base.Length + 1)..]
                : path == rule.Base ? ""
                : null;
            if (candidate is null || candidate.Length == 0) continue;
            var ancestors = Ancestors(candidate).ToList();
            if (rule.DirectoryOnly && ancestors.Count > 0) ancestors.RemoveAt(ancestors.Count - 1);
            var components = candidate.Split('/');
            var matchingComponents = rule.DirectoryOnly ? components.Take(Math.Max(0, components.Length - 1)) : components;
            var matched = rule.HasSlash
                ? ancestors.Any(part => rule.Matcher.IsMatch(part))
                : matchingComponents.Any(part => rule.Matcher.IsMatch(part));
            if (matched) ignored = !rule.Negated;
        }
        return ignored;
    }

    private static IEnumerable<string> Ancestors(string path)
    {
        var parts = path.Split('/');
        for (var count = 1; count <= parts.Length; count++) yield return string.Join("/", parts.Take(count));
    }

    private static Regex Glob(string pattern)
    {
        var regex = new StringBuilder("^");
        for (var index = 0; index < pattern.Length; index++)
        {
            var current = pattern[index];
            if (current == '*')
            {
                if (index + 1 < pattern.Length && pattern[index + 1] == '*')
                {
                    index++;
                    if (index + 1 < pattern.Length && pattern[index + 1] == '/')
                    {
                        index++;
                        regex.Append("(?:.*/)?");
                    }
                    else regex.Append(".*");
                }
                else regex.Append("[^/]*");
            }
            else if (current == '?') regex.Append("[^/]");
            else regex.Append(Regex.Escape(current.ToString()));
        }
        regex.Append('$');
        return new Regex(regex.ToString(), RegexOptions.Compiled | RegexOptions.CultureInvariant);
    }

    private static HashSet<string> ReadIncludes(string root)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        string[] lines;
        try { lines = File.ReadAllLines(Path.Combine(root, IncludeFileName), Encoding.UTF8); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return result; }
        foreach (var raw in lines)
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#') || line.Contains('*') || line.Contains('?') || Path.IsPathRooted(line)) continue;
            var relative = Normalize(line);
            if (relative.Length == 0 || relative.Split('/').Any(part => part is ".." or ".")) continue;
            result.Add(relative);
        }
        return result;
    }

    private static bool IsRegularFile(string root, string relative)
    {
        var current = Path.GetFullPath(root);
        var parts = relative.Split('/');
        for (var index = 0; index < parts.Length; index++)
        {
            current = Path.Combine(current, parts[index]);
            if (NativeWorkspaceTools.IsSymlink(current)) return false;
            if (index == parts.Length - 1) return File.Exists(current);
        }
        return false;
    }

    private static bool IsDefaultSkippedDirectory(string relative) =>
        relative.Split('/').Any(part => NativeWorkspaceTools.IgnoredScanDirectories.Contains(part));

    private static bool IsPrivateExcluded(string relative)
    {
        var parts = relative.Split('/');
        if (parts.Any(part => part.Equals(".git", StringComparison.OrdinalIgnoreCase)
            || part.Equals(".mem", StringComparison.OrdinalIgnoreCase)
            || part.Equals(".ssh", StringComparison.OrdinalIgnoreCase)
            || part.Equals(".gnupg", StringComparison.OrdinalIgnoreCase))) return true;
        var name = parts[^1];
        if (name.Equals(IgnoreFileName, StringComparison.OrdinalIgnoreCase)
            || name.Equals(IncludeFileName, StringComparison.OrdinalIgnoreCase)
            || name.StartsWith(".env", StringComparison.OrdinalIgnoreCase)
            || SensitiveNames.Contains(name)
            || name.EndsWith(".secret", StringComparison.OrdinalIgnoreCase)) return true;
        return SensitiveExtensions.Contains(Path.GetExtension(name));
    }

    private static string Normalize(string path)
    {
        var normalized = path.Replace('\\', '/');
        while (normalized.StartsWith("./", StringComparison.Ordinal)) normalized = normalized[2..];
        return normalized;
    }
}
