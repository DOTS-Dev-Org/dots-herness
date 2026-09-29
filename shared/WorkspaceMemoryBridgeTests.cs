using System.Text;
using System.Text.Json.Nodes;
using DotsHarnessCore;
using PluginRuntime;
using Xunit;

/// <summary>A real bridge run with a fake provider that calls write_file, then answers.</summary>
public sealed class WorkspaceMemoryBridgeTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"MemoryBridgeTests-{Guid.NewGuid():N}");
    private readonly string _workspace;
    private readonly ToolThenAnswerProvider _provider;
    private readonly RouterController _router;
    private readonly AgentBridge _bridge;

    public WorkspaceMemoryBridgeTests()
    {
        _workspace = Path.Combine(_root, "project");
        Directory.CreateDirectory(_workspace);
        var support = Path.Combine(_root, "support");
        var paths = new SupportPaths(support, Path.Combine(support, "plugins"), Path.Combine(support, "presets"),
            Path.Combine(support, "settings.json"), Path.Combine(support, "host.patch.yml"), Path.Combine(support, "trust.json"),
            Path.Combine(support, "models"), Path.Combine(support, "runtime"));
        _provider = new ToolThenAnswerProvider();
        _router = new RouterController(paths);
        var endpoint = _router.Store.AddCustom("Memory test", "memory-test", _provider.Url.ToString().TrimEnd('/'),
            NativeProviderProtocol.OpenAiCompatible, "chat", null);
        _router.Store.AddCustomAccount(endpoint, null);
        _bridge = new AgentBridge(_router, paths);
    }

    public void Dispose()
    {
        _provider.Dispose();
        _router.Dispose();
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    private string Mem(params string[] parts) => Path.Combine(new[] { _workspace, ".mem" }.Concat(parts).ToArray());

    [Fact]
    public async Task ARunThatWritesAFileLeavesSignedEventsATaskNoteAndPromptContext()
    {
        await _router.RefreshAsync();
        await _bridge.StartAsync(_workspace);
        Assert.False(Directory.Exists(Mem())); // opening a workspace creates nothing

        await _bridge.SendAsync("Create the output file").WaitAsync(TimeSpan.FromSeconds(15));

        var transcript = string.Join(" | ", _bridge.Selected!.Messages.Select(m => $"{m.Kind}:{m.Text}")) + " status=" + _bridge.Status;
        Assert.True(File.Exists(Path.Combine(_workspace, "out.txt")), transcript);
        Assert.Equal("hi", File.ReadAllText(Path.Combine(_workspace, "out.txt")));
        Assert.True(File.Exists(Mem("manifest.json")));

        var events = Directory.EnumerateFiles(Mem("events"), "*.json")
            .Select(f => JsonNode.Parse(File.ReadAllText(f))!.AsObject())
            .ToList();
        var types = events.Select(e => e["type"]!.GetValue<string>()).ToList();
        Assert.Contains("workspace.initialized", types);
        Assert.Contains("task.started", types);
        Assert.Contains("tool.executed", types);
        Assert.Contains("file.changed", types);
        Assert.Contains("task.completed", types);
        var changed = events.Single(e => e["type"]!.GetValue<string>() == "file.changed")["payload"]!;
        Assert.Equal("out.txt", changed["path"]!.GetValue<string>());
        Assert.Equal("write_file", changed["attribution"]!.GetValue<string>());

        // The events reload and verify, and the task is a vault note linking the changed file.
        var vault = _bridge.Memory.Vault();
        var task = Assert.Single(vault.Notes, n => n.Kind == "task");
        Assert.Contains("file:out.txt", task.LinkList);
        Assert.Contains("Created out.txt.", task.Body);
        Assert.True(_bridge.Memory.AccessStatus().MemoryReady);
        Assert.Equal(MemoryRole.Owner, _bridge.Memory.AccessStatus().Role);

        // Task history is offered to the next prompt as data, in its own section.
        var report = _bridge.EffectiveSystemPromptReport(_workspace);
        Assert.Contains("project_memory", report);
        Assert.Contains("Create the output file", report);
    }

    [Fact]
    public async Task ChatConversationsAndRemoteWorkspacesGetNoVault()
    {
        await _router.RefreshAsync();
        var chat = new AgentBridge(_router, new SupportPaths(_root, _root, _root, _root, _root, _root, _root, _root),
            area: AgentArea.Chat, sessionFileName: "memory-chat.json");
        await chat.StartAsync("");
        Assert.False(chat.Memory.AccessStatus().MemoryReady);
        Assert.Equal("", chat.Memory.Snapshot("x").Text);
        Assert.False(Directory.Exists(Mem()));
    }

    private sealed class ToolThenAnswerProvider : IDisposable
    {
        private readonly NativeProviderGateway _gateway;
        private int _count;

        public ToolThenAnswerProvider() => _gateway = TestPorts.Start(HandleAsync);

        public Uri Url => _gateway.Url;

        private Task<NativeGatewayResponse> HandleAsync(NativeGatewayRequest request)
        {
            // Model discovery and connection checks also reach this gateway; only chat turns count.
            if (!Encoding.UTF8.GetString(request.Body).Contains("\"messages\"", StringComparison.Ordinal))
                return Task.FromResult(new NativeGatewayResponse(200, "{\"data\":[]}"u8.ToArray()));
            var message = Interlocked.Increment(ref _count) == 1
                ? new JsonObject
                {
                    ["role"] = "assistant",
                    ["content"] = "",
                    ["tool_calls"] = new JsonArray
                    {
                        new JsonObject
                        {
                            ["id"] = "call-1",
                            ["type"] = "function",
                            ["function"] = new JsonObject
                            {
                                ["name"] = "write_file",
                                ["arguments"] = """{"path":"out.txt","content":"hi"}""",
                            },
                        },
                    },
                }
                : new JsonObject { ["role"] = "assistant", ["content"] = "Created out.txt." };
            var body = new JsonObject { ["choices"] = new JsonArray { new JsonObject { ["message"] = message } } }.ToJsonString();
            return Task.FromResult(new NativeGatewayResponse(200, Encoding.UTF8.GetBytes(body)));
        }

        public void Dispose() => _gateway.Dispose();
    }
}
