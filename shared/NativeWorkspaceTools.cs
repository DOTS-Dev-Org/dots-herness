// Copyright (c) 2026 DOTS
// Small workspace-scoped tools used by the in-process .NET agent loop.

using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public static class NativeWorkspaceTools
{
    private const string VerifiedRemovalMarker = "[cleanup:verified]";
    private const string PreservedRemovalMarker = "[cleanup:preserved]";
    private const string FailedRemovalMarker = "[cleanup:failed]";
    private static readonly HashSet<string> CleanupExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".c", ".cc", ".cpp", ".cs", ".csproj", ".gradle", ".h", ".hpp", ".ini", ".java", ".js", ".jsx",
        ".json", ".kts", ".kt", ".m", ".mm", ".php", ".plist", ".props", ".py", ".resx", ".rs", ".swift",
        ".targets", ".toml", ".ts", ".tsx", ".xml", ".xaml", ".yaml", ".yml",
    };
    private static readonly HashSet<string> IgnoredScanDirectories = new(StringComparer.OrdinalIgnoreCase)
    {
        ".git", ".mem", ".build", "build", "bin", "obj", "dist", "node_modules", "Pods", "DerivedData",
    };
    private static readonly HashSet<string> ProtectedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "provider-state.json", "conversations.json", "state.sqlite", "state.db",
    };
    public static IReadOnlyList<NativeToolDefinition> Definitions { get; } =
    [
        new("list_files", "List files and directories inside the current workspace.", Schema(("path", "Relative path. Use . for the workspace root.", false))),
        new("read_file", "Read a UTF-8 text file inside the current workspace. Long files come back truncated with the line to continue from; pass offset to read the rest.", Schema(
            ("path", "Relative path to the file.", true),
            ("offset", "First line to read, 1-based. Defaults to the start of the file.", false),
            ("limit", "How many lines to read. Defaults to as many as fit.", false))),
        new("write_file", "Create or replace a UTF-8 text file inside the current workspace. It writes the whole file, so read an existing file first: rewriting one you have not read, or one that changed since you read it, is refused.", Schema(("path", "Relative path to the file.", true), ("content", "Complete file contents.", true))),
        new("remove_file", "Remove one unused source/config/test/import file only after references are checked.", Schema(
            ("path", "Relative path to the file to remove.", true),
            ("reason", "Why this old artifact is no longer needed.", true),
            ("referenceTerms", "Old symbols or paths to search for, separated by commas or new lines.", true))),
        new("grep_files", "Search file contents inside the workspace with a regular expression and get back path:line:text matches. Prefer this over a shell grep: it skips build and dependency directories, bounds its own output, and answers in one call.", Schema(
            ("pattern", "Regular expression to match against each line.", true),
            ("path", "Relative directory to search. Defaults to the workspace root.", false),
            ("extensions", "Optional comma-separated file extensions to limit the search, e.g. cs,json.", false))),
        new("run_command", "Run a shell command with the workspace as its current directory.", Schema(("command", "Command to run in the workspace.", true))),
    ];

    /// What plan mode offers: everything except the two tools that change the
    /// workspace. Plan mode gathers evidence - it may run a check - it never applies.
    public static IReadOnlyList<NativeToolDefinition> PlanDefinitions { get; } =
        Definitions.Where(tool => !IsWorkspaceMutation(tool.Name)).ToArray();

    /// Chat has no implicit workspace. Every filesystem call must name the
    /// verified root that came from a user message.
    public static IReadOnlyList<NativeToolDefinition> ChatDefinitions { get; } =
        Definitions.Select(AddContextRootId).ToArray();

    public static IReadOnlyList<NativeToolDefinition> ChatPlanDefinitions { get; } =
        ChatDefinitions.Where(tool => !IsWorkspaceMutation(tool.Name)).ToArray();

    public static bool IsReadOnly(string name) => name is "list_files" or "read_file" or "grep_files";

    public static bool IsWorkspaceMutation(string name) => name is "write_file" or "remove_file";

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
        AgentCommandSandboxMode commandSandbox = AgentCommandSandboxMode.Legacy)
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
                "remove_file" => RemoveFile(input["path"]?.GetValue<string>(), input["reason"]?.GetValue<string>(), input["referenceTerms"]?.GetValue<string>(), workspace),
                "run_command" => await RunCommandAsync(
                    input["command"]?.GetValue<string>(),
                    workspace,
                    ct,
                    commandSandbox: commandSandbox),
                _ => $"Unknown tool: {call.Name}",
            };
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex) { return $"Tool error: {ex.Message}"; }
    }

    public static async Task<string> ExecuteAsync(
        NativeToolCall call,
        IReadOnlyList<ChatContextRoot> contextRoots,
        CancellationToken ct = default,
        AgentCommandSandboxMode commandSandbox = AgentCommandSandboxMode.Legacy)
    {
        if (contextRoots.Count == 0)
            return "Tool error: a user-provided file or folder path is required before using filesystem tools.";

        JsonObject input;
        try { input = JsonNode.Parse(call.Arguments)?.AsObject() ?? new JsonObject(); }
        catch { return $"Tool error: invalid arguments for {call.Name}."; }

        var rootId = input["contextRootID"]?.GetValue<string>();
        var root = contextRoots.FirstOrDefault(item => string.Equals(item.Id, rootId, StringComparison.Ordinal));
        if (root is null)
            return "Tool error: choose a valid contextRootID from the user's known context roots.";

        if (root.Kind == ChatContextRootKind.File
            && call.Name is not ("read_file" or "write_file"))
            return $"Tool error: {call.Name} requires a directory context root.";

        if (call.Name == "run_command"
            && !IsChatCommandScoped(input["command"]?.GetValue<string>()))
            return "Tool error: this command may leave the selected context root. Use a relative command without cd, absolute paths, or parent traversal.";

        var rootPath = Path.GetFullPath(root.Path);
        var requested = input["path"]?.GetValue<string>();
        if (root.Kind == ChatContextRootKind.File)
        {
            var requestedFull = string.IsNullOrWhiteSpace(requested)
                ? rootPath
                : Path.GetFullPath(Path.IsPathRooted(requested)
                    ? requested
                    : Path.Combine(Path.GetDirectoryName(rootPath)!, requested));
            if (!SamePath(requestedFull, rootPath))
                return $"Tool error: path is outside the selected context root: {requested}.";
            input["path"] = Path.GetFileName(rootPath);
            rootPath = Path.GetDirectoryName(rootPath)!;
        }
        else if (!string.IsNullOrWhiteSpace(requested))
        {
            var requestedFull = Path.GetFullPath(Path.IsPathRooted(requested)
                ? requested
                : Path.Combine(rootPath, requested));
            if (!IsContained(requestedFull, rootPath))
                return $"Tool error: path is outside the selected context root: {requested}.";
        }

        var rewritten = new NativeToolCall(call.Id, call.Name, input.ToJsonString());
        return await ExecuteAsync(rewritten, rootPath, ct, commandSandbox);
    }

    public static Task<string> ExecuteCommandStreamingAsync(
        string? command,
        string workspace,
        Action<string>? onOutput = null,
        CancellationToken ct = default,
        AgentCommandSandboxMode commandSandbox = AgentCommandSandboxMode.Legacy) =>
        RunCommandAsync(command, workspace, ct, onOutput, commandSandbox);

    private static string ListFiles(string? path, string workspace)
    {
        var directory = Resolve(path, workspace);
        if (!Directory.Exists(directory)) return $"Not a directory: {path}";
        var names = Directory.EnumerateFileSystemEntries(directory)
            .Where(item => !Path.GetFileName(item).Equals(".mem", StringComparison.Ordinal) && !Path.GetFileName(item).StartsWith(".", StringComparison.Ordinal))
            .OrderBy(item => Path.GetFileName(item), StringComparer.OrdinalIgnoreCase)
            .Take(200)
            .Select(item => Directory.Exists(item) ? Path.GetFileName(item) + Path.DirectorySeparatorChar : Path.GetFileName(item));
        var result = string.Join('\n', names);
        return result.Length == 0 ? "Directory is empty." : result;
    }

    private const int ReadMaxBytes = 60_000;

    /// Reads whole lines, never a partial one, and stops at <see cref="ReadMaxBytes"/>.
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
        var end = limit is { } take ? Math.Min(lines.Length, start + Math.Max(0, take) - 1) : lines.Length;

        var emitted = new List<string>();
        var size = 0;
        var line = start;
        while (line <= end)
        {
            var candidate = lines[line - 1];
            var cost = Encoding.UTF8.GetByteCount(candidate) + 1;
            if (size + cost > ReadMaxBytes && emitted.Count > 0) break;
            emitted.Add(candidate);
            size += cost;
            line++;
        }
        var body = string.Join('\n', emitted);
        // Only a complete read authorizes a later full rewrite of the file.
        if (start == 1 && line > lines.Length) ReadLedger.Record(file, bytes);
        else ReadLedger.Forget(file);
        return line > end ? body : body + $"\n\n[truncated] Continue with offset: {line}";
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

    private const int GrepMaxMatches = 200;
    private const int GrepMaxFiles = 5_000;
    private const int GrepMaxLineCharacters = 240;

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
        var pending = new Stack<string>();
        pending.Push(root);
        while (pending.Count > 0 && !truncated)
        {
            IEnumerable<string> entries;
            try { entries = Directory.EnumerateFileSystemEntries(pending.Pop()); } catch { continue; }
            foreach (var entry in entries)
            {
                if (IsSymlink(entry)) continue;
                if (Directory.Exists(entry))
                {
                    var name = Path.GetFileName(entry);
                    if (!IgnoredScanDirectories.Contains(name)) pending.Push(entry);
                    continue;
                }
                if (!File.Exists(entry)) continue;
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
        AgentCommandSandboxMode commandSandbox = AgentCommandSandboxMode.Legacy)
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
        if (commandSandbox == AgentCommandSandboxMode.StrictNoDesktop)
        {
            if (!AgentCommandSandbox.TryConfigure(info, workspace, out var error))
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
        timeout.CancelAfter(TimeSpan.FromSeconds(45));
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
            return "Command timed out after 45 seconds.";
        }
        catch
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
            try { await Task.WhenAll(output, errors); } catch { }
            throw;
        }
        var text = (stdout.ToString() + stderr.ToString()).Trim();
        if (text.Length > 100_000) text = text[..100_000] + "\n[truncated]";
        return string.IsNullOrEmpty(text) ? $"Command exited with status {process.ExitCode}." : text + (process.ExitCode == 0 ? "" : $"\nCommand exited with status {process.ExitCode}.");
    }

    private static async Task ReadLinesAsync(StreamReader reader, StringBuilder target, Action<string>? onOutput, CancellationToken ct)
    {
        while (await reader.ReadLineAsync(ct) is { } line)
        {
            lock (target) target.AppendLine(line);
            onOutput?.Invoke(line);
        }
    }

    private static string Resolve(string? path, string workspace)
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
                if (link is not null) result = link.FullName;
            }
            catch
            {
                // Unreadable component: keep the syntactic path and let the prefix check decide.
            }
        }
        return result;
    }

    private static bool IsSymlink(string path)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            return attributes.HasFlag(FileAttributes.ReparsePoint)
                || (File.Exists(path) ? new FileInfo(path).LinkTarget is not null : new DirectoryInfo(path).LinkTarget is not null);
        }
        catch { return true; }
    }

    private static JsonNode Schema(params (string Name, string Description, bool Required)[] fields)
    {
        var properties = new JsonObject();
        var required = new JsonArray();
        foreach (var field in fields)
        {
            var type = field.Name is "offset" or "limit" ? "integer" : "string";
            properties[field.Name] = new JsonObject { ["type"] = type, ["description"] = field.Description };
            if (field.Required) required.Add(field.Name);
        }
        var schema = new JsonObject { ["type"] = "object", ["properties"] = properties };
        if (required.Count > 0) schema["required"] = required;
        return schema;
    }

    private static NativeToolDefinition AddContextRootId(NativeToolDefinition definition)
    {
        var parameters = definition.Parameters.DeepClone() as JsonObject ?? new JsonObject { ["type"] = "object" };
        var properties = parameters["properties"] as JsonObject ?? new JsonObject();
        properties["contextRootID"] = new JsonObject
        {
            ["type"] = "string",
            ["description"] = "Required id of the file or folder root explicitly supplied by the user.",
        };
        parameters["properties"] = properties;
        var required = parameters["required"] as JsonArray ?? new JsonArray();
        if (!required.Any(item => string.Equals(item?.GetValue<string>(), "contextRootID", StringComparison.Ordinal)))
            required.Add("contextRootID");
        parameters["required"] = required;
        return new NativeToolDefinition(
            definition.Name,
            definition.Description + " In Chat, always include contextRootID.",
            parameters);
    }

    private static bool SamePath(string left, string right) =>
        string.Equals(
            Path.GetFullPath(left).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
            Path.GetFullPath(right).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static bool IsContained(string path, string root)
    {
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var normalizedRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var normalizedPath = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        return normalizedPath.Equals(normalizedRoot, comparison)
            || normalizedPath.StartsWith(normalizedRoot + Path.DirectorySeparatorChar, comparison)
            || normalizedPath.StartsWith(normalizedRoot + Path.AltDirectorySeparatorChar, comparison);
    }

    private static bool IsChatCommandScoped(string? command)
    {
        if (string.IsNullOrWhiteSpace(command) || command.Contains('\0')) return false;
        if (command.Contains("..", StringComparison.Ordinal)) return false;
        if (System.Text.RegularExpressions.Regex.IsMatch(
                command,
                @"(?i)(^|[\s;&|()])(?:cd|pushd|popd|set-location|set-locationpath)(?:[\s;&|()]|$)"))
            return false;
        // Commands such as /bin/sh -c 'cat /etc/passwd', C:\... and UNC paths
        // can escape the selected root even when the process starts inside it.
        return !System.Text.RegularExpressions.Regex.IsMatch(
            command,
            @"(?:^|[\s'""=])(?:/|[A-Za-z]:[\\/]|\\\\|~(?:[\\/]|$))");
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
    private static readonly Queue<string> Order = new();

    public static void Record(string file, byte[] content)
    {
        var hash = Hash(content);
        lock (Gate)
        {
            if (!Hashes.ContainsKey(file)) Order.Enqueue(file);
            Hashes[file] = hash;
            while (Order.Count > Capacity) Hashes.Remove(Order.Dequeue());
        }
    }

    public static void Forget(string file)
    {
        lock (Gate) Hashes.Remove(file);
    }

    public static ReadState StateOf(string file, byte[] content)
    {
        string? known;
        lock (Gate) Hashes.TryGetValue(file, out known);
        if (known is null) return ReadState.Unread;
        return known == Hash(content) ? ReadState.Fresh : ReadState.Stale;
    }

    /// Test seam: a fresh ledger per test keeps the shared one out of it.
    public static void Reset()
    {
        lock (Gate)
        {
            Hashes.Clear();
            Order.Clear();
        }
    }

    private static string Hash(byte[] content) =>
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(content));
}
