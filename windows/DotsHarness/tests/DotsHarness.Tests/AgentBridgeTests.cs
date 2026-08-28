// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using DotsHarnessCore;
using HarnessPluginKit;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Xunit;

namespace DotsHarness.Tests;

public sealed class AgentBridgeTests
{
    [Theory]
    [InlineData(PromptMode.Queue, "queue")]
    [InlineData(PromptMode.Steer, "steer")]
    public void PromptDeliveryModesMatchHostContract(PromptMode mode, string wireValue)
    {
        Assert.Equal(wireValue, mode.ToWireValue());
    }

    [Fact]
    public void PlanApprovalRequiresAnExplicitPhrase()
    {
        Assert.True(PlanApproval.Matches("  Onaylıyorum!!! "));
        Assert.True(PlanApproval.Matches("apply plan."));
        Assert.True(PlanApproval.Matches("GO AHEAD"));
        Assert.True(PlanApproval.Matches("PLANI UYGULA"));
        Assert.False(PlanApproval.Matches("evet"));
        Assert.False(PlanApproval.Matches("please apply the plan"));
        Assert.False(PlanApproval.Matches("continue"));
    }

    [Fact]
    public void PlanMessagesAndPendingIdRoundTrip()
    {
        var conversation = new Conversation
        {
            Id = "plan-chat",
            Blank = false,
            PendingPlanMessageId = "plan-1",
        };
        conversation.Messages.Add(new ChatMessage { Id = "plan-1", Kind = ChatKind.Plan, Text = "# Plan" });

        var restored = JsonSerializer.Deserialize<Conversation>(JsonSerializer.Serialize(conversation));

        Assert.NotNull(restored);
        Assert.Equal("plan-1", restored!.PendingPlanMessageId);
        Assert.Equal(ChatKind.Plan, Assert.Single(restored.Messages).Kind);
    }

    [Fact]
    public void ContinuationSnapshotRoundTripsToolCallsAndFullOutput()
    {
        var conversation = new Conversation
        {
            Id = "paused-chat",
            Blank = false,
            Continuation = new ContinuationState
            {
                Reason = ContinuationPauseReason.ProviderLimit,
                Provider = "OpenAI",
                Model = "test-model",
                Message = "Provider limit reached.",
            },
            ModelContext =
            [
                new NativeMessage("system", "system prompt"),
                new NativeMessage("user", "inspect"),
                new NativeMessage("assistant", "", ToolCalls: [new NativeToolCall("call-1", "read_file", "{\"path\":\"a.txt\"}")]),
                new NativeMessage("tool", "the complete file contents", "call-1"),
            ],
        };

        var restored = JsonSerializer.Deserialize<Conversation>(JsonSerializer.Serialize(conversation));

        Assert.NotNull(restored);
        Assert.True(restored!.CanContinue);
        Assert.Equal(ContinuationPauseReason.ProviderLimit, restored.Continuation!.Reason);
        Assert.Equal("OpenAI", restored.Continuation.Provider);
        Assert.Equal("test-model", restored.Continuation.Model);
        Assert.Equal(4, restored.ModelContext.Count);
        Assert.Equal("{\"path\":\"a.txt\"}", restored.ModelContext[2].ToolCalls![0].Arguments);
        Assert.Equal("the complete file contents", restored.ModelContext[3].Content);
        Assert.Equal("call-1", restored.ModelContext[3].ToolCallId);
    }

    [Fact]
    public void PlanModeOnlyExposesReadOnlyWorkspaceTools()
    {
        Assert.Equal(new[] { "list_files", "read_file" }, NativeWorkspaceTools.ReadOnlyDefinitions.Select(tool => tool.Name));
        Assert.True(NativeWorkspaceTools.IsReadOnly("list_files"));
        Assert.True(NativeWorkspaceTools.IsReadOnly("read_file"));
        Assert.False(NativeWorkspaceTools.IsReadOnly("write_file"));
        Assert.False(NativeWorkspaceTools.IsReadOnly("run_command"));
    }

