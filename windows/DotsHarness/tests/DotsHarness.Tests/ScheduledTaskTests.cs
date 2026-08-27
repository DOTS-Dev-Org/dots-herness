// Copyright (c) 2026 DOTS
// Cron parsing, due-detection, store round-trip, and scheduler gating tests.
// Shared by the Windows and Linux test projects.

using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using DotsHarnessCore;
using PluginRuntime;
using Xunit;

namespace DotsHarness.Tests;

public sealed class ScheduledTaskTests
{
    private static DateTimeOffset Utc(string iso) => DateTimeOffset.Parse(iso).ToUniversalTime();

    [Theory]
    [InlineData("")]
    [InlineData("* * * *")]
    [InlineData("60 * * * *")]
    [InlineData("* 24 * * *")]
    [InlineData("*/0 * * * *")]
    [InlineData("5-1 * * * *")]
    [InlineData("abc * * * *")]
    public void RejectsMalformedExpressions(string expression)
    {
        Assert.Null(CronExpression.TryParse(expression));
    }

    [Fact]
    public void EveryFiveHoursFromMidnight()
    {
        var cron = CronExpression.TryParse("0 */5 * * *")!;
        Assert.Equal(Utc("2026-08-27T05:00:00Z"), cron.NextDate(Utc("2026-08-27T01:30:00Z")));
    }

    [Fact]
    public void DailyAtFixedTime()
    {
        var cron = CronExpression.TryParse("30 9 * * *")!;
        Assert.Equal(Utc("2026-08-28T09:30:00Z"), cron.NextDate(Utc("2026-08-27T09:30:00Z")));
    }

    [Fact]
    public void DayOfWeekMondayNineAm()
    {
        var cron = CronExpression.TryParse("0 9 * * 1")!;
        // 2026-08-27 is a Thursday; next Monday is 2026-08-31.
        Assert.Equal(Utc("2026-08-31T09:00:00Z"), cron.NextDate(Utc("2026-08-27T12:00:00Z")));
    }

    [Fact]
    public void SundayAcceptsZeroAndSeven()
    {
        var a = CronExpression.TryParse("0 0 * * 0")!.NextDate(Utc("2026-08-27T00:00:00Z"));
        var b = CronExpression.TryParse("0 0 * * 7")!.NextDate(Utc("2026-08-27T00:00:00Z"));
        Assert.Equal(Utc("2026-08-30T00:00:00Z"), a);
        Assert.Equal(a, b);
    }

    [Fact]
    public void ListAndRange()
    {
        var cron = CronExpression.TryParse("0,30 8-10 * * *")!;
        Assert.Equal(Utc("2026-08-27T08:30:00Z"), cron.NextDate(Utc("2026-08-27T08:15:00Z")));
        Assert.Equal(Utc("2026-08-28T08:00:00Z"), cron.NextDate(Utc("2026-08-27T10:30:00Z")));
    }

    [Fact]
    public void RestrictedDomAndDowUseOrSemantics()
    {
        // 1st of the month OR any Friday.
        var cron = CronExpression.TryParse("0 0 1 * 5")!;
        Assert.Equal(Utc("2026-08-28T00:00:00Z"), cron.NextDate(Utc("2026-08-27T00:00:00Z")));
    }

    [Fact]
    public void IsDueFiresForMissedSlotThenClears()
    {
        var task = new ScheduledTask
        {
            Name = "backup",
            Cron = "0 */5 * * *",
            Prompt = "run backup",
            WorkspacePath = "/tmp/ws",
            CreatedAt = Utc("2026-08-27T02:00:00Z"),
        };
        Assert.True(task.IsDue(Utc("2026-08-27T06:01:00Z")));

        task.LastRunAt = Utc("2026-08-27T06:01:00Z");
        Assert.False(task.IsDue(Utc("2026-08-27T06:30:00Z")));
        Assert.True(task.IsDue(Utc("2026-08-27T10:02:00Z")));
    }

    [Fact]
    public void DisabledOrInvalidNeverDue()
    {
        var task = new ScheduledTask
        {
            Name = "x", Cron = "0 * * * *", Prompt = "p", WorkspacePath = "/tmp",
            Enabled = false, CreatedAt = Utc("2026-08-27T00:00:00Z"),
        };
        Assert.False(task.IsDue(Utc("2026-08-27T05:00:00Z")));
        task.Enabled = true;
        task.Cron = "nonsense";
        Assert.False(task.IsDue(Utc("2026-08-27T05:00:00Z")));
    }

