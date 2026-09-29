using System.Text.Json.Nodes;
using DotsHarnessCore;
using Xunit;

public sealed class MCPTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"mcp-{Guid.NewGuid():N}");

    public MCPTests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    /// <summary>Canned JSON-RPC endpoint: answers initialize / tools/list / tools/call.</summary>
    private sealed class StubTransport : IMCPTransport
    {
        public JsonObject? LastCallArguments;

        public Task<string?> SendAsync(string request, bool expectsResponse, CancellationToken ct)
        {
            var obj = JsonNode.Parse(request)!.AsObject();
            if (!expectsResponse) return Task.FromResult<string?>(null);
            var id = obj["id"]!.GetValue<int>();
            JsonObject result = obj["method"]!.GetValue<string>() switch
            {
                "initialize" => new() { ["serverInfo"] = new JsonObject { ["name"] = "stub" } },
                "tools/list" => new()
                {
                    ["tools"] = new JsonArray
                    {
                        new JsonObject
                        {
                            ["name"] = "search", ["description"] = "search docs",
                            ["inputSchema"] = new JsonObject { ["type"] = "object" },
                            ["annotations"] = new JsonObject { ["readOnlyHint"] = true, ["destructiveHint"] = false },
                        },
                        new JsonObject
                        {
                            ["name"] = "wipe", ["description"] = "delete everything",
                            ["inputSchema"] = new JsonObject { ["type"] = "object" },
                            ["annotations"] = new JsonObject { ["destructiveHint"] = true },
                        },
                    },
                },
                "tools/call" => new()
                {
                    ["content"] = new JsonArray { new JsonObject { ["type"] = "text", ["text"] = "ok" } },
                },
                _ => new(),
            };
            if (obj["method"]!.GetValue<string>() == "tools/call")
                LastCallArguments = obj["params"]!["arguments"]!.AsObject().DeepClone().AsObject();
            return Task.FromResult<string?>(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["result"] = result }.ToJsonString());
        }

        public void Dispose() { }
    }

    private MCPRegistry Registry(StubTransport? stub = null, MemoryProviderSecretStore? secrets = null) =>
        new(Path.Combine(_root, "mcp-servers.json"), secrets ?? new MemoryProviderSecretStore())
        {
            TransportOverride = _ => stub ?? new StubTransport(),
        };

    [Fact]
    public async Task ClientDiscoversAndCallsTools()
    {
        var stub = new StubTransport();
        using var client = new MCPClient(new MCPServerConfig { Name = "stub" }, _ => stub);
        await client.ConnectAsync();

        Assert.Equal(new[] { "search", "wipe" }, client.Tools.Select(t => t.Name).OrderBy(n => n));
        Assert.True(client.Tools.Single(t => t.Name == "search").ReadOnlyHint);
        Assert.True(client.Tools.Single(t => t.Name == "wipe").DestructiveHint);
        Assert.Equal("stub", client.ServerInfo);

        var output = await client.CallToolAsync("search", new JsonObject { ["q"] = "hi" });
        Assert.Equal("ok", output);
        Assert.Equal("hi", stub.LastCallArguments!["q"]!.GetValue<string>());
    }

    [Fact]
    public async Task RegistryNamespacesToolsAndGatesAutoRun()
    {
        var registry = Registry();
        var config = new MCPServerConfig { Name = "Docs Server", AutoRunReadOnly = true };
        registry.Upsert(config);
        await registry.ConnectAsync(config.Id);

        Assert.Equal(new[] { "mcp__Docs_Server__search", "mcp__Docs_Server__wipe" },
            registry.ToolDefinitions().Select(t => t.Name).OrderBy(n => n));
        Assert.True(registry.ShouldAutoRun("mcp__Docs_Server__search"));
        // A destructive hint never auto-runs, even with opt-in.
        Assert.False(registry.ShouldAutoRun("mcp__Docs_Server__wipe"));

        config.AutoRunReadOnly = false;
        registry.Upsert(config);
        await registry.ConnectAsync(config.Id);
        Assert.False(registry.ShouldAutoRun("mcp__Docs_Server__search"));
        Assert.IsType<MCPServerState.Connected>(registry.StateOf(config.Id));
    }

    [Fact]
    public async Task SandboxHidesAndRefusesHttpToolsButKeepsThemAfterLeaving()
    {
        var registry = Registry();
        var config = new MCPServerConfig { Name = "Docs Server", Transport = MCPTransportKind.Http };
        registry.Upsert(config);
        await registry.ConnectAsync(config.Id);
        Assert.Equal(2, registry.ToolDefinitions().Count);

        await registry.SetSandboxWorkspaceAsync(_root);
        Assert.Empty(registry.ToolDefinitions());
        await Assert.ThrowsAsync<MCPException>(() =>
            registry.CallAsync("mcp__Docs_Server__search", new JsonObject { ["q"] = "hi" }));

        await registry.SetSandboxWorkspaceAsync(null);
        Assert.Equal(2, registry.ToolDefinitions().Count);
        Assert.Equal("ok", await registry.CallAsync("mcp__Docs_Server__search", new JsonObject()));
    }

    [Fact]
    public async Task ConfigPersistsAndTokenStaysOutOfTheFile()
    {
        var secrets = new MemoryProviderSecretStore();
        var registry = Registry(secrets: secrets);
        var config = new MCPServerConfig { Name = "Docs", Url = "https://mcp.example/rpc", Transport = MCPTransportKind.Http };
        registry.Upsert(config, token: "s3cret-token");

        var file = File.ReadAllText(Path.Combine(_root, "mcp-servers.json"));
        Assert.Contains("mcp.example", file);
        Assert.DoesNotContain("s3cret-token", file);
        Assert.Equal("s3cret-token", registry.Token(config.Id));

        var reloaded = new MCPRegistry(Path.Combine(_root, "mcp-servers.json"), secrets);
        Assert.Equal(config.Id, reloaded.Servers.Single().Id);
        Assert.Equal(MCPTransportKind.Http, reloaded.Servers.Single().Transport);

        registry.Remove(config.Id);
        Assert.Null(registry.Token(config.Id));
        await Task.CompletedTask;
    }

    [Fact]
    public async Task FailedConnectionIsRecordedAndContributesNoTools()
    {
        var registry = new MCPRegistry(Path.Combine(_root, "mcp-servers.json"), new MemoryProviderSecretStore())
        {
            TransportOverride = _ => throw MCPException.Transport("boom"),
        };
        var config = new MCPServerConfig { Name = "Broken" };
        registry.Upsert(config);
        await registry.ConnectAllAsync();
        var failed = Assert.IsType<MCPServerState.Failed>(registry.StateOf(config.Id));
        Assert.Contains("boom", failed.Message);
        Assert.Empty(registry.ToolDefinitions());
    }

    [Fact]
    public void ServerSentEventBodiesAreDecoded()
    {
        var body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"ping\"}\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{}}\n";
        Assert.Equal(3, MCPClient.DecodeJsonRpc(body)["id"]!.GetValue<int>());
        Assert.Throws<MCPException>(() => MCPClient.DecodeJsonRpc("not json"));
    }

    [Fact]
    public void ToolResultTextIsExtractedFromEveryShape()
    {
        Assert.Equal("a", MCPClient.TextBlocks(JsonValue.Create("a")));
        Assert.Equal("ab", MCPClient.TextBlocks(JsonNode.Parse("""[{"type":"text","text":"a"},{"type":"reasoning","text":"x"},{"text":"b"}]""")));
        Assert.Equal("c", MCPClient.TextBlocks(JsonNode.Parse("""{"content":[{"type":"text","text":"c"}]}""")));
    }

    [Fact]
    public async Task ErrorResultsSurfaceAsExceptions()
    {
        var registry = Registry();
        using var client = new MCPClient(new MCPServerConfig { Name = "x" }, _ => new ErrorTransport());
        await client.ConnectAsync();
        var error = await Assert.ThrowsAsync<MCPException>(() => client.CallToolAsync("t", new JsonObject()));
        Assert.Contains("nope", error.Message);
        _ = registry;
    }

    private sealed class ErrorTransport : IMCPTransport
    {
        public Task<string?> SendAsync(string request, bool expectsResponse, CancellationToken ct)
        {
            if (!expectsResponse) return Task.FromResult<string?>(null);
            var obj = JsonNode.Parse(request)!.AsObject();
            var result = obj["method"]!.GetValue<string>() switch
            {
                "tools/call" => new JsonObject
                {
                    ["isError"] = true,
                    ["content"] = new JsonArray { new JsonObject { ["type"] = "text", ["text"] = "nope" } },
                },
                "tools/list" => new JsonObject { ["tools"] = new JsonArray() },
                _ => new JsonObject(),
            };
            return Task.FromResult<string?>(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = obj["id"]!.GetValue<int>(), ["result"] = result }.ToJsonString());
        }

        public void Dispose() { }
    }

    [Fact]
    public async Task StdioTransportTalksToARealChildProcess()
    {
        if (OperatingSystem.IsWindows()) return;
        var script = Path.Combine(_root, "server.sh");
        File.WriteAllText(script, """
            #!/bin/sh
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
              case "$line" in
                *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"serverInfo":{"name":"sh"}}}\n' "$id";;
                *'"method":"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"e","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true,"destructiveHint":false}}]}}\n' "$id";;
                *'"method":"tools/call"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"pong"}]}}\n' "$id";;
              esac
            done
            """.Replace("\r\n", "\n"));
        File.SetUnixFileMode(script, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);

        using var client = new MCPClient(new MCPServerConfig
        {
            Name = "sh", Transport = MCPTransportKind.Stdio, Command = "/bin/sh", Arguments = [script],
        });
        await client.ConnectAsync();
        Assert.Equal("sh", client.ServerInfo);
        Assert.Equal("echo", client.Tools.Single().Name);
        Assert.Equal("pong", await client.CallToolAsync("echo", new JsonObject()));
    }

    [Fact]
    public async Task StdioLaunchFailureIsReportedNotThrownRaw()
    {
        using var client = new MCPClient(new MCPServerConfig
        {
            Name = "missing", Transport = MCPTransportKind.Stdio, Command = "/definitely/not/here",
        });
        var error = await Assert.ThrowsAsync<MCPException>(() => client.ConnectAsync());
        Assert.Contains("failed to launch", error.Message);
    }

    [Fact]
    public void DraftValidatesPerTransportAndRoundTrips()
    {
        var draft = new MCPServerDraft { Name = "  ", Transport = MCPTransportKind.Http, Url = "https://x.example" };
        Assert.NotNull(draft.Validate());
        draft.Name = "Docs";
        Assert.Null(draft.Validate());
        draft.Url = "ftp://x";
        Assert.NotNull(draft.Validate());

        draft.Transport = MCPTransportKind.Stdio;
        Assert.NotNull(draft.Validate());
        draft.Command = "npx";
        draft.ArgumentsText = "-y\n@scope/server\n\n";
        draft.EnvironmentText = "API_KEY=abc=def\nMODE=dev";
        Assert.Null(draft.Validate());
        var config = draft.ToConfig();
        Assert.Equal(new[] { "-y", "@scope/server" }, config.Arguments);
        Assert.Equal("abc=def", config.Environment["API_KEY"]);

        var again = MCPServerDraft.From(config);
        Assert.Equal("npx", again.Command);
        Assert.Contains("MODE=dev", again.EnvironmentText);

        draft.EnvironmentText = "no-equals-sign";
        Assert.Contains("KEY=VALUE", draft.Validate());
    }
}
