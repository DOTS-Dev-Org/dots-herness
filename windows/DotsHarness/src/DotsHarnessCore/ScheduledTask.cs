// Copyright (c) 2026 DOTS
// Durable scheduled tasks: a cron expression plus a prompt to run in a workspace.
// Mirrors the macOS ScheduledTask.swift.

using System.Text.Json;
using System.Text.Json.Serialization;
using PluginRuntime;

namespace DotsHarnessCore;

public enum TaskRunKind
{
    Never,
    Running,
    Ok,
    Failed,
}

public sealed class ScheduledTask
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";

    /// <summary>Standard 5-field cron expression.</summary>
    public string Cron { get; set; } = "";

    /// <summary>The prompt sent to the agent when the task fires.</summary>
    public string Prompt { get; set; } = "";

    /// <summary>Absolute workspace path the run executes in.</summary>
    public string WorkspacePath { get; set; } = "";

    /// <summary>Optional model id override. Empty means "use the current agent model".</summary>
    public string ModelId { get; set; } = "";

    public bool Enabled { get; set; } = true;

    /// <summary>
    /// Allow the run to execute <c>run_command</c> tool calls without an interactive
    /// approval prompt. ponytail: off by default; a scheduled run cannot answer a
    /// dialog, so leaving this off means command tool calls are rejected.
    /// </summary>
    public bool AutoApproveCommands { get; set; }

    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.Now;
    public DateTimeOffset? LastRunAt { get; set; }
    public TaskRunKind LastState { get; set; } = TaskRunKind.Never;
    public string LastMessage { get; set; } = "";
    public string? LastConversationId { get; set; }

    [JsonIgnore]
    public CronExpression? Expression => CronExpression.TryParse(Cron);

    public DateTimeOffset? NextRun(DateTimeOffset? reference = null)
        => Expression?.NextDate(reference ?? DateTimeOffset.Now);

    /// <summary>
    /// Whether the task is due at <paramref name="now"/>: enabled, valid cron, and a
    /// scheduled firing exists in <c>(anchor, now]</c> where anchor is the last run
    /// (or creation time). A task that missed several firings runs once, not once
    /// per missed slot.
    /// </summary>
    public bool IsDue(DateTimeOffset now)
    {
        if (!Enabled) return false;
        var expression = Expression;
        if (expression is null) return false;
        var anchor = LastRunAt ?? CreatedAt;
        if (anchor >= now) return false;
        var fire = expression.NextDate(anchor);
        return fire is { } f && f <= now;
    }
}

/// <summary>Small, transparent JSON store mirroring the conversation store.</summary>
public sealed class TaskStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    private readonly string _file;

    public TaskStore(SupportPaths paths)
    {
        _file = Path.Combine(paths.Root, "tasks.json");
    }

    public List<ScheduledTask> Load()
    {
        try
        {
            if (!File.Exists(_file)) return new List<ScheduledTask>();
            var tasks = JsonSerializer.Deserialize<List<ScheduledTask>>(File.ReadAllText(_file), Options)
                        ?? new List<ScheduledTask>();
            return tasks.OrderBy(t => t.CreatedAt).ToList();
        }
        catch
        {
            return new List<ScheduledTask>();
        }
    }

    public void Save(IEnumerable<ScheduledTask> tasks)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
            var tmp = _file + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(tasks.ToList(), Options));
            File.Move(tmp, _file, overwrite: true);
        }
        catch
        {
            // best effort
        }
    }
}
