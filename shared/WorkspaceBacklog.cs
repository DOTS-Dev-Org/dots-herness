// Copyright (c) 2026 DOTS
// Unfinished work carried across runs. A reply that leaves something open ends
// with a `BACKLOG: <what is left>` line; that turn is written to
// .mem/tasks/<runId>.md with status "unfinished" and injected into the next
// prompt so the model resumes it and asks the user whether to continue.
// `BACKLOG-DONE: <run id>` closes the note again.
//
// Mirrors macos/DotsHarness/Sources/DotsHarnessCore/WorkspaceMemory.swift.

namespace DotsHarnessCore;

public static class WorkspaceBacklog
{
    public const string Marker = "BACKLOG:";
    public const string DoneMarker = "BACKLOG-DONE:";

    /// <summary>How many open notes reach the prompt. Older ones stay on disk.</summary>
    public const int MaxPromptEntries = 5;

    public static IReadOnlyList<string> OpenItems(string? finalText) =>
        (finalText ?? "")
            .Split('\n')
            .Select(line => line.Trim())
            .Where(line => line.StartsWith(Marker, StringComparison.OrdinalIgnoreCase))
            .Select(line => Sanitize(line[Marker.Length..], 200))
            .Where(item => item.Length > 0)
            .ToList();

    /// <summary>
    /// Records one finished run. Only runs that left work open - or failed -
    /// produce a note; a clean run has nothing to carry forward.
    /// </summary>
    public static void Record(string? workspace, string runId, string prompt, string? finalText, string outcome)
    {
        var directory = TasksDirectory(workspace);
        if (directory is null || string.IsNullOrWhiteSpace(runId)) return;
        Close(workspace, finalText);
        var items = OpenItems(finalText);
        var status = outcome == "completed" ? (items.Count == 0 ? "completed" : "unfinished") : "failed";
        if (status == "completed") return;

        var body = items.Count == 0
            ? "- [ ] Run ended as " + status + "; work was not confirmed finished."
            : string.Join("\n", items.Select(item => $"- [ ] {item}"));
        var note = $"""
            ---
            id: task-{runId}
            type: task
            title: "{Sanitize(prompt, 120).Replace("\"", "'")}"
            recorded: {DateTime.UtcNow:yyyy-MM-ddTHH:mm:ssZ}
            status: {status}
            tags: [task, {status}]
            ---
            # Task: {runId}

            ## Request summary

            {Sanitize(prompt, 240)}

            ## Open items

            {body}

            ## Result

            {Sanitize(finalText ?? "", 600)}
            """;
        try
        {
            Directory.CreateDirectory(directory);
            File.WriteAllText(Path.Combine(directory, runId + ".md"), note);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    /// <summary>The prompt section: open notes plus how to keep them current.</summary>
    public static string Text(string? workspace)
    {
        var entries = new List<string>();
        foreach (var (path, note) in Notes(workspace).OrderByDescending(item => item.Path, StringComparer.Ordinal))
        {
            if (!note.Contains("status: unfinished") && !note.Contains("status: failed")) continue;
            var lines = note.Split('\n').Select(line => line.TrimEnd('\r'));
            var title = lines.FirstOrDefault(line => line.StartsWith("title:", StringComparison.Ordinal))
                ?.Substring("title:".Length).Trim().Trim('"') ?? "untitled";
            var items = string.Join("\n", note.Split('\n')
                .Where(line => line.TrimStart().StartsWith("- [ ] ", StringComparison.Ordinal))
                .Select(line => "  " + line.Trim()));
            entries.Add($"- `{Path.GetFileNameWithoutExtension(path)}` — {title}"
                + (items.Length == 0 ? "" : "\n" + items));
            if (entries.Count == MaxPromptEntries) break;
        }
        if (entries.Count == 0) return "";
        return $"""
            Unfinished work (backlog)
            {string.Join("\n", entries)}

            If this request continues one of these, resume it. When your reply leaves work open, end it with a line `{Marker} <what is left>` and ask the user whether to continue. When one of the items above is done, write `{DoneMarker} <task id>`.
            """;
    }

    /// <summary>`BACKLOG-DONE: <run id>` flips that note out of the backlog.</summary>
    public static void Close(string? workspace, string? finalText)
    {
        var text = (finalText ?? "").ToLowerInvariant();
        if (!text.Contains(DoneMarker.ToLowerInvariant())) return;
        foreach (var (path, note) in Notes(workspace))
        {
            if (!text.Contains(Path.GetFileNameWithoutExtension(path).ToLowerInvariant())) continue;
            var closed = note
                .Replace("status: unfinished", "status: completed")
                .Replace("status: failed", "status: completed")
                .Replace("- [ ] ", "- [x] ");
            try { File.WriteAllText(path, closed); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static IEnumerable<(string Path, string Note)> Notes(string? workspace)
    {
        var directory = TasksDirectory(workspace);
        if (directory is null || !Directory.Exists(directory)) yield break;
        string[] files;
        try { files = Directory.GetFiles(directory, "*.md"); }
        catch (IOException) { yield break; }
        catch (UnauthorizedAccessException) { yield break; }
        foreach (var path in files)
        {
            string note;
            try { note = File.ReadAllText(path); }
            catch (IOException) { continue; }
            catch (UnauthorizedAccessException) { continue; }
            yield return (path, note);
        }
    }

    private static string? TasksDirectory(string? workspace) =>
        string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)
            ? null
            : Path.Combine(workspace, ".mem", "tasks");

    private static string Sanitize(string text, int limit)
    {
        var value = string.Join(" ", text.Split('\n', '\r')).Trim();
        return value.Length <= limit ? value : value[..limit] + "…";
    }
}
