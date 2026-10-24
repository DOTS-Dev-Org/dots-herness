// Copyright (c) 2026 DOTS
// Cross-platform tests for the project-centered session migration.

using System.Text.Json;
using DotsHarnessCore;
using PluginRuntime;
using Xunit;

namespace DotsHarness.Tests;

public sealed class ProjectSessionTests : IDisposable
{
    private readonly string _root = Path.Combine(
        Path.GetTempPath(),
        "DotsHarnessProjectSessionTests-" + Guid.NewGuid().ToString("N"));
    private readonly SupportPaths _paths;

    public ProjectSessionTests()
    {
        _paths = new SupportPaths(
            _root,
            Path.Combine(_root, "plugins"),
            Path.Combine(_root, "presets"),
            Path.Combine(_root, "settings.json"),
            Path.Combine(_root, "host.patch.yml"),
            Path.Combine(_root, "trust.json"),
            Path.Combine(_root, "models"),
            Path.Combine(_root, "runtime"));
        _paths.Ensure();
    }

    [Fact]
    public void MigrationKeepsWorkspaceSessionsAndDropsProjectlessChat()
    {
        var workspace = Path.Combine(_root, "project");
        Directory.CreateDirectory(workspace);
        var shortCopy = new Conversation
        {
            Id = "duplicate",
            Cwd = workspace,
            Messages = [new ChatMessage { Kind = ChatKind.User, Text = "first" }],
        };
        var fullCopy = new Conversation
        {
            Id = "duplicate",
            Cwd = workspace,
            Messages =
            [
                new ChatMessage { Kind = ChatKind.User, Text = "first" },
                new ChatMessage { Kind = ChatKind.Assistant, Text = "second" },
            ],
        };
        var project = new Conversation { Id = "project", Cwd = workspace };
        var projectlessChat = new Conversation { Id = "free-chat" };
        var explicitProjectless = new Conversation { Id = "no-project", Projectless = true };

        File.WriteAllText(
            Path.Combine(_paths.Root, "coding-sessions.json"),
            JsonSerializer.Serialize(new[] { shortCopy, project }));
        File.WriteAllText(
            Path.Combine(_paths.Root, "chat-sessions.json"),
            JsonSerializer.Serialize(new[] { fullCopy, projectlessChat, explicitProjectless }));

        SessionAreaMigration.Run(_paths);

        var canonicalPath = Path.Combine(_paths.Root, "sessions.json");
        var migrated = Read(canonicalPath);
        Assert.Equal(new[] { "duplicate", "no-project", "project" }, migrated.Select(item => item.Id));
        Assert.Equal(2, migrated.Single(item => item.Id == "duplicate").Messages.Count);
        Assert.All(migrated, item => Assert.True(!string.IsNullOrWhiteSpace(item.Cwd) || item.Projectless));
        Assert.False(File.Exists(Path.Combine(_paths.Root, "coding-sessions.json")));
        Assert.False(File.Exists(Path.Combine(_paths.Root, "chat-sessions.json")));
        Assert.DoesNotContain(migrated, item => item.Id == "free-chat");
        Assert.True(File.Exists(Path.Combine(_paths.Root, "project-session-migration-v1.json")));

        var before = JsonSerializer.Serialize(migrated);
        SessionAreaMigration.Run(_paths);
        Assert.Equal(before, JsonSerializer.Serialize(Read(canonicalPath)));
    }

    [Fact]
    public void MigrationRemovesContextFilesOnlyAfterCanonicalVerification()
    {
        var workspace = Path.Combine(_root, "project");
        Directory.CreateDirectory(workspace);
        File.WriteAllText(
            Path.Combine(_paths.Root, "coding-sessions.json"),
            JsonSerializer.Serialize(new[] { new Conversation { Id = "project", Cwd = workspace } }));
        var context = Path.Combine(_paths.Root, "chat-context");
        Directory.CreateDirectory(context);
        File.WriteAllText(Path.Combine(context, "state.json"), "legacy");
        File.WriteAllText(Path.Combine(_paths.Root, "chat-projects.json"), "[]");

        SessionAreaMigration.Run(_paths);

        Assert.True(File.Exists(Path.Combine(_paths.Root, "sessions.json")));
        Assert.False(Directory.Exists(context));
        Assert.False(File.Exists(Path.Combine(_paths.Root, "chat-projects.json")));
    }

    private static List<Conversation> Read(string path) =>
        JsonSerializer.Deserialize<List<Conversation>>(File.ReadAllText(path)) ?? [];

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
        }
        catch { }
    }
}
