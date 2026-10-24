// Copyright (c) 2026 DOTS
// Small workspace-scoped tools used by the in-process .NET agent loop.

using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public static class NativeWorkspaceTools
{
    public const string GeneratedMediaName = "copy_generated_media";
    public const string GeneratedMediaInspectionName = "inspect_generated_media";
    private const string VerifiedRemovalMarker = "[cleanup:verified]";
    private const string PreservedRemovalMarker = "[cleanup:preserved]";
    private const string FailedRemovalMarker = "[cleanup:failed]";
    private static readonly HashSet<string> CleanupExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".c", ".cc", ".cpp", ".cs", ".csproj", ".gradle", ".h", ".hpp", ".ini", ".java", ".js", ".jsx",
        ".json", ".kts", ".kt", ".m", ".mm", ".php", ".plist", ".props", ".py", ".resx", ".rs", ".swift",
        ".targets", ".toml", ".ts", ".tsx", ".xml", ".xaml", ".yaml", ".yml",
    };
    // The one list of build, dependency and runtime trees no search descends into, applied
    // even inside a repository: .sandbox-cache is written by HerNess and is in no .gitignore.
    // Mirrors WorkspaceTools.ignoredScanDirectories on macOS.
    internal static readonly HashSet<string> IgnoredScanDirectories = new(StringComparer.OrdinalIgnoreCase)
    {
        ".git", ".mem", ".build", "build", "bin", "obj", "dist", "node_modules", "Pods", "DerivedData",
        ".sandbox-cache", ".gradle", "target", "vendor", ".next", ".venv", "__pycache__", "coverage",
    };
    private static readonly HashSet<string> ProtectedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "provider-state.json", "conversations.json", "state.sqlite", "state.db",
    };
    public static IReadOnlyList<NativeToolDefinition> Definitions { get; } =
    [
        new("list_files", "List files and directories inside the current workspace.", Schema(("path", "Relative path. Use . for the workspace root.", false))),
        new("read_file", "Read a UTF-8 text file inside the current workspace. Returns 250 lines by default; a longer file ends with a continuation line naming the next offset. Prefer a narrow offset/limit range for relevant sections. edit_file only needs the lines it replaces to have been read; read every page only when write_file will rewrite the whole file.", Schema(
            ("path", "Relative path to the file.", true),
            ("offset", "First line to read, 1-based. Defaults to the start of the file.", false),
            ("limit", "How many lines to read. Defaults to 250.", false))),
        new("write_file", "Create or replace a UTF-8 text file inside the current workspace. It writes the whole file, so read an existing file first: rewriting one you have not read, or one that changed since you read it, is refused.", Schema(("path", "Relative path to the file.", true), ("content", "Complete file contents.", true))),
        new("remove_file", "Remove one unused source/config/test/import file only after references are checked.", Schema(
            ("path", "Relative path to the file to remove.", true),
            ("reason", "Why this old artifact is no longer needed.", true),
            ("referenceTerms", "Old symbols or paths to search for, separated by commas or new lines.", true))),
        new("grep_files", "Search file contents inside the workspace with a regular expression and get back path:line:text matches. Prefer this over a shell grep: it skips build and dependency directories, bounds its own output, and answers in one call.", Schema(
            ("pattern", "Regular expression to match against each line.", true),
            ("path", "Relative directory to search. Defaults to the workspace root.", false),
            ("extensions", "Optional comma-separated file extensions to limit the search, e.g. cs,json.", false))),
        new("run_command", "Run a shell command in the workspace. The timeout is enforced as requested (default 120 seconds, maximum 600). If a build lock times out the command, use wait_command with its holder PID and rerun instead of polling.", Schema(
            ("command", "Command to run in the workspace.", true),
            ("timeout_seconds", "Seconds before the command is stopped. Default 120, maximum 600.", false))),
        new("wait_command", "Wait for a process by PID, including a SwiftPM build lock holder. Default and maximum wait: 600 seconds. Do not poll with sleep or kill -0 loops.", Schema(
            ("pid", "Process ID to wait for.", true),
            ("log_path", "Optional workspace-relative log file to include after the wait.", false),
            ("timeout_seconds", "Seconds to wait. Default and maximum 600.", false))),
        .. NativeFileEdit.Definitions,
        new(GeneratedMediaName, "Copy a generated image from the current conversation into the current coding workspace. Use this before editing project files that should reference the asset.", Schema(
            ("source_path", "Exact absolute path from the Generated media artifact context.", true),
            ("destination_path", "Workspace-relative destination path, including the filename.", true))),
        new(GeneratedMediaInspectionName, "Inspect a generated image only when its visual content is needed. The normal conversation carries only the exact file path; this tool attaches that file to the next model request for visual inspection.", Schema(
            ("source_path", "Exact absolute path from the Generated media artifact context.", true),
            ("instruction", "Optional visual inspection question.", false))),
    ];

    /// What plan mode offers: everything except the tools that change the
    /// workspace. Plan mode gathers evidence - it may run a check - it never applies.
    public static IReadOnlyList<NativeToolDefinition> PlanDefinitions { get; } =
        Definitions.Where(tool => !IsWorkspaceMutation(tool.Name)).ToArray();

    public static bool IsReadOnly(string name) =>
        name is "list_files" or "read_file" or "grep_files" or "wait_command" or NativeFileEdit.GlobName or GeneratedMediaInspectionName;

    public static bool IsWorkspaceMutation(string name) =>
        name is "write_file" or NativeFileEdit.EditName or "remove_file" or GeneratedMediaName;

    public static bool IsVerifiedRemovalResult(string result) => result.StartsWith(VerifiedRemovalMarker, StringComparison.Ordinal);
    public static bool IsPreservedRemovalResult(string result) => result.StartsWith(PreservedRemovalMarker, StringComparison.Ordinal);
    public static bool IsFailedRemovalResult(string result) => result.StartsWith(FailedRemovalMarker, StringComparison.Ordinal);

    public static bool MayDeleteFiles(string? command)
    {
        if (string.IsNullOrWhiteSpace(command)) return false;
        return System.Text.RegularExpressions.Regex.IsMatch(
            command,
            @"(^|[\s;&|])(rm|unlink|del|erase|rmdir|Remove-Item|git\s+clean)([\s;&|]|$)",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    }

    public static async Task<string> ExecuteAsync(
        NativeToolCall call,
        string workspace,
        CancellationToken ct = default,
        AgentCommandSandboxMode commandSandbox = AgentCommandSandboxMode.Legacy,
        IReadOnlyList<string>? additionalWritableRoots = null,
        bool networkAccess = false)
    {
        try
        {
            var input = JsonNode.Parse(call.Arguments)?.AsObject() ?? new JsonObject();
            return call.Name switch
            {
                "list_files" => ListFiles(input["path"]?.GetValue<string>() ?? ".", workspace),
                "read_file" => ReadFile(
                    input["path"]?.GetValue<string>(),
                    Count(input["offset"]),
                    Count(input["limit"]),
                    workspace),
                "grep_files" => GrepFiles(
                    input["pattern"]?.GetValue<string>(),
                    input["path"]?.GetValue<string>() ?? ".",
                    input["extensions"]?.GetValue<string>(),
                    workspace),
                "write_file" => WriteFile(input["path"]?.GetValue<string>(), input["content"]?.GetValue<string>(), workspace),
                NativeFileEdit.EditName or NativeFileEdit.GlobName => NativeFileEdit.Execute(call, workspace),
                "remove_file" => RemoveFile(input["path"]?.GetValue<string>(), input["reason"]?.GetValue<string>(), input["referenceTerms"]?.GetValue<string>(), workspace),
                "run_command" when IsSleepPoll(input["command"]?.GetValue<string>() ?? "") => SleepPollRefusal,
                "run_command" => await RunCommandAsync(
                    input["command"]?.GetValue<string>(),
                    workspace,
                    ct,
                    timeoutSeconds: CommandTimeout(input["timeout_seconds"]),
                    commandSandbox: commandSandbox,
                    additionalWritableRoots: additionalWritableRoots,
                    networkAccess: networkAccess),
                "wait_command" => await WaitForProcessAsync(
                    Count(input["pid"]),
                    input["log_path"]?.GetValue<string>(),
                    input["timeout_seconds"],
                    workspace,
                    ct),
                _ => $"Unknown tool: {call.Name}",
            };
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex) { return $"Tool error: {ex.Message}"; }
    }

    public static Task<string> ExecuteCommandStreamingAsync(
        string? command,
        string workspace,
        Action<string>? onOutput = null,
        CancellationToken ct = default,
        AgentCommandSandboxMode commandSandbox = AgentCommandSandboxMode.Legacy,
        IReadOnlyList<string>? additionalWritableRoots = null,
        bool networkAccess = false,
        int timeoutSeconds = DefaultCommandTimeout) =>
        RunCommandAsync(command, workspace, ct, onOutput, commandSandbox, additionalWritableRoots, networkAccess, timeoutSeconds);

    /// `sleep 30; tail log` loops resend the whole context every round for nothing.
    internal static bool IsSleepPoll(string command) =>
        System.Text.RegularExpressions.Regex.IsMatch(command, @"^\s*sleep\s+[0-9.]+\s*(?:;|&&|\n)");
    internal const string SleepPollRefusal = "Tool error: do not poll with sleep or kill -0. Call wait_command with the process PID (and optional log_path), or rerun the command in the foreground with a larger timeout_seconds (maximum 600).";

    public const int DefaultCommandTimeout = 120;
    public const int MaxCommandTimeout = 600;

    /// The model's timeout_seconds, clamped; anything missing or invalid is the default.
    public static int CommandTimeout(JsonNode? node) =>
        Count(node) is int seconds and > 0 ? Math.Min(seconds, MaxCommandTimeout) : DefaultCommandTimeout;

    public static int WaitCommandTimeout(JsonNode? node) =>
        Count(node) is int seconds and > 0 ? Math.Min(seconds, MaxCommandTimeout) : MaxCommandTimeout;

    private static readonly System.Text.RegularExpressions.Regex SwiftPmLockPattern = new(
        @"Another instance of SwiftPM(?: \(PID: (?<pid>\d+)\))? is already running",
        System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    internal static bool IsSwiftPmLockMessage(string? output) =>
        !string.IsNullOrEmpty(output) && SwiftPmLockPattern.IsMatch(output);

    /// SwiftPM waits silently while another process builds in the same directory;
    /// report its PID so the model can block on it, then retry the original command.
    internal static string LockNotice(string output)
    {
        var match = SwiftPmLockPattern.Match(output);
        if (!match.Success) return "";
        var pid = match.Groups["pid"].Value;
        var wait = pid.Length > 0
            ? $"Call wait_command with pid {pid} and timeout_seconds up to {MaxCommandTimeout}, then rerun the build."
            : "SwiftPM did not report a holder PID, so wait_command cannot target this lock.";
        return $"\nNote: another process is building in this package's .build directory. {wait} Do not pass a new --scratch-path because it rebuilds every dependency from scratch. If the holder stays at 0% CPU for minutes, tell the user instead of working around it.";
    }

    public static string CopyGeneratedMedia(
        string? sourcePath,
        string? destinationPath,
        string workspace,
        IEnumerable<string> allowedSourcePaths)
    {
        if (string.IsNullOrWhiteSpace(sourcePath) || string.IsNullOrWhiteSpace(destinationPath))
            return "Tool error: source_path and destination_path are required.";
        if (Path.IsPathRooted(destinationPath))
            return "Tool error: destination_path must be relative to the workspace.";

        var source = Path.GetFullPath(sourcePath);
        var allowed = allowedSourcePaths.Select(Path.GetFullPath).ToHashSet(
            OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
        if (!allowed.Contains(source) || !File.Exists(source))
            return "Tool error: the generated media artifact is not available in this conversation.";

        string destination;
        try { destination = Resolve(destinationPath, workspace); }
        catch (Exception ex) { return $"Tool error: {ex.Message}"; }
        if (File.Exists(destination)) return $"Tool error: destination already exists: {Path.GetRelativePath(workspace, destination)}";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Copy(source, destination);
            return $"Copied generated media to {Path.GetRelativePath(Path.GetFullPath(workspace), destination)}.";
        }
        catch (Exception ex) { return $"Tool error: could not copy generated media: {ex.Message}"; }
    }

    private static string ListFiles(string? path, string workspace)
    {
        var directory = Resolve(path, workspace);
        if (!Directory.Exists(directory)) return $"Not a directory: {path}";
        var entries = Directory.EnumerateFileSystemEntries(directory)
            .Where(item => !Path.GetFileName(item).Equals(".mem", StringComparison.Ordinal) && !Path.GetFileName(item).StartsWith(".", StringComparison.Ordinal))
            .ToList();
        var names = entries
            .OrderBy(item => Path.GetFileName(item), StringComparer.OrdinalIgnoreCase)
            .Take(200)
            .Select(item => Directory.Exists(item) ? Path.GetFileName(item) + Path.DirectorySeparatorChar : Path.GetFileName(item));
        var result = string.Join('\n', names);
        if (entries.Count > 200) result += $"\n[{entries.Count - 200} more entries not shown; use glob or a narrower path]";
        return result.Length == 0 ? "Directory is empty." : result;
    }

    private const int ReadMaxBytes = 60_000;
    /// A read without an explicit limit returns one page: most questions need a
    /// section, and a later page is one offset away.
    internal const int DefaultReadLines = 250;
    private const int DefaultReadMaxBytes = 20_000;

    /// Reads whole lines, never a partial one, and stops at <see cref="ReadMaxBytes"/>
    /// (<see cref="DefaultReadMaxBytes"/> when no limit was given).
    /// A cut answer names the line to continue from, so a long file stays reachable
    /// without falling back to a shell command.
    private static string ReadFile(string? path, int? offset, int? limit, string workspace)
    {
        if (string.IsNullOrWhiteSpace(path)) return "A file path is required.";
        var file = Resolve(path, workspace);
        var bytes = File.ReadAllBytes(file);
        string text;
        try { text = new UTF8Encoding(false, true).GetString(bytes); }
        catch (DecoderFallbackException) { return $"File is not UTF-8 text: {path}"; }

        var lines = text.Split('\n');
        var start = Math.Max(1, offset ?? 1);
        if (start > lines.Length) return $"Offset is past the end of the file; it has {lines.Length} lines.";
        var end = Math.Min(lines.Length, start + Math.Max(0, limit ?? DefaultReadLines) - 1);
        var maxBytes = limit is null ? DefaultReadMaxBytes : ReadMaxBytes;

        var emitted = new List<string>();
        var size = 0;
        var line = start;
        while (line <= end)
        {
            var candidate = lines[line - 1];
            var cost = Encoding.UTF8.GetByteCount(candidate) + 1;
            if (size + cost > maxBytes && emitted.Count > 0) break;
            emitted.Add(candidate);
            size += cost;
            line++;
        }
        var body = string.Join('\n', emitted);
        ReadLedger.RecordLines(file, bytes, start, line, lines.Length);
        // Any page that stops before the end of the file says where to continue and how
        // long the file is, so the model knows whether it has seen all of it.
        return line <= lines.Length ? body + $"\n\n[truncated] Continue with offset: {line} (file has {lines.Length} lines)" : body;
    }

    private static int? Count(JsonNode? node)
    {
        if (node is null) return null;
        try { return node.GetValue<int>(); } catch { }
        try
        {
            var raw = node.GetValue<string>();
            if (int.TryParse(raw, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var parsed)) return parsed;
        }
        catch { }
        return null;
    }

    private const int GrepMaxMatches = 100;
    private const int GrepMaxFiles = 5_000;
    private const int GrepMaxLineCharacters = 240;

    /// <summary>
    /// The files a search under `root` looks at. Inside a repository that is git's own list -
    /// tracked plus untracked, minus whatever .gitignore excludes - so a project's ignored
    /// output is never read; elsewhere a walk. Both skip IgnoredScanDirectories and symlinks.
    /// </summary>
    internal static IEnumerable<string> ScanFiles(string root)
    {
        // ponytail: git runs once per call; cache by .git/index stamp if large repositories feel it.
        var listed = WorkspaceFileIndex.Git(root, "-c", "core.quotePath=false", "ls-files", "--cached", "--others", "--exclude-standard");
        if (listed.Count > 0)
        {
            foreach (var relative in listed)
            {
                // A path git had to quote is skipped, as FileIndex does.
                if (relative.StartsWith('"') || relative.Split('/').Any(IgnoredScanDirectories.Contains)) continue;
                var entry = Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
                if (File.Exists(entry) && !IsSymlink(entry)) yield return entry;
            }
            yield break;
        }
        var pending = new Stack<string>();
        pending.Push(root);
        while (pending.Count > 0)
        {
            IEnumerable<string> entries;
            try { entries = Directory.EnumerateFileSystemEntries(pending.Pop()); } catch { continue; }
            foreach (var entry in entries)
            {
                if (IsSymlink(entry)) continue;
                if (Directory.Exists(entry))
                {
                    if (!IgnoredScanDirectories.Contains(Path.GetFileName(entry))) pending.Push(entry);
                }
                else if (File.Exists(entry)) yield return entry;
            }
        }
    }

    /// Line-level regex search, bounded on three axes so one call can never flood
    /// the context: files scanned, matches returned, and characters per line.
    private static string GrepFiles(string? pattern, string path, string? extensions, string workspace)
    {
        if (string.IsNullOrWhiteSpace(pattern)) return "A search pattern is required.";
        System.Text.RegularExpressions.Regex regex;
        try
        {
            regex = new System.Text.RegularExpressions.Regex(
                pattern,
                System.Text.RegularExpressions.RegexOptions.None,
                TimeSpan.FromSeconds(1));
        }
        catch (ArgumentException) { return $"Invalid search pattern: {pattern}"; }

        var root = Resolve(path, workspace);
        if (!Directory.Exists(root)) return $"Not a directory: {path}";
        var workspaceRoot = RealPath(Path.GetFullPath(workspace));
        var filter = (extensions ?? "")
            .Split([',', ' ', '\n', '\r'], StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Select(item => "." + item.TrimStart('.').ToLowerInvariant())
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        var matches = new List<string>();
        var scanned = 0;
        var truncated = false;
        foreach (var entry in ScanFiles(root))
        {
            if (filter.Count > 0 && !filter.Contains(Path.GetExtension(entry))) continue;
            if (++scanned > GrepMaxFiles) { truncated = true; break; }

            string[] lines;
            try { lines = File.ReadAllLines(entry, new UTF8Encoding(false, true)); }
            catch { continue; }
            var relative = Path.GetRelativePath(workspaceRoot, entry).Replace(Path.DirectorySeparatorChar, '/');
            for (var index = 0; index < lines.Length; index++)
            {
                try { if (!regex.IsMatch(lines[index])) continue; }
                catch (System.Text.RegularExpressions.RegexMatchTimeoutException) { continue; }
                var line = lines[index];
                var shown = line.Length > GrepMaxLineCharacters
                    ? line[..GrepMaxLineCharacters] + "\u2026"
                    : line;
                matches.Add($"{relative}:{index + 1}:{shown}");
                if (matches.Count >= GrepMaxMatches) { truncated = true; break; }
            }
            if (truncated) break;
        }

        if (matches.Count == 0) return "No matches.";
        return string.Join('\n', matches) + (truncated ? "\n\n[truncated]" : "");
    }

    private static string WriteFile(string? path, string? content, string workspace)
    {
        if (string.IsNullOrWhiteSpace(path)) return "A file path is required.";
        if (content is null) return "File content is required.";
        var file = Resolve(path, workspace);
        // write_file replaces the whole file, so an unread or externally changed file
        // would lose whatever the model never saw. Refuse instead.
        if (File.Exists(file))
        {
            switch (ReadLedger.StateOf(file, File.ReadAllBytes(file)))
            {
                case ReadState.Unread:
                    return $"Read {path} before rewriting it: write_file replaces the whole file.";
                case ReadState.Stale:
                    return $"{path} changed on disk since you read it. Read it again before rewriting.";
            }
        }
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        // A symlinked component would let the write land somewhere the
        // prefix check never saw. remove_file already refuses those.
        var canonicalRoot = RealPath(Path.GetFullPath(workspace));
        if (HasSymlinkComponentBelowRoot(canonicalRoot, path) || IsExistingSymlink(file))
            return $"Symlinked paths cannot be written: {path}";
        var temporary = file + "." + Guid.NewGuid().ToString("N") + ".part";
        try
        {
            File.WriteAllText(temporary, content, new UTF8Encoding(false));
            File.Move(temporary, file, overwrite: true);
        }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); } catch { }
        }
        ReadLedger.Record(file, Encoding.UTF8.GetBytes(content));
        return $"Wrote {Path.GetRelativePath(Path.GetFullPath(workspace), file)} ({Encoding.UTF8.GetByteCount(content)} bytes).";
    }

    private static string RemoveFile(string? path, string? reason, string? referenceTerms, string workspace)
    {
        if (string.IsNullOrWhiteSpace(path)) return $"{FailedRemovalMarker} A file path is required.";
        if (string.IsNullOrWhiteSpace(reason)) return $"{FailedRemovalMarker} A removal reason is required.";
        if (string.IsNullOrWhiteSpace(referenceTerms)) return $"{FailedRemovalMarker} Reference search terms are required.";
        var terms = referenceTerms.Split([',', ';', '\n', '\r'], StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        if (terms.Length == 0) return $"{FailedRemovalMarker} Reference search terms are required.";
        if (terms.Length > 20 || terms.Any(term => term.Length > 200))
            return $"{PreservedRemovalMarker} Reference search could not be bounded; file was kept.";

        var lexical = Path.GetFullPath(Path.Combine(Path.GetFullPath(workspace), path));
        var file = Resolve(path, workspace);
        if (!File.Exists(file)) return $"{PreservedRemovalMarker} File was not found: {path}";
        if (HasSymlinkComponent(Path.GetFullPath(workspace), path)
            || IsSymlink(file)
            || File.GetAttributes(lexical).HasFlag(FileAttributes.ReparsePoint))
            return $"{PreservedRemovalMarker} Symlink removal is not allowed: {path}";
        if (Directory.Exists(file)) return $"{PreservedRemovalMarker} Directory removal is not allowed: {path}";
        if (!IsCleanupCandidate(file)) return $"{PreservedRemovalMarker} This file is protected from agent cleanup: {path}";

        // Same canonical form as `file` (Resolve follows links), or the scan would not
        // recognise the target and would report it as a reference to itself.
        var root = RealPath(Path.GetFullPath(workspace));
        try
        {
            foreach (var candidate in ScanFiles(root, file))
            {
                var text = File.ReadAllText(candidate, new UTF8Encoding(false, true));
                if (terms.Any(term => text.Contains(term, StringComparison.Ordinal)))
                    return $"{PreservedRemovalMarker} Live reference found; file was kept: {Path.GetRelativePath(root, file)}";
            }
        }
        catch (Exception ex)
        {
            return $"{PreservedRemovalMarker} Reference scan could not be verified; file was kept: {ex.Message}";
        }

        try
        {
            File.Delete(file);
            if (File.Exists(file)) return $"{FailedRemovalMarker} File deletion could not be verified: {path}";
            return $"{VerifiedRemovalMarker} Removed {Path.GetRelativePath(root, file)}. Reason: {reason.Trim()}";
        }
        catch (Exception ex)
        {
            return $"{FailedRemovalMarker} File deletion failed: {ex.Message}";
        }
    }

    private static IEnumerable<string> ScanFiles(string root, string target)
    {
        var count = 0;
        var pending = new Stack<string>();
        pending.Push(root);
        while (pending.Count > 0)
        {
            var directory = pending.Pop();
            foreach (var entry in Directory.EnumerateFileSystemEntries(directory))
            {
                if (IsIgnoredScanPath(entry, root) || IsSymlink(entry)) continue;
                if (Directory.Exists(entry))
                {
                    pending.Push(entry);
                    continue;
                }
                if (!File.Exists(entry)
                    || string.Equals(entry, target, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)
                    || !IsCleanupCandidate(entry)) continue;
                if (++count > 5_000) throw new IOException("Reference scan limit reached.");
                yield return entry;
            }
        }
    }

    private static bool IsIgnoredScanPath(string path, string root) =>
        Path.GetRelativePath(root, path).Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            .Any(part => IgnoredScanDirectories.Contains(part));

    private static bool HasSymlinkComponent(string root, string path)
    {
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var basePath = Path.GetFullPath(root);
        var current = Path.GetFullPath(Path.Combine(basePath, path));
        while (true)
        {
            if (IsSymlink(current)) return true;
            if (current.Equals(basePath, comparison)) return false;
            var parent = Directory.GetParent(current)?.FullName;
            if (string.IsNullOrEmpty(parent) || parent.Equals(current, comparison)) return true;
            current = parent;
        }
    }

    private static bool IsCleanupCandidate(string path)
    {
        var name = Path.GetFileName(path);
        if (ProtectedNames.Contains(name) || name.StartsWith(".env", StringComparison.OrdinalIgnoreCase)) return false;
        if (name.Contains("credential", StringComparison.OrdinalIgnoreCase)
            || name.Contains("secret", StringComparison.OrdinalIgnoreCase)
            || name.Contains("token", StringComparison.OrdinalIgnoreCase)
            || name.Contains("password", StringComparison.OrdinalIgnoreCase)
            || name.Contains("keychain", StringComparison.OrdinalIgnoreCase)
            || name.Contains("keystore", StringComparison.OrdinalIgnoreCase)) return false;
        if (Path.GetExtension(name) is ".db" or ".sqlite" or ".sqlite3" or ".pem" or ".key" or ".p12" or ".pfx") return false;
        return CleanupExtensions.Contains(Path.GetExtension(name));
    }

    private static async Task<string> RunCommandAsync(
        string? command,
        string workspace,
        CancellationToken ct,
        Action<string>? onOutput = null,
        AgentCommandSandboxMode commandSandbox = AgentCommandSandboxMode.Legacy,
        IReadOnlyList<string>? additionalWritableRoots = null,
        bool networkAccess = false,
        int timeoutSeconds = DefaultCommandTimeout)
    {
        if (string.IsNullOrWhiteSpace(command)) return "A command is required.";
        var info = new ProcessStartInfo
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Path.GetFullPath(workspace),
            CreateNoWindow = true,
        };
        if (commandSandbox == AgentCommandSandboxMode.StrictNoDesktop && !AgentCommandSandbox.IsAvailable && AgentCommandIsolation.Current is { } isolation)
        {
            // Windows isolates through a registered runner; it fails closed when the runner cannot prove isolation.
            var roots = additionalWritableRoots ?? [];
            if (isolation.Unavailable(workspace, roots, networkAccess) is { } reason) return $"Tool error: {reason}";
            var isolated = await isolation.RunAsync(command, workspace, roots, onOutput, TimeSpan.FromSeconds(timeoutSeconds), ct);
            if (isolated.Error is not null) return $"Tool error: {isolated.Error}";
            if (isolated.TimedOut)
            {
                var partial = KeepHeadAndTail((isolated.Stdout + isolated.Stderr).Trim());
                return $"Command timed out after {timeoutSeconds} seconds." + LockNotice(partial) + "\n" + partial;
            }
            var isolatedText = (isolated.Stdout + isolated.Stderr).Trim();
            if (isolatedText.Length > 100_000) isolatedText = isolatedText[..100_000] + "\n[truncated]";
            var status = isolated.ExitCode ?? -1;
            return string.IsNullOrEmpty(isolatedText) ? $"Command exited with status {status}." : isolatedText + (status == 0 ? "" : $"\nCommand exited with status {status}.") + LockNotice(isolatedText);
        }
        if (commandSandbox == AgentCommandSandboxMode.StrictNoDesktop)
        {
            if (!AgentCommandSandbox.TryConfigure(info, workspace, out var error, additionalWritableRoots, networkAccess))
                return $"Tool error: {error}";
            info.ArgumentList.Add(command);
        }
        else
        {
            info.FileName = OperatingSystem.IsWindows() ? "cmd.exe" : "/bin/sh";
            info.ArgumentList.Add(OperatingSystem.IsWindows() ? "/c" : "-lc");
            info.ArgumentList.Add(command);
        }
        using var process = Process.Start(info) ?? throw new InvalidOperationException("The command could not start.");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        var output = ReadLinesAsync(process.StandardOutput, stdout, onOutput, timeout.Token);
        var errors = ReadLinesAsync(process.StandardError, stderr, onOutput, timeout.Token);
        try
        {
            await process.WaitForExitAsync(timeout.Token);
            await Task.WhenAll(output, errors);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
            try { await Task.WhenAll(output, errors); } catch { }
            // Keep what it printed: where a build stopped, or a lock it was waiting on.
            string partial;
            lock (stdout) lock (stderr) partial = KeepHeadAndTail((stdout.ToString() + stderr.ToString()).Trim());
            return $"Command timed out after {timeoutSeconds} seconds." + LockNotice(partial) + "\n" + partial;
        }
        catch
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
            try { await Task.WhenAll(output, errors); } catch { }
            throw;
        }
        var text = (stdout.ToString() + stderr.ToString()).Trim();
        text = KeepHeadAndTail(text);
        return string.IsNullOrEmpty(text) ? $"Command exited with status {process.ExitCode}." : text + (process.ExitCode == 0 ? "" : $"\nCommand exited with status {process.ExitCode}.") + LockNotice(text);
    }

    private static async Task<string> WaitForProcessAsync(
        int? processId,
        string? logPath,
        JsonNode? timeoutNode,
        string workspace,
        CancellationToken ct)
    {
        if (processId is not int pid || pid <= 1) return "Tool error: pid must be a process id greater than 1.";
        string? resolvedLog = null;
        try
        {
            if (!string.IsNullOrWhiteSpace(logPath)) resolvedLog = Resolve(logPath, workspace);
        }
        catch (Exception error) { return $"Tool error: {error.Message}"; }

        Process process;
        try { process = Process.GetProcessById(pid); }
        catch (ArgumentException) { return $"Process {pid} is not running."; }

        var timeoutSeconds = WaitCommandTimeout(timeoutNode);
        var started = Stopwatch.StartNew();
        using (process)
        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            timeout.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
            try { await process.WaitForExitAsync(timeout.Token); }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                var stillRunning = $"Process {pid} is still running after {Math.Floor(started.Elapsed.TotalSeconds):0}s.";
                return AppendLogTail(stillRunning, resolvedLog);
            }
        }

        var completed = $"Process {pid} exited after {Math.Floor(started.Elapsed.TotalSeconds):0}s.";
        return AppendLogTail(completed, resolvedLog);
    }

    private static string AppendLogTail(string result, string? path)
    {
        if (path is null) return result;
        try
        {
            const int maxCharacters = 8_000;
            using var stream = File.OpenRead(path);
            if (stream.Length > maxCharacters * 4L) stream.Seek(-maxCharacters * 4L, SeekOrigin.End);
            using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
            var text = reader.ReadToEnd();
            if (text.Length > maxCharacters) text = text[^maxCharacters..];
            return result + "\n" + text;
        }
        catch { return result + "\n(log unreadable)"; }
    }

    /// Long command output keeps its start and its end, where build and test
    /// failures land; the middle is rarely what the next step needs.
    internal static string KeepHeadAndTail(string text, int head = 2_000, int tail = 14_000) =>
        text.Length <= head + tail
            ? text
            : text[..head] + $"\n[... {text.Length - head - tail} characters omitted ...]\n" + text[^tail..];

    /// Whether a run_command result reports exit status 0.
    // ponytail: read from RunCommandAsync's fixed English wording; return the exit
    // code from there instead if that wording is ever localized.
    public static bool CommandSucceeded(string result) =>
        !result.StartsWith("Tool error:", StringComparison.Ordinal)
        && !result.StartsWith("Command timed out", StringComparison.Ordinal)
        && result != "A command is required."
        && (result.EndsWith("Command exited with status 0.", StringComparison.Ordinal)
            || !System.Text.RegularExpressions.Regex.IsMatch(result, @"Command exited with status -?\d+\.$"));

    private static async Task ReadLinesAsync(StreamReader reader, StringBuilder target, Action<string>? onOutput, CancellationToken ct)
    {
        while (await reader.ReadLineAsync(ct) is { } line)
        {
            lock (target) target.AppendLine(line);
            onOutput?.Invoke(line);
        }
    }

    internal static string Resolve(string? path, string workspace)
    {
        var root = RealPath(Path.GetFullPath(workspace));
        var full = RealPath(Path.GetFullPath(Path.Combine(root, string.IsNullOrWhiteSpace(path) ? "." : path)));
        var rootPrefix = root.EndsWith(Path.DirectorySeparatorChar) ? root : root + Path.DirectorySeparatorChar;
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (!full.Equals(root, comparison) && !full.StartsWith(rootPrefix, comparison)) throw new InvalidOperationException($"Path is outside the workspace: {path}");
        var memory = Path.Combine(root, ".mem");
        if (full.Equals(memory, comparison) || full.StartsWith(memory + Path.DirectorySeparatorChar, comparison)) throw new InvalidOperationException("This path is unavailable.");
        return full;
    }

    // Canonicalize each existing path component, following symlinks, so an in-workspace
    // symlink cannot redirect a path past the prefix check. Path.GetFullPath only
    // normalizes syntax and leaves symlinks intact.
    private static string RealPath(string path)
    {
        var full = Path.GetFullPath(path);
        var root = Path.GetPathRoot(full);
        if (string.IsNullOrEmpty(root)) return full;
        var result = root.TrimEnd(Path.DirectorySeparatorChar);
        if (result.Length == 0) result = Path.DirectorySeparatorChar.ToString();
        foreach (var part in full[root.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            result = Path.Combine(result, part);
            try
            {
                var link = Directory.Exists(result)
                    ? new DirectoryInfo(result).ResolveLinkTarget(true)
                    : File.Exists(result) ? new FileInfo(result).ResolveLinkTarget(true) : null;
                if (link is not null)
                {
                    result = link.FullName;
                    continue;
                }
                // A broken symlink has no target to follow, but a write through
                // it still lands on the raw target — which may sit outside the
                // workspace. The syntactic path cannot be trusted, so the raw
                // target is what the prefix check has to judge.
                var raw = new FileInfo(result).LinkTarget;
                if (string.IsNullOrEmpty(raw)) continue;
                result = Path.IsPathRooted(raw)
                    ? Path.GetFullPath(raw)
                    : Path.GetFullPath(Path.Combine(Path.GetDirectoryName(result) ?? root, raw));
            }
            catch
            {
                // Unreadable component: keep the syntactic path and let the prefix check decide.
            }
        }
        return result;
    }

    internal static bool IsSymlink(string path)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            return attributes.HasFlag(FileAttributes.ReparsePoint)
                || (File.Exists(path) ? new FileInfo(path).LinkTarget is not null : new DirectoryInfo(path).LinkTarget is not null);
        }
        catch { return true; }
    }

    /// True when the path exists and is a symbolic link. A path that does not
    /// exist yet cannot be one, and a broken link still counts: a write
    /// through it would land on its target.
    private static bool IsExistingSymlink(string path)
    {
        try
        {
            if (new FileInfo(path).LinkTarget is not null) return true;
            if (new DirectoryInfo(path).LinkTarget is not null) return true;
            return false;
        }
        catch { return false; }
    }

    /// True when a component strictly below the workspace root is a symlink.
    /// The root's own ancestors are ignored: on macOS `/var` is a symlink to
    /// `/private/var`, and every temporary workspace lives under it.
    private static bool HasSymlinkComponentBelowRoot(string root, string path)
    {
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var basePath = Path.GetFullPath(root);
        var current = Path.GetFullPath(Path.Combine(basePath, path));
        while (!current.Equals(basePath, comparison))
        {
            if (IsExistingSymlink(current)) return true;
            var parent = Directory.GetParent(current)?.FullName;
            if (string.IsNullOrEmpty(parent) || parent.Equals(current, comparison)) return false;
            current = parent;
        }
        return false;
    }

    private static JsonNode Schema(params (string Name, string Description, bool Required)[] fields)
    {
        var properties = new JsonObject();
        var required = new JsonArray();
        foreach (var field in fields)
        {
            var type = field.Name is "offset" or "limit" or "timeout_seconds" ? "integer" : "string";
            properties[field.Name] = new JsonObject { ["type"] = type, ["description"] = field.Description };
            if (field.Required) required.Add(field.Name);
        }
        var schema = new JsonObject { ["type"] = "object", ["properties"] = properties };
        if (required.Count > 0) schema["required"] = required;
        return schema;
    }

}

