using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using DotsHarnessCore;
using PluginRuntime;
using Xunit;

/// <summary>End-to-end rewind / edit against a real bridge with a fake provider.</summary>
public sealed class ConversationRewindTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"RewindTests-{Guid.NewGuid():N}");
    private readonly string _workspace;
    private readonly FakeProvider _provider = new();
    private readonly RouterController _router;
    private readonly AgentBridge _bridge;

    public ConversationRewindTests()
    {
        _workspace = Path.Combine(_root, "workspace");
        Directory.CreateDirectory(_workspace);
        File.WriteAllText(A, "one");
        _router = new RouterController(Paths());
        var endpoint = _router.Store.AddCustom("Rewind test", "rewind-test", _provider.Url.ToString().TrimEnd('/'),
            NativeProviderProtocol.OpenAiCompatible, "chat", null);
        _router.Store.AddCustomAccount(endpoint, null);
        _bridge = new AgentBridge(_router, Paths());
    }

    public void Dispose()
    {
        _provider.Dispose();
        _router.Dispose();
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    private string A => Path.Combine(_workspace, "a.txt");

    private SupportPaths Paths() => new(
        _root,
        Path.Combine(_root, "plugins"), Path.Combine(_root, "presets"), Path.Combine(_root, "settings.json"),
        Path.Combine(_root, "host.patch.yml"), Path.Combine(_root, "trust.json"),
        Path.Combine(_root, "models"), Path.Combine(_root, "runtime"));

    /// <summary>Runs one turn during which "the agent" changes the workspace.</summary>
    private async Task<(Conversation Conversation, ChatMessage User)> RunTurnAsync(string prompt, Action edit)
    {
        await _router.RefreshAsync();
        await _bridge.StartAsync(_workspace);
        var turn = _bridge.SendAsync(prompt);
        await _provider.FirstRequest.Task.WaitAsync(TimeSpan.FromSeconds(5));
        edit();
        _provider.ReleaseFirst.TrySetResult(true);
        await turn.WaitAsync(TimeSpan.FromSeconds(10));
        var conversation = _bridge.Selected!;
        return (conversation, conversation.Messages.First(m => m.Kind == ChatKind.User));
    }

    [Fact]
    public async Task RewindRestoresTheFilesATurnChangedAndDropsItsMessages()
    {
        var (conversation, user) = await RunTurnAsync("change it", () =>
        {
            File.WriteAllText(A, "two");
            File.WriteAllText(Path.Combine(_workspace, "b.txt"), "new");
        });
        Assert.True(_bridge.CanRewind(conversation.Id, user.Id));
        Assert.True(_bridge.CanEdit(conversation.Id, user.Id));

        var result = _bridge.Rewind(conversation.Id, user.Id);

        Assert.Empty(result.ConflictPaths);
        Assert.Equal("one", File.ReadAllText(A));
        Assert.False(File.Exists(Path.Combine(_workspace, "b.txt")));
        Assert.Empty(conversation.Messages);
        Assert.True(conversation.Blank);
    }

    [Fact]
    public async Task RewindKeepsAFileTheUserChangedAfterTheTurnAndSaysSo()
    {
        var (conversation, user) = await RunTurnAsync("change it", () => File.WriteAllText(A, "agent"));
        File.WriteAllText(A, "user edit after the turn");

        var result = _bridge.Rewind(conversation.Id, user.Id);

        Assert.Equal(new[] { "a.txt" }, result.ConflictPaths);
        Assert.Equal("user edit after the turn", File.ReadAllText(A));
        Assert.Contains(conversation.Messages, m => m.Kind == ChatKind.System && m.Text.Contains("a.txt"));
    }

    [Fact]
    public async Task EditingTheLatestMessageRestoresTheTurnAndSendsTheNewText()
    {
        var (conversation, user) = await RunTurnAsync("original", () => File.WriteAllText(A, "two"));

        await _bridge.EditLatestMessageAsync(conversation.Id, user.Id, "edited", []);

        Assert.Equal(new[] { "original", "edited" }, _provider.Prompts);
        Assert.Equal("one", File.ReadAllText(A));
        Assert.Equal(1, conversation.Messages.Count(m => m.Kind == ChatKind.User));
        Assert.Equal("edited", conversation.Messages.First(m => m.Kind == ChatKind.User).Text);
    }

    [Fact]
    public async Task EditingRefusesWhenTheUserChangedAFileSinceTheTurn()
    {
        var (conversation, user) = await RunTurnAsync("original", () => File.WriteAllText(A, "agent"));
        File.WriteAllText(A, "user edit after the turn");

        var error = await Assert.ThrowsAsync<ConversationMutationException>(() =>
            _bridge.EditLatestMessageAsync(conversation.Id, user.Id, "edited", []));

        Assert.Equal(ConversationMutationKind.Conflict, error.Kind);
        Assert.Equal(new[] { "a.txt" }, error.Paths);
        // Nothing was touched: the conversation and the file are as they were.
        Assert.Equal("user edit after the turn", File.ReadAllText(A));
        Assert.Contains(conversation.Messages, m => m.Id == user.Id);
        Assert.Single(_provider.Prompts);
    }

    [Fact]
    public async Task UnknownAndOlderMessagesCannotBeMutated()
    {
        var (conversation, user) = await RunTurnAsync("original", () => File.WriteAllText(A, "two"));
        Assert.False(_bridge.CanRewind(conversation.Id, "missing"));
        Assert.False(_bridge.CanEdit(conversation.Id, conversation.Messages.First(m => m.Kind == ChatKind.Assistant).Id));
        var error = await Assert.ThrowsAsync<ConversationMutationException>(() =>
            _bridge.EditLatestMessageAsync(conversation.Id, "missing", "x", []));
        Assert.Equal(ConversationMutationKind.MessageNotFound, error.Kind);
        Assert.NotNull(user);
    }

    private sealed class FakeProvider : IDisposable
    {
        private readonly NativeProviderGateway _gateway;
        private readonly object _lock = new();
        private int _count;

        public FakeProvider()
        {
            _gateway = TestPorts.Start(HandleAsync);
        }

        public Uri Url => _gateway.Url;
        public List<string> Prompts { get; } = new();
        public TaskCompletionSource<bool> FirstRequest { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource<bool> ReleaseFirst { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        private async Task<NativeGatewayResponse> HandleAsync(NativeGatewayRequest request)
        {
            var node = JsonNode.Parse(Encoding.UTF8.GetString(request.Body));
            var prompt = node?["messages"]?.AsArray()
                .LastOrDefault(m => m?["role"]?.GetValue<string>() == "user")?["content"]?.GetValue<string>() ?? "";
            int count;
            lock (_lock)
            {
                // The host snapshot precedes the submitted text on each turn.
                Prompts.Add(prompt.Split("\n\n", StringSplitOptions.None).Last());
                count = ++_count;
            }
            if (count == 1)
            {
                FirstRequest.TrySetResult(true);
                await ReleaseFirst.Task.WaitAsync(TimeSpan.FromSeconds(10));
            }
            return new NativeGatewayResponse(200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"}}]}"u8.ToArray());
        }

        public void Dispose() => _gateway.Dispose();

    }
}
