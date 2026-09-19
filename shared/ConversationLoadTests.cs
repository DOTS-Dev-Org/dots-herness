// Copyright (c) 2026 DOTS

using System.Text.Json;
using DotsHarnessCore;
using PluginRuntime;
using Xunit;

namespace DotsHarness.Tests;

public sealed class ConversationLoadTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "DotsHarnessLoadTests-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    [Fact]
    public async Task StagedLoadHydratesTranscriptsAndSaveKeepsOtherWorkspaces()
    {
        var paths = new SupportPaths(
            _root,
            Path.Combine(_root, "plugins"),
            Path.Combine(_root, "presets"),
            Path.Combine(_root, "settings.json"),
            Path.Combine(_root, "host.patch.yml"),
            Path.Combine(_root, "trust.json"),
            Path.Combine(_root, "models"),
            Path.Combine(_root, "runtime"));
        var mine = Path.Combine(_root, "mine");
        var other = Path.Combine(_root, "other");
        Directory.CreateDirectory(mine);
        Directory.CreateDirectory(other);
        Conversation Chat(string id, string cwd) => new()
        {
            Id = id,
            Title = id,
            Blank = false,
            Cwd = cwd,
            Area = AgentArea.Coding,
            Messages =
            {
                new ChatMessage { Kind = ChatKind.User, Text = id + " question" },
                new ChatMessage { Kind = ChatKind.Assistant, Text = id + " answer" },
            },
        };
        var file = Path.Combine(_root, "conversations.json");
        File.WriteAllText(file, JsonSerializer.Serialize(new[] { Chat("a", mine), Chat("b", other) }));

        using var router = new RouterController(paths);
        var bridge = new AgentBridge(router, paths);
        await bridge.StartAsync(mine);

        var loaded = Assert.Single(bridge.Conversations);
        Assert.Equal("a", loaded.Id);
        Assert.Equal(2, loaded.Messages.Count);
        Assert.NotEmpty(loaded.ModelContext);

        bridge.RenameConversation("a", "renamed");
        var stored = JsonSerializer.Deserialize<List<Conversation>>(File.ReadAllText(file))!;
        Assert.Equal("renamed", stored.Single(c => c.Id == "a").Title);
        Assert.Equal(2, stored.Single(c => c.Id == "a").Messages.Count);
        Assert.Equal(2, stored.Single(c => c.Id == "b").Messages.Count);
    }
}
