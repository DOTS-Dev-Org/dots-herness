// Copyright (c) 2026 DOTS
// Scheduler: ticks once a minute and runs due tasks via an injected runner.
// Used by the in-app manager and the background daemon. Mirrors TaskScheduler.swift.

using PluginRuntime;

namespace DotsHarnessCore;

public sealed record TaskRunResult(bool Ok, string Message = "", string? ConversationId = null);

// Named HarnessScheduler (not TaskScheduler) to avoid colliding with
// System.Threading.Tasks.TaskScheduler, which ImplicitUsings pulls in.
public sealed class HarnessScheduler : ObservableObject, IDisposable
{
    private readonly TaskStore _store;
    private readonly Func<ScheduledTask, Task<TaskRunResult>> _runner;
    private readonly object _gate = new();
    private readonly HashSet<string> _inFlight = new();
    private Timer? _timer;
    private List<ScheduledTask> _tasks;

    /// <summary>
    /// When false the engine still reloads/persists task definitions and honours
    /// <see cref="RunNow"/>, but does not fire due tasks on tick. The in-app
    /// scheduler sets this false while the background daemon owns execution.
    /// </summary>
    public bool RunsDueTasks { get; set; } = true;

    public IReadOnlyList<ScheduledTask> Tasks => _tasks;

    public HarnessScheduler(TaskStore store, Func<ScheduledTask, Task<TaskRunResult>> runner, bool runsDueTasks = true)
    {
        _store = store;
        _runner = runner;
        RunsDueTasks = runsDueTasks;
        _tasks = store.Load();
    }

    public void Start()
    {
        if (_timer is not null) return;
        _timer = new Timer(_ => Tick(DateTimeOffset.Now), null, TimeSpan.Zero, TimeSpan.FromSeconds(60));
    }

    public void Stop()
    {
        _timer?.Dispose();
        _timer = null;
    }

    public void Dispose() => Stop();

    // MARK: CRUD

    public void Upsert(ScheduledTask task)
    {
        lock (_gate)
        {
            ReloadFromDisk_NoLock();
            var index = _tasks.FindIndex(t => t.Id == task.Id);
            if (index >= 0) _tasks[index] = task;
            else _tasks.Add(task);
            Persist_NoLock();
        }
        OnPropertyChanged(nameof(Tasks));
    }

    public void Delete(string id)
    {
        lock (_gate)
        {
            ReloadFromDisk_NoLock();
            _tasks.RemoveAll(t => t.Id == id);
            Persist_NoLock();
        }
        OnPropertyChanged(nameof(Tasks));
    }

    public void SetEnabled(string id, bool enabled)
    {
        lock (_gate)
        {
            ReloadFromDisk_NoLock();
            var task = _tasks.FirstOrDefault(t => t.Id == id);
            if (task is null) return;
            task.Enabled = enabled;
            Persist_NoLock();
        }
        OnPropertyChanged(nameof(Tasks));
    }

    /// <summary>Run a task immediately, ignoring its schedule and <see cref="RunsDueTasks"/>.</summary>
    public void RunNow(string id)
    {
        ScheduledTask? task;
        lock (_gate) task = _tasks.FirstOrDefault(t => t.Id == id);
        if (task is not null) Execute(task);
    }

    // MARK: Engine

    private void Tick(DateTimeOffset now)
    {
        List<ScheduledTask> due;
        lock (_gate)
        {
            ReloadFromDisk_NoLock();
            if (!RunsDueTasks) { OnPropertyChanged(nameof(Tasks)); return; }
            due = _tasks.Where(t => t.IsDue(now)).ToList();
        }
        foreach (var task in due) Execute(task);
        OnPropertyChanged(nameof(Tasks));
    }

    private void ReloadFromDisk_NoLock()
    {
        var disk = _store.Load();
        if (disk.Count == 0 && _tasks.Count == 0) return;
        for (var i = 0; i < disk.Count; i++)
        {
            if (!_inFlight.Contains(disk[i].Id)) continue;
            var live = _tasks.FirstOrDefault(t => t.Id == disk[i].Id);
            if (live is not null) disk[i] = live;
        }
        _tasks = disk;
    }

    private void Persist_NoLock() => _store.Save(_tasks);

    private void Execute(ScheduledTask task)
    {
        lock (_gate)
        {
            if (!_inFlight.Add(task.Id)) return;
            Mutate_NoLock(task.Id, t =>
            {
                t.LastState = TaskRunKind.Running;
                t.LastRunAt = DateTimeOffset.Now;
            });
        }
        OnPropertyChanged(nameof(Tasks));

        _ = Task.Run(async () =>
        {
            TaskRunResult result;
            try
            {
                result = await _runner(task).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                result = new TaskRunResult(false, ex.Message);
            }

            lock (_gate)
            {
                _inFlight.Remove(task.Id);
                Mutate_NoLock(task.Id, t =>
                {
                    t.LastState = result.Ok ? TaskRunKind.Ok : TaskRunKind.Failed;
                    t.LastMessage = result.Message;
                    if (result.ConversationId is not null) t.LastConversationId = result.ConversationId;
                });
            }
            OnPropertyChanged(nameof(Tasks));
        });
    }

    private void Mutate_NoLock(string id, Action<ScheduledTask> change)
    {
        ReloadFromDisk_NoLock();
        var task = _tasks.FirstOrDefault(t => t.Id == id);
        if (task is null) return;
        change(task);
        Persist_NoLock();
    }
}
