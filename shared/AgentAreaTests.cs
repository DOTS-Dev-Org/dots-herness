// Copyright (c) 2026 DOTS
// Cross-platform tests for Chat/Coding persistence and Chat context boundaries.

using System.Text.Json;
using DotsHarnessCore;
using PluginRuntime;
using Xunit;

namespace DotsHarness.Tests;

public sealed class AgentAreaTests : IDisposable
{
    private readonly string _root = Path.Combine(
        Path.GetTempPath(),
        "DotsHarnessAreaTests-" + Guid.NewGuid().ToString("N"));
    private readonly SupportPaths _paths;

    public AgentAreaTests()
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
    public void LegacySessionsSplitByWorkspaceAndKeepTheLegacyFile()
    {
        var workspace = Path.Combine(_root, "coding-project");
        Directory.CreateDirectory(workspace);
        var legacyPath = Path.Combine(_paths.Root, "sessions.json");
        var legacy = new[]
        {
            new Conversation { Id = "coding", Cwd = workspace },
            new Conversation { Id = "chat", Cwd = "", Area = AgentArea.Coding },
        };
        File.WriteAllText(legacyPath, JsonSerializer.Serialize(legacy));

        SessionAreaMigration.Run(_paths);

        var coding = Read(Path.Combine(_paths.Root, AgentArea.Coding.SessionFileName()));
        var chat = Read(Path.Combine(_paths.Root, AgentArea.Chat.SessionFileName()));
        Assert.Equal("coding", Assert.Single(coding).Id);
        Assert.Equal(AgentArea.Coding, coding[0].Area);
        Assert.Equal("chat", Assert.Single(chat).Id);
        Assert.Equal(AgentArea.Chat, chat[0].Area);
        Assert.Null(chat[0].Cwd);
        Assert.True(File.Exists(legacyPath));
        Assert.True(File.Exists(Path.Combine(_paths.Root, "area-session-migration-v1.json")));
    }

    [Fact]
    public void PathParserRecognizesPosixWindowsDriveAndUncCandidates()
    {
        var extracted = ChatPathParser.ExtractPaths(
            "POSIX /tmp/project/main.cs, drive C:\\repo\\main.cs and UNC \\\\server\\share\\main.cs.");

        Assert.Contains("/tmp/project/main.cs", extracted);
        Assert.Contains("C:\\repo\\main.cs", extracted);
        Assert.Contains(@"\\server\share\main.cs", extracted);
    }

    [Fact]
    public void LedgerKeepsMultipleRootsAndCacheNamespacesDoNotContainRawPaths()
    {
        var first = Path.Combine(_root, "project-a");
        var second = Path.Combine(_root, "project-b");
        Directory.CreateDirectory(first);
        Directory.CreateDirectory(second);
        var ledger = new ChatContextLedger();
        var attached = ledger.Attach(
            [
                ChatContextRoot.Create(first, ChatContextRootKind.Directory, "message-a"),
                ChatContextRoot.Create(second, ChatContextRootKind.Directory, "message-b"),
            ],
            "message-a");

        Assert.Equal(2, attached.Count);
        Assert.Equal(2, ledger.Roots.Count);
        Assert.Contains("message-a", ledger.Roots[0].SourceMessageIds);
        Assert.Contains("message-b", ledger.Roots[1].SourceMessageIds);

        var chatKey = AgentCacheNamespace.Create(
            AgentArea.Chat, "conversation", "chat-project", null, "model", false, ledger.Revision,
            ledger.Roots.Select(root => root.Id));
        var codingKey = AgentCacheNamespace.Create(
            AgentArea.Coding, "conversation", null, "coding-project", "model", false, ledger.Revision);

        Assert.NotEqual(chatKey, codingKey);
        Assert.DoesNotContain(first, chatKey, StringComparison.Ordinal);
        Assert.DoesNotContain(second, chatKey, StringComparison.Ordinal);
    }