public enum ReadState { Fresh, Stale, Unread }

// ponytail: global ledger (512 cap) — cross-conversation reuse can allow blind write without re-read; per-conversation ledger if that matters.
 /// <summary>
/// Remembers the content hash of every file the agent has fully read, so
/// <c>write_file</c> can tell an informed rewrite from a blind one. Session-scoped
/// and bounded; forgetting an entry only costs one extra read.
/// </summary>
public static class ReadLedger
{
    private const int Capacity = 512;
    private static readonly object Gate = new();
    private static readonly Dictionary<string, string> Hashes = new(StringComparer.Ordinal);
    private sealed record PageRead(string Hash, List<(int Start, int End)> Ranges);
    private static readonly Dictionary<string, PageRead> Pages = new(StringComparer.Ordinal);
    private static readonly Queue<string> Order = new();
    private static readonly AsyncLocal<string?> ScopeSlot = new();

    /// <summary>
    /// Separates a subagent's reads from the conversation's. A file the subagent read
    /// is not one the conversation saw, and the other way round, so neither may count
    /// as the other's permission to rewrite it. Flows with the async call that set it.
    /// </summary>
    public static string? Scope
    {
        get => ScopeSlot.Value;
        set => ScopeSlot.Value = value;
    }

    private static string Key(string file) => Scope is { } scope ? scope + "\n" + file : file;