    [Fact]
    public void RpcEnvelopeRoundTrip()
    {
        var body = DshJson.DataFrom(new Dictionary<string, object?>
        {
            ["type"] = "client-request",
            ["rpcId"] = "rpc-1",
            ["method"] = "host.describe",
            ["payload"] = new Dictionary<string, object?>(),
        });
        var obj = DshJson.ObjectFrom(body);
        Assert.Equal("client-request", obj["type"].AsString());
        Assert.Equal("host.describe", obj["method"].AsString());
        Assert.Equal("rpc-1", obj["rpcId"].AsString());
    }

    [Fact]
    public void DescribeValueMaps()
    {
        var json = """
            {"type":"server-response","rpcId":"x","result":{"ok":true,"value":{"version":"0.0.1","cwd":"/tmp","provider":"router","model":"gcli/grok-4.6-high","attachedSessions":2}}}
            """u8.ToArray();
        var envelope = DshJson.ObjectFrom(json);
        var value = envelope["result"]?["value"];
        Assert.Equal("router", value?["provider"]?.AsString());
        Assert.Equal("gcli/grok-4.6-high", value?["model"]?.AsString());
        Assert.Equal(2, value?["attachedSessions"]?.AsInt());
    }

    [Fact]
    public void SessionListIgnoresSubagents()
    {
        var parent = SessionProjector.Summary(new Dictionary<string, JsonValue>
        {
            ["sessionId"] = JsonValue.String("session-root"),
            ["blank"] = JsonValue.Bool(false),
            ["running"] = JsonValue.Bool(true),
            ["cwd"] = JsonValue.String("/tmp"),
            ["projections"] = JsonValue.Object(new Dictionary<string, JsonValue>
            {
                ["values"] = JsonValue.Object(new Dictionary<string, JsonValue>
                {
                    ["title"] = JsonValue.String("Root chat<|eos|>"),
                }),
            }),
        });
        Assert.Equal("Root chat", parent.Title);
        Assert.True(parent.Running);
    }

    [Fact]
    public void HistoryFoldUserAssistantAndTool()
    {
        var events = new IReadOnlyDictionary<string, JsonValue>[]
        {
            new Dictionary<string, JsonValue>
            {
                ["type"] = JsonValue.String("user/message"),
                ["seq"] = JsonValue.Number(1),
                ["time"] = JsonValue.Number(1_000),
                ["data"] = JsonValue.Object(new Dictionary<string, JsonValue>
                {
                    ["id"] = JsonValue.String("u1"),
                    ["content"] = JsonValue.Array(JsonValue.Object(new Dictionary<string, JsonValue>
                    {
                        ["type"] = JsonValue.String("text"),
                        ["text"] = JsonValue.String("hello"),
                    })),
                }),
            },
            new Dictionary<string, JsonValue>
            {
                ["type"] = JsonValue.String("assistant/chunk"),
                ["seq"] = JsonValue.Number(2),
                ["time"] = JsonValue.Number(1_100),
                ["data"] = JsonValue.Object(new Dictionary<string, JsonValue>
                {
                    ["chunk"] = JsonValue.Object(new Dictionary<string, JsonValue>
                    {
                        ["type"] = JsonValue.String("text-delta"),
                        ["text"] = JsonValue.String("hi "),
                    }),
                }),
            },
            new Dictionary<string, JsonValue>
            {
                ["type"] = JsonValue.String("assistant/chunk"),
                ["seq"] = JsonValue.Number(3),
                ["time"] = JsonValue.Number(1_200),
                ["data"] = JsonValue.Object(new Dictionary<string, JsonValue>
                {
                    ["chunk"] = JsonValue.Object(new Dictionary<string, JsonValue>
                    {
                        ["type"] = JsonValue.String("text-delta"),
                        ["text"] = JsonValue.String("there"),
                    }),
                }),
            },
            new Dictionary<string, JsonValue>
            {
                ["type"] = JsonValue.String("assistant/message"),
                ["seq"] = JsonValue.Number(4),
                ["time"] = JsonValue.Number(1_300),
                ["data"] = JsonValue.Object(new Dictionary<string, JsonValue>
                {
                    ["message"] = JsonValue.Object(new Dictionary<string, JsonValue>
                    {
                        ["id"] = JsonValue.String("a1"),
                        ["content"] = JsonValue.Array(JsonValue.Object(new Dictionary<string, JsonValue>
                        {
                            ["type"] = JsonValue.String("text"),
                            ["text"] = JsonValue.String("hi there"),
                        })),
                    }),
                }),
            },
            new Dictionary<string, JsonValue>
            {
                ["type"] = JsonValue.String("tool/call"),
                ["seq"] = JsonValue.Number(5),
                ["time"] = JsonValue.Number(1_400),
                ["data"] = JsonValue.Object(new Dictionary<string, JsonValue>
                {
                    ["callId"] = JsonValue.String("c1"),
                    ["name"] = JsonValue.String("bash"),
                }),
            },
        };
        var messages = SessionProjector.Fold(events);
        Assert.Equal(new[] { ChatKind.User, ChatKind.Assistant, ChatKind.Tool }, messages.Select(m => m.Kind));
        Assert.Equal("hello", messages[0].Text);
        Assert.Equal("hi there", messages[1].Text);
        Assert.Equal("a1", messages[1].Id);
        Assert.False(messages[1].Streaming);
        Assert.Equal("→ bash", messages[2].Text);
    }