    [Fact]
    public void ProviderAccountsUseOneSharedStoreAcrossAreas()
    {
        var model = new AppModel(_paths);

        Assert.Same(model.ChatRouter.Store, model.CodingRouter.Store);
        Assert.NotSame(model.ChatBridge.Skills, model.CodingBridge.Skills);
        Assert.Same(model.ActiveSkills, model.ChatBridge.Skills);
        model.SetActiveArea(AgentArea.Coding);
        Assert.Same(model.ActiveSkills, model.CodingBridge.Skills);
    }

    [Fact]
    public void LastActiveAreaSurvivesAppModelRecreation()
    {
        var firstLaunch = new AppModel(_paths);
        firstLaunch.SetActiveArea(AgentArea.Coding);
        Assert.Equal(AgentArea.Coding, firstLaunch.ActiveArea);

        var codingLaunch = new AppModel(_paths);
        Assert.Equal(AgentArea.Coding, codingLaunch.ActiveArea);

        codingLaunch.SetActiveArea(AgentArea.Chat);
        Assert.Equal(AgentArea.Chat, codingLaunch.ActiveArea);

        var chatLaunch = new AppModel(_paths);
        Assert.Equal(AgentArea.Chat, chatLaunch.ActiveArea);
    }

    [Fact]
    public async Task ChatToolsRequireAValidRootAndStayInsideIt()
    {
        var workspace = Path.Combine(_root, "chat-root");
        Directory.CreateDirectory(workspace);
        var inside = Path.Combine(workspace, "inside.txt");
        var outside = Path.Combine(_root, "outside.txt");
        File.WriteAllText(inside, "inside");
        File.WriteAllText(outside, "outside");
        var root = ChatContextRoot.Create(workspace, ChatContextRootKind.Directory, "message");

        var outsideCall = new NativeToolCall(
            "read-outside",
            "read_file",
            JsonSerializer.Serialize(new { contextRootID = root.Id, path = outside }));
        var outsideResult = await NativeWorkspaceTools.ExecuteAsync(outsideCall, [root]);
        Assert.Contains("outside the selected context root", outsideResult, StringComparison.OrdinalIgnoreCase);

        var invalidRootCall = new NativeToolCall(
            "read-invalid",
            "read_file",
            JsonSerializer.Serialize(new { contextRootID = "unknown", path = "inside.txt" }));
        var invalidRootResult = await NativeWorkspaceTools.ExecuteAsync(invalidRootCall, [root]);
        Assert.Contains("valid contextRootID", invalidRootResult, StringComparison.OrdinalIgnoreCase);

        var escapingCommand = new NativeToolCall(
            "command-escape",
            "run_command",
            JsonSerializer.Serialize(new { contextRootID = root.Id, command = "cd .. && pwd" }));
        var commandResult = await NativeWorkspaceTools.ExecuteAsync(escapingCommand, [root]);
        Assert.Contains("leave the selected context root", commandResult, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task FileContextRootCanOnlyAddressThatFile()
    {
        var workspace = Path.Combine(_root, "file-root");
        Directory.CreateDirectory(workspace);
        var file = Path.Combine(workspace, "answer.txt");
        var other = Path.Combine(workspace, "other.txt");
        File.WriteAllText(file, "answer");
        File.WriteAllText(other, "other");
        var root = ChatContextRoot.Create(file, ChatContextRootKind.File, "message");

        var read = new NativeToolCall(
            "read-file",
            "read_file",
            JsonSerializer.Serialize(new { contextRootID = root.Id }));
        Assert.Equal("answer", await NativeWorkspaceTools.ExecuteAsync(read, [root]));

        var list = new NativeToolCall(
            "list-file",
            "list_files",
            JsonSerializer.Serialize(new { contextRootID = root.Id, path = "answer.txt" }));
        var listResult = await NativeWorkspaceTools.ExecuteAsync(list, [root]);
        Assert.Contains("requires a directory context root", listResult, StringComparison.OrdinalIgnoreCase);

        var otherRead = new NativeToolCall(
            "read-other",
            "read_file",
            JsonSerializer.Serialize(new { contextRootID = root.Id, path = "other.txt" }));
        var otherResult = await NativeWorkspaceTools.ExecuteAsync(otherRead, [root]);
        Assert.Contains("outside the selected context root", otherResult, StringComparison.OrdinalIgnoreCase);
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