    public static void RecordLines(string file, byte[] content, int start, int end, int totalLines)
    {
        if (end <= start) return;
        file = Key(file);
        var hash = Hash(content);
        lock (Gate)
        {
            if (Hashes.TryGetValue(file, out var known) && known == hash) return;
            if (!Hashes.ContainsKey(file) && !Pages.ContainsKey(file)) Order.Enqueue(file);
            Hashes.Remove(file);
            var ranges = Pages.TryGetValue(file, out var page) && page.Hash == hash
                ? page.Ranges : new List<(int Start, int End)>();
            ranges.Add((start, end));
            var merged = new List<(int Start, int End)>();
            foreach (var range in ranges.OrderBy(range => range.Start))
            {
                if (merged.Count > 0 && range.Start <= merged[^1].End)
                    merged[^1] = (merged[^1].Start, Math.Max(merged[^1].End, range.End));
                else merged.Add(range);
            }
            if (merged.Count == 1 && merged[0].Start == 1 && merged[0].End > totalLines)
            {
                Hashes[file] = hash;
                Pages.Remove(file);
            }
            else Pages[file] = new PageRead(hash, merged);
            while (Order.Count > Capacity)
            {
                var oldest = Order.Dequeue();
                Hashes.Remove(oldest);
                Pages.Remove(oldest);
            }
        }
    }