    [Fact]
    public async Task MultipleQueuedPromptsRunInSubmissionOrder()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessTests-{Guid.NewGuid()}");
        var workspace = Path.Combine(root, "workspace");
        Directory.CreateDirectory(workspace);
        try
        {
            using var provider = new OrderedProvider();
            using var router = new RouterController(PathsFor(root));
            var endpoint = router.Store.AddCustom("Queue test", "queue-test", provider.Url.ToString().TrimEnd('/'), NativeProviderProtocol.OpenAiCompatible, "chat", null);
            router.Store.AddCustomAccount(endpoint, null);
            await router.RefreshAsync();

            var bridge = new AgentBridge(router, PathsFor(root));
            await bridge.StartAsync(workspace);
            var first = bridge.SendAsync("first");
            await provider.FirstRequest.Task.WaitAsync(TimeSpan.FromSeconds(5));

            var second = bridge.SendAsync("second");
            var third = bridge.SendAsync("third");
            Assert.Equal(new[] { "second", "third" }, bridge.Selected?.PendingPrompts.Select(prompt => prompt.Text));
            Assert.Single(provider.Prompts);

            provider.ReleaseFirst.TrySetResult(true);
            await Task.WhenAll(first, second, third).WaitAsync(TimeSpan.FromSeconds(10));
            Assert.Equal(new[] { "first", "second", "third" }, provider.Prompts);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task SteeringQueuedPromptStopsCurrentRunAndRunsSelectedPromptFirst()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessTests-{Guid.NewGuid()}");
        var workspace = Path.Combine(root, "workspace");
        Directory.CreateDirectory(workspace);
        try
        {
            using var provider = new OrderedProvider();
            using var router = new RouterController(PathsFor(root));
            var endpoint = router.Store.AddCustom("Queue test", "queue-test", provider.Url.ToString().TrimEnd('/'), NativeProviderProtocol.OpenAiCompatible, "chat", null);
            router.Store.AddCustomAccount(endpoint, null);
            await router.RefreshAsync();

            var bridge = new AgentBridge(router, PathsFor(root));
            await bridge.StartAsync(workspace);
            var first = bridge.SendAsync("first");
            await provider.FirstRequest.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var second = bridge.SendAsync("second");
            var third = bridge.SendAsync("third");
            var conversation = Assert.IsType<Conversation>(bridge.Selected);
            var thirdPrompt = Assert.Single(conversation.PendingPrompts.Where(prompt => prompt.Text == "third"));

            bridge.SteerPendingPrompt(conversation.Id, thirdPrompt.Id);

            Assert.Equal(PromptMode.Steer, thirdPrompt.Mode);
            Assert.Equal(PromptPlacement.Steering, thirdPrompt.Placement);
            Assert.Single(conversation.Messages.Where(message =>
                message.Kind == ChatKind.System && message.Text == "Generation stopped."));

            provider.ReleaseFirst.TrySetResult(true);
            await Task.WhenAll(first, second, third).WaitAsync(TimeSpan.FromSeconds(10));
            Assert.Equal(new[] { "first", "third", "second" }, provider.Prompts);
            Assert.Equal(1, conversation.Messages.Count(message => message.Text == "third"));
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task ExplicitStopLeavesQueuedPromptsUntilResumed()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessTests-{Guid.NewGuid()}");
        var workspace = Path.Combine(root, "workspace");
        Directory.CreateDirectory(workspace);
        try
        {
            using var provider = new OrderedProvider();
            using var router = new RouterController(PathsFor(root));
            var endpoint = router.Store.AddCustom("Queue test", "queue-test", provider.Url.ToString().TrimEnd('/'), NativeProviderProtocol.OpenAiCompatible, "chat", null);
            router.Store.AddCustomAccount(endpoint, null);
            await router.RefreshAsync();

            var bridge = new AgentBridge(router, PathsFor(root));
            await bridge.StartAsync(workspace);
            var first = bridge.SendAsync("first");
            await provider.FirstRequest.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var second = bridge.SendAsync("second");
            var conversation = Assert.IsType<Conversation>(bridge.Selected);
            var secondPrompt = Assert.Single(conversation.PendingPrompts);

            await bridge.CancelAsync();
            provider.ReleaseFirst.TrySetResult(true);
            await first.WaitAsync(TimeSpan.FromSeconds(10));

            Assert.False(second.IsCompleted);
            Assert.Contains(secondPrompt, conversation.PendingPrompts);
            Assert.Single(conversation.Messages.Where(message =>
                message.Kind == ChatKind.System && message.Text == "Generation stopped."));
            Assert.Equal(new[] { "first" }, provider.Prompts);

            bridge.SteerPendingPrompt(conversation.Id, secondPrompt.Id);
            await second.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.Equal(new[] { "first", "second" }, provider.Prompts);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task PlanRunUsesReadOnlyToolsAndApprovalUsesFullTools()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessTests-{Guid.NewGuid()}");
        var workspace = Path.Combine(root, "workspace");
        Directory.CreateDirectory(workspace);
        try
        {
            using var provider = new PlanProvider();
            using var router = new RouterController(PathsFor(root));
            var endpoint = router.Store.AddCustom("Plan test", "plan-test", provider.Url.ToString().TrimEnd('/'), NativeProviderProtocol.OpenAiCompatible, "chat", null);
            router.Store.AddCustomAccount(endpoint, null);
            await router.RefreshAsync();

            var bridge = new AgentBridge(router, PathsFor(root));
            await bridge.StartAsync(workspace);

            await bridge.SendAsync("inspect the project", planMode: true).WaitAsync(TimeSpan.FromSeconds(10));
            var conversation = Assert.IsType<Conversation>(bridge.Selected);
            var plan = Assert.Single(conversation.Messages.Where(message => message.Kind == ChatKind.Plan));
            Assert.Equal(plan.Id, conversation.PendingPlanMessageId);
            Assert.Equal(new[] { "list_files", "read_file" }, provider.ToolNames[0]);

            await bridge.SendAsync("apply plan").WaitAsync(TimeSpan.FromSeconds(10));

            Assert.Null(conversation.PendingPlanMessageId);
            Assert.Equal(new[] { "list_files", "read_file", "write_file", "run_command" }, provider.ToolNames[1]);
            Assert.Contains(conversation.Messages, message => message.Kind == ChatKind.Assistant && message.Text == "Implemented.");
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task ProviderLimitPausesQueueAndContinueUsesSavedToolContext()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessTests-{Guid.NewGuid()}");
        var workspace = Path.Combine(root, "workspace");
        Directory.CreateDirectory(workspace);
        await File.WriteAllTextAsync(Path.Combine(workspace, "input.txt"), "the full file contents");
        try
        {
            using var provider = new LimitProvider();
            using var router = new RouterController(PathsFor(root));
            var endpoint = router.Store.AddCustom("Limit test", "limit-test", provider.Url.ToString().TrimEnd('/'), NativeProviderProtocol.OpenAiCompatible, "chat", null);
            var account = router.Store.AddCustomAccount(endpoint, null);
            account.Model = "test-model";
            account.Models = ["test-model", "other-model"];
            router.Store.Save();
            await router.RefreshAsync();
            router.SelectedModelID = "test-model";

            var bridge = new AgentBridge(router, PathsFor(root));
            await bridge.StartAsync(workspace);
            var first = bridge.SendAsync("inspect input.txt");
            await provider.LimitRequest.Task.WaitAsync(TimeSpan.FromSeconds(10));

            var queued = bridge.SendAsync("queued after limit");
            provider.ReleaseLimit.TrySetResult(true);
            await first.WaitAsync(TimeSpan.FromSeconds(10));

            var conversation = Assert.IsType<Conversation>(bridge.Selected);
            Assert.True(conversation.CanContinue);
            Assert.False(queued.IsCompleted);
            Assert.Contains(conversation.PendingPrompts, prompt => prompt.Text == "queued after limit");

            router.SelectedModelID = "other-model";
            var continuation = bridge.ContinueAsync();
            await continuation.WaitAsync(TimeSpan.FromSeconds(10));
            await queued.WaitAsync(TimeSpan.FromSeconds(10));

            Assert.Null(conversation.Continuation);
            Assert.Equal(4, provider.Requests.Count);
            var continuationBody = JsonNode.Parse(provider.Requests[2])!.AsObject();
            Assert.Equal("other-model", continuationBody["model"]!.GetValue<string>());
            var messages = continuationBody["messages"]!.AsArray();
            var assistant = Assert.Single(messages.Where(message => message?["role"]?.GetValue<string>() == "assistant"));
            Assert.NotNull(assistant!["tool_calls"]);
            var tool = Assert.Single(messages.Where(message => message?["role"]?.GetValue<string>() == "tool"));
            Assert.Equal("the full file contents", tool!["content"]!.GetValue<string>());
            Assert.Equal("call-1", tool["tool_call_id"]!.GetValue<string>());
            Assert.Equal("other-model", JsonNode.Parse(provider.Requests[3])!["model"]!.GetValue<string>());
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    private static SupportPaths PathsFor(string root) => new(
        root,
        Path.Combine(root, "plugins"),
        Path.Combine(root, "presets"),
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "host.patch.yml"),
        Path.Combine(root, "trust.json"),
        Path.Combine(root, "models"),
        Path.Combine(root, "runtime"));

    private sealed class OrderedProvider : IDisposable
    {
        private readonly NativeProviderGateway _gateway;
        private readonly object _lock = new();
        private int _requestCount;

        public OrderedProvider()
        {
            _gateway = new NativeProviderGateway(FreePort(), HandleAsync);
            _gateway.Start();
        }

        public Uri Url => _gateway.Url;
        public List<string> Prompts { get; } = new();
        public TaskCompletionSource<bool> FirstRequest { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource<bool> ReleaseFirst { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        private async Task<NativeGatewayResponse> HandleAsync(NativeGatewayRequest request)
        {
            var node = JsonNode.Parse(Encoding.UTF8.GetString(request.Body));
            var prompt = node?["messages"]?.AsArray()
                .LastOrDefault(message => message?["role"]?.GetValue<string>() == "user")?["content"]?.GetValue<string>() ?? "";
            int count;
            lock (_lock)
            {
                Prompts.Add(prompt);
                count = ++_requestCount;
            }
            if (count == 1)
            {
                FirstRequest.TrySetResult(true);
                await ReleaseFirst.Task.WaitAsync(TimeSpan.FromSeconds(10));
            }
            return new NativeGatewayResponse(200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"}}]}"u8.ToArray());
        }

        public void Dispose() => _gateway.Dispose();

        private static ushort FreePort()
        {
            using var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            return checked((ushort)((IPEndPoint)listener.LocalEndpoint).Port);
        }
    }

    private sealed class PlanProvider : IDisposable
    {
        private readonly NativeProviderGateway _gateway;
        private readonly object _lock = new();
        private int _requestCount;

        public PlanProvider()
        {
            _gateway = new NativeProviderGateway(FreePort(), HandleAsync);
            _gateway.Start();
        }

        public Uri Url => _gateway.Url;
        public List<string[]> ToolNames { get; } = new();

        private Task<NativeGatewayResponse> HandleAsync(NativeGatewayRequest request)
        {
            var node = JsonNode.Parse(Encoding.UTF8.GetString(request.Body));
            var tools = node?["tools"]?.AsArray()
                .Select(tool => tool?["function"]?["name"]?.GetValue<string>() ?? "")
                .ToArray() ?? [];
            int count;
            lock (_lock)
            {
                ToolNames.Add(tools);
                count = ++_requestCount;
            }
            var text = count == 1 ? "# Plan\n\n## Summary\nInspect the project." : "Implemented.";
            var body = JsonSerializer.SerializeToUtf8Bytes(new
            {
                choices = new[] { new { message = new { role = "assistant", content = text } } },
            });
            return Task.FromResult(new NativeGatewayResponse(200, body));
        }

        public void Dispose() => _gateway.Dispose();

        private static ushort FreePort()
        {
            using var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            return checked((ushort)((IPEndPoint)listener.LocalEndpoint).Port);
        }
    }

    private sealed class LimitProvider : IDisposable
    {
        private readonly NativeProviderGateway _gateway;
        private readonly object _lock = new();
        private int _requestCount;

        public LimitProvider()
        {
            _gateway = new NativeProviderGateway(FreePort(), HandleAsync);
            _gateway.Start();
        }

        public Uri Url => _gateway.Url;
        public List<string> Requests { get; } = new();
        public TaskCompletionSource<bool> LimitRequest { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource<bool> ReleaseLimit { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        private async Task<NativeGatewayResponse> HandleAsync(NativeGatewayRequest request)
        {
            if (request.Method != "POST") return new NativeGatewayResponse(404, []);
            var body = Encoding.UTF8.GetString(request.Body);
            int count;
            lock (_lock)
            {
                Requests.Add(body);
                count = ++_requestCount;
            }
            if (count == 1)
            {
                var toolCall = new
                {
                    choices = new[]
                    {
                        new
                        {
                            message = new
                            {
                                role = "assistant",
                                content = "",
                                tool_calls = new[]
                                {
                                    new
                                    {
                                        id = "call-1",
                                        type = "function",
                                        function = new { name = "read_file", arguments = "{\"path\":\"input.txt\"}" },
                                    },
                                },
                            },
                        },
                    },
                };
                return new NativeGatewayResponse(200, JsonSerializer.SerializeToUtf8Bytes(toolCall));
            }
            if (count == 2)
            {
                LimitRequest.TrySetResult(true);
                await ReleaseLimit.Task.WaitAsync(TimeSpan.FromSeconds(10));
                return new NativeGatewayResponse(429, "{\"error\":{\"message\":\"rate limit reached\"}}"u8.ToArray());
            }
            return new NativeGatewayResponse(200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"resumed\"}}]}"u8.ToArray());
        }

        public void Dispose() => _gateway.Dispose();

        private static ushort FreePort()
        {
            using var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            return checked((ushort)((IPEndPoint)listener.LocalEndpoint).Port);
        }
    }

}