    [Fact]
    public void StoreRoundTrip()
    {
        var root = Path.Combine(Path.GetTempPath(), "DotsHarnessTasks-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var paths = TempPaths(root);
            var store = new TaskStore(paths);
            Assert.Empty(store.Load());

            store.Save(new[]
            {
                new ScheduledTask
                {
                    Name = "mail", Cron = "*/15 * * * *", Prompt = "check mail",
                    WorkspacePath = "/tmp/ws", LastState = TaskRunKind.Failed, LastMessage = "boom",
                },
            });

            var loaded = store.Load();
            Assert.Single(loaded);
            Assert.Equal("mail", loaded[0].Name);
            Assert.Equal(TaskRunKind.Failed, loaded[0].LastState);
            Assert.Equal("boom", loaded[0].LastMessage);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void LinuxUnitContentIsAValidServiceFile()
    {
        var unit = SchedulerService.LinuxUnitContent("/opt/dots/DotsHarnessScheduler");
        Assert.Contains("[Service]", unit);
        Assert.Contains("ExecStart=/opt/dots/DotsHarnessScheduler", unit);
        Assert.Contains("WantedBy=default.target", unit);
    }

    [Fact]
    public async Task SchedulerDoesNotFireWhenExecutionGated()
    {
        var root = Path.Combine(Path.GetTempPath(), "DotsHarnessSched-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var store = new TaskStore(TempPaths(root));
            store.Save(new[]
            {
                new ScheduledTask
                {
                    Name = "t", Cron = "* * * * *", Prompt = "p", WorkspacePath = "/tmp",
                    CreatedAt = DateTimeOffset.Now.AddMinutes(-2),
                },
            });

            var runs = 0;
            using var scheduler = new HarnessScheduler(store, _ => { Interlocked.Increment(ref runs); return Task.FromResult(new TaskRunResult(true)); }, runsDueTasks: false);
            scheduler.Start();
            await Task.Delay(100);
            Assert.Equal(0, runs);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task SchedulerFiresDueTaskWhenEnabled()
    {
        var root = Path.Combine(Path.GetTempPath(), "DotsHarnessSched-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var store = new TaskStore(TempPaths(root));
            store.Save(new[]
            {
                new ScheduledTask
                {
                    Name = "t", Cron = "* * * * *", Prompt = "p", WorkspacePath = "/tmp",
                    CreatedAt = DateTimeOffset.Now.AddMinutes(-2),
                },
            });

            var runs = 0;
            using var scheduler = new HarnessScheduler(store, _ => { Interlocked.Increment(ref runs); return Task.FromResult(new TaskRunResult(true)); }, runsDueTasks: true);
            scheduler.Start();
            await Task.Delay(200);
            Assert.Equal(1, runs);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void CrudReloadsExternalEdits()
    {
        var root = Path.Combine(Path.GetTempPath(), "DotsHarnessSched-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var store = new TaskStore(TempPaths(root));
            var a = new ScheduledTask { Name = "a", Cron = "0 0 * * *", Prompt = "p", WorkspacePath = "/tmp" };
            store.Save(new[] { a });

            using var scheduler = new HarnessScheduler(store, _ => Task.FromResult(new TaskRunResult(true)), runsDueTasks: false);
            Assert.Equal(new[] { "a" }, scheduler.Tasks.Select(t => t.Name));

            var b = new ScheduledTask { Name = "b", Cron = "0 0 * * *", Prompt = "p", WorkspacePath = "/tmp" };
            store.Save(new[] { a, b });

            var c = new ScheduledTask { Name = "c", Cron = "0 0 * * *", Prompt = "p", WorkspacePath = "/tmp" };
            scheduler.Upsert(c);

            Assert.Equal(new[] { "a", "b", "c" }, scheduler.Tasks.Select(t => t.Name).OrderBy(n => n));
            Assert.Equal(new[] { "a", "b", "c" }, store.Load().Select(t => t.Name).OrderBy(n => n));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static SupportPaths TempPaths(string root) => new(
        root,
        Path.Combine(root, "plugins"),
        Path.Combine(root, "presets"),
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "host.patch.yml"),
        Path.Combine(root, "trust.json"),
        Path.Combine(root, "models"),
        Path.Combine(root, "runtime"));
}