    public static void Record(string file, byte[] content)
    {
        file = Key(file);
        var hash = Hash(content);
        lock (Gate)
        {
            if (!Hashes.ContainsKey(file) && !Pages.ContainsKey(file)) Order.Enqueue(file);
            Hashes[file] = hash;
            Pages.Remove(file);
            while (Order.Count > Capacity)
            {
                var oldest = Order.Dequeue();
                Hashes.Remove(oldest);
                Pages.Remove(oldest);
            }
        }
    }

    public static void Forget(string file)
    {
        file = Key(file);
        lock (Gate)
        {
            Hashes.Remove(file);
            Pages.Remove(file);
        }
    }

    /// <summary>
    /// Drops every read made under <paramref name="scope"/>. Context compaction calls
    /// this: once the file bodies are out of the model's context, a recorded read no
    /// longer means the model has seen those bytes.
    /// </summary>
    public static void ForgetScope(string scope)
    {
        var prefix = scope + "\n";
        lock (Gate)
        {
            foreach (var key in Hashes.Keys.Concat(Pages.Keys).Where(key => key.StartsWith(prefix, StringComparison.Ordinal)).ToList())
            {
                Hashes.Remove(key);
                Pages.Remove(key);
            }
        }
    }

    /// <summary>
    /// Line ranges (1-based, end exclusive) the agent read from exactly this version.
    /// A complete read is one range over the whole file. Stale when an older version
    /// was read; Unread when nothing was.
    /// </summary>
    public static (ReadState State, List<(int Start, int End)> Ranges) Coverage(string file, byte[] content, int totalLines)
    {
        file = Key(file);
        var hash = Hash(content);
        lock (Gate)
        {
            if (Hashes.TryGetValue(file, out var known))
                return known == hash ? (ReadState.Fresh, [(1, totalLines + 1)]) : (ReadState.Stale, []);
            if (Pages.TryGetValue(file, out var page))
                return page.Hash == hash ? (ReadState.Fresh, page.Ranges.ToList()) : (ReadState.Stale, []);
            return (ReadState.Unread, []);
        }
    }

    public static ReadState StateOf(string file, byte[] content, bool partial = false)
    {
        file = Key(file);
        string? known;
        lock (Gate)
        {
            if (!Hashes.TryGetValue(file, out known) && partial && Pages.TryGetValue(file, out var page))
                known = page.Hash;
        }
        if (known is null) return ReadState.Unread;
        return known == Hash(content) ? ReadState.Fresh : ReadState.Stale;
    }

    /// Test seam: a fresh ledger per test keeps the shared one out of it.
    public static void Reset()
    {
        lock (Gate)
        {
            Hashes.Clear();
            Pages.Clear();
            Order.Clear();
        }
    }

    private static string Hash(byte[] content) =>
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(content));
}
