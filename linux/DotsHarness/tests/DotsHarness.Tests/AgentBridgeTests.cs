using System.Text;
// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using DotsHarnessCore;
using HarnessPluginKit;
using System.Text.Json;
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
        Assert.Equal(
            new[] { "list_files", "read_file", "grep_files", "run_command" },
            NativeWorkspaceTools.PlanDefinitions.Select(tool => tool.Name));
        Assert.True(NativeWorkspaceTools.IsWorkspaceMutation("write_file"));
        Assert.True(NativeWorkspaceTools.IsWorkspaceMutation("remove_file"));
        Assert.False(NativeWorkspaceTools.IsWorkspaceMutation("run_command"));
        Assert.True(NativeWorkspaceTools.IsReadOnly("list_files"));
        Assert.True(NativeWorkspaceTools.IsReadOnly("read_file"));
        Assert.False(NativeWorkspaceTools.IsReadOnly("write_file"));
        Assert.True(NativeWorkspaceTools.IsReadOnly("grep_files"));
        Assert.False(NativeWorkspaceTools.IsReadOnly("run_command"));
    }

    [Fact]
    public async Task ReadFilePagesAndWriteFileRefusesABlindRewrite()
    {
        var root = Path.Combine(Path.GetTempPath(), "DotsHarnessRead-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        ReadLedger.Reset();
        try
        {
            var file = Path.Combine(root, "a.txt");
            File.WriteAllText(file, string.Join('\n', Enumerable.Range(1, 10).Select(number => $"line {number}")));

            Assert.Equal("line 3\nline 4", await ReadAsync(root, """{"path":"a.txt","offset":3,"limit":2}"""));
            Assert.Contains("10 lines", await ReadAsync(root, """{"path":"a.txt","offset":99}"""));

            // A partial read is not a licence to rewrite the whole file.
            Assert.Contains("before rewriting", await WriteAsync(root, "a.txt", "short"));
            Assert.StartsWith("line 1", File.ReadAllText(file));

            await ReadAsync(root, """{"path":"a.txt"}""");
            Assert.StartsWith("Wrote", await WriteAsync(root, "a.txt", "replaced"));
            Assert.Equal("replaced", File.ReadAllText(file));

            File.WriteAllText(file, "changed by someone else");
            Assert.Contains("changed on disk", await WriteAsync(root, "a.txt", "mine"));
            Assert.Equal("changed by someone else", File.ReadAllText(file));

            // A new file needs no read, and a write refreshes the ledger.
            Assert.StartsWith("Wrote", await WriteAsync(root, "new.txt", "hello"));
            Assert.StartsWith("Wrote", await WriteAsync(root, "new.txt", "hello again"));
        }
        finally
        {
            ReadLedger.Reset();
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task ReadFileCutsOnALineAndNamesTheNextOffset()
    {
        var root = Path.Combine(Path.GetTempPath(), "DotsHarnessRead-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        ReadLedger.Reset();
        try
        {
            var line = new string('x', 1_000);
            File.WriteAllText(
                Path.Combine(root, "big.txt"),
                string.Join('\n', Enumerable.Repeat(line, 200)));

            var first = await ReadAsync(root, """{"path":"big.txt"}""");
            Assert.Contains("[truncated] Continue with offset:", first);
            Assert.True(Encoding.UTF8.GetByteCount(first) <= 60_200);
            Assert.All(
                first.Split('\n').Where(item => item.Length > 0 && !item.StartsWith('[')),
                item => Assert.Equal(1_000, item.Length));
        }
        finally
        {
            ReadLedger.Reset();
            Directory.Delete(root, recursive: true);
        }
    }

    private static Task<string> ReadAsync(string root, string arguments) =>
        NativeWorkspaceTools.ExecuteAsync(new NativeToolCall("read", "read_file", arguments), root);

    private static Task<string> WriteAsync(string root, string path, string content) =>
        NativeWorkspaceTools.ExecuteAsync(
            new NativeToolCall("write", "write_file", JsonSerializer.Serialize(new { path, content })),
            root);

    [Fact]
    public async Task GrepFilesReportsPathLineTextAndSkipsBuildDirectories()
    {
        var root = Path.Combine(Path.GetTempPath(), "DotsHarnessGrep-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(root, "src"));
        Directory.CreateDirectory(Path.Combine(root, "node_modules"));
        try
        {
            File.WriteAllText(Path.Combine(root, "src", "a.cs"), "using X;\nvar needle = 1;\n");
            File.WriteAllText(Path.Combine(root, "src", "b.json"), "{\"needle\": true}");
            File.WriteAllText(Path.Combine(root, "node_modules", "c.cs"), "var needle = 2;");

            var all = await NativeWorkspaceTools.ExecuteAsync(
                new NativeToolCall("call-1", "grep_files", """{"pattern":"needle"}"""), root);
            Assert.Contains("src/a.cs:2:var needle = 1;", all);
            Assert.Contains("src/b.json:1:", all);
            Assert.DoesNotContain("node_modules", all);

            var filtered = await NativeWorkspaceTools.ExecuteAsync(
                new NativeToolCall("call-2", "grep_files", """{"pattern":"needle","extensions":"cs"}"""), root);
            Assert.Contains("src/a.cs:2:", filtered);
            Assert.DoesNotContain("b.json", filtered);

            var none = await NativeWorkspaceTools.ExecuteAsync(
                new NativeToolCall("call-3", "grep_files", """{"pattern":"haystack"}"""), root);
            Assert.Equal("No matches.", none);

            var invalid = await NativeWorkspaceTools.ExecuteAsync(
                new NativeToolCall("call-4", "grep_files", """{"pattern":"[unclosed"}"""), root);
            Assert.StartsWith("Invalid search pattern", invalid);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
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
    public void FirstUserMessageBecomesConversationTitle()
    {
        var conversation = new Conversation { Title = "New chat", Blank = true };
        SessionProjector.Apply(new Dictionary<string, JsonValue>
        {
            ["type"] = JsonValue.String("user/message"),
            ["time"] = JsonValue.Number(1_000),
            ["data"] = JsonValue.Object(new Dictionary<string, JsonValue>
            {
                ["id"] = JsonValue.String("u1"),
                ["content"] = JsonValue.Array(JsonValue.Object(new Dictionary<string, JsonValue>
                {
                    ["type"] = JsonValue.String("text"),
                    ["text"] = JsonValue.String("Fix the sidebar\nKeep this detail below the title"),
                })),
            }),
        }, conversation);

        Assert.Equal("Fix the sidebar", conversation.Title);
        Assert.False(conversation.Blank);
    }

}
