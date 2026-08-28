// Copyright (c) 2026 DOTS
// Small workspace-scoped tools used by the in-process .NET agent loop.

using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public static class NativeWorkspaceTools
{
    public static IReadOnlyList<NativeToolDefinition> Definitions { get; } =
    [
        new("list_files", "List files and directories inside the current workspace.", Schema(("path", "Relative path. Use . for the workspace root.", false))),
        new("read_file", "Read a UTF-8 text file inside the current workspace.", Schema(("path", "Relative path to the file.", true))),
        new("write_file", "Create or replace a UTF-8 text file inside the current workspace.", Schema(("path", "Relative path to the file.", true), ("content", "Complete file contents.", true))),
        new("run_command", "Run a shell command with the workspace as its current directory.", Schema(("command", "Command to run in the workspace.", true))),
    ];

    public static IReadOnlyList<NativeToolDefinition> ReadOnlyDefinitions { get; } =
        Definitions.Where(tool => tool.Name is "list_files" or "read_file").ToArray();

    public static bool IsReadOnly(string name) => name is "list_files" or "read_file";

    public static async Task<string> ExecuteAsync(NativeToolCall call, string workspace, CancellationToken ct = default)
    {
        try
        {
            var input = JsonNode.Parse(call.Arguments)?.AsObject() ?? new JsonObject();
            return call.Name switch
            {
                "list_files" => ListFiles(input["path"]?.GetValue<string>() ?? ".", workspace),
                "read_file" => ReadFile(input["path"]?.GetValue<string>(), workspace),
                "write_file" => WriteFile(input["path"]?.GetValue<string>(), input["content"]?.GetValue<string>(), workspace),
                "run_command" => await RunCommandAsync(input["command"]?.GetValue<string>(), workspace, ct),
                _ => $"Unknown tool: {call.Name}",
            };
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex) { return $"Tool error: {ex.Message}"; }
    }

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

    private static string ReadFile(string? path, string workspace)
    {
        if (string.IsNullOrWhiteSpace(path)) return "A file path is required.";
        var file = Resolve(path, workspace);
        var bytes = File.ReadAllBytes(file);
        var length = Math.Min(bytes.Length, 200_000);
        try
        {
            var text = new UTF8Encoding(false, true).GetString(bytes, 0, length);
            return bytes.Length > length ? text + "\n\n[truncated]" : text;
        }
        catch (DecoderFallbackException) { return $"File is not UTF-8 text: {path}"; }
    }

    private static string WriteFile(string? path, string? content, string workspace)
    {
        if (string.IsNullOrWhiteSpace(path)) return "A file path is required.";
        if (content is null) return "File content is required.";
        var file = Resolve(path, workspace);
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
        return $"Wrote {Path.GetRelativePath(Path.GetFullPath(workspace), file)} ({Encoding.UTF8.GetByteCount(content)} bytes).";
    }

    private static async Task<string> RunCommandAsync(string? command, string workspace, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(command)) return "A command is required.";
        var info = new ProcessStartInfo
        {
            FileName = OperatingSystem.IsWindows() ? "cmd.exe" : "/bin/sh",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Path.GetFullPath(workspace),
            CreateNoWindow = true,
        };
        info.ArgumentList.Add(OperatingSystem.IsWindows() ? "/c" : "-lc");
        info.ArgumentList.Add(command);
        using var process = Process.Start(info) ?? throw new InvalidOperationException("The command could not start.");
        var output = process.StandardOutput.ReadToEndAsync(ct);
        var errors = process.StandardError.ReadToEndAsync(ct);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(45));
        try
        {
            await process.WaitForExitAsync(timeout.Token);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
            return "Command timed out after 45 seconds.";
        }
        var text = (await output + await errors).Trim();
        if (text.Length > 100_000) text = text[..100_000] + "\n[truncated]";
        return string.IsNullOrEmpty(text) ? $"Command exited with status {process.ExitCode}." : text + (process.ExitCode == 0 ? "" : $"\nCommand exited with status {process.ExitCode}.");
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

    private static JsonNode Schema(params (string Name, string Description, bool Required)[] fields)
    {
        var properties = new JsonObject();
        var required = new JsonArray();
        foreach (var field in fields)
        {
            properties[field.Name] = new JsonObject { ["type"] = "string", ["description"] = field.Description };
            if (field.Required) required.Add(field.Name);
        }
        var schema = new JsonObject { ["type"] = "object", ["properties"] = properties };
        if (required.Count > 0) schema["required"] = required;
        return schema;
    }
}
