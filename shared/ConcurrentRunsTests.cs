// Copyright (c) 2026 DOTS

using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using DotsHarnessCore;
using PluginRuntime;
using Xunit;

namespace DotsHarness.Tests;

public sealed class ConcurrentRunsTests : IDisposable
{
    private static readonly TimeSpan Delay = TimeSpan.FromSeconds(1);
    private readonly string _root = Path.Combine(Path.GetTempPath(), "DotsHarnessConcurrentRuns-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    /// Two chats run at once; the first keeps running after the user switches away.
    [Fact]
    public void ChatsRunInParallelAndKeepRunningInBackground() => UiThread.Run(async () =>
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
        var workspace = Path.Combine(_root, "workspace");
        Directory.CreateDirectory(workspace);
        using var provider = new SlowEchoProvider();
        using var router = new RouterController(paths);
        var endpoint = router.Store.AddCustom("Parallel test", "parallel-test", provider.Url.ToString().TrimEnd('/'), NativeProviderProtocol.OpenAiCompatible, "chat", null);
        router.Store.AddCustomAccount(endpoint, null);
        await router.RefreshAsync();
        var bridge = new AgentBridge(router, paths);
        await bridge.StartAsync(workspace);
        var started = Stopwatch.StartNew();

        await bridge.NewConversationAsync(workspace);
        var first = bridge.SelectedId!;
        var firstRun = bridge.SendAsync("alpha");
        Assert.True(bridge.Selected!.Running);

        await bridge.NewConversationAsync(workspace);
        var second = bridge.SelectedId!;
        Assert.NotEqual(first, second);
        Assert.False(bridge.CanContinue);
        var secondRun = bridge.SendAsync("beta");
        Assert.True(bridge.AnyRunBusy);
        Assert.True(bridge.Conversations.Single(c => c.Id == first).Running);

        await Task.WhenAll(firstRun, secondRun).WaitAsync(TimeSpan.FromSeconds(10));
        Assert.True(started.Elapsed < Delay * 1.9, $"Runs were serialized: {started.Elapsed}");
        Assert.False(bridge.AnyRunBusy);

        string Answer(string id) => Assert.Single(bridge.Conversations.Single(c => c.Id == id).Messages, m => m.Kind == ChatKind.Assistant).Text;
        Assert.EndsWith("alpha", Answer(first));
        Assert.EndsWith("beta", Answer(second));
    });

    /// Answers each chat completion after a delay, echoing the last user message.
    private sealed class SlowEchoProvider : IDisposable
    {
        private readonly NativeProviderGateway _gateway;

        public SlowEchoProvider()
        {
            using var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            var port = checked((ushort)((IPEndPoint)listener.LocalEndpoint).Port);
            listener.Stop();
            _gateway = new NativeProviderGateway(port, HandleAsync);
            _gateway.Start();
        }

        public Uri Url => _gateway.Url;

        private static async Task<NativeGatewayResponse> HandleAsync(NativeGatewayRequest request)
        {
            var prompt = JsonNode.Parse(Encoding.UTF8.GetString(request.Body))?["messages"]?.AsArray()
                .LastOrDefault(message => message?["role"]?.GetValue<string>() == "user")?["content"]?.GetValue<string>() ?? "";
            await Task.Delay(Delay);
            var body = new JsonObject
            {
                ["choices"] = new JsonArray(new JsonObject
                {
                    ["message"] = new JsonObject { ["role"] = "assistant", ["content"] = "echo: " + prompt },
                }),
            };
            return new NativeGatewayResponse(200, Encoding.UTF8.GetBytes(body.ToJsonString()));
        }

        public void Dispose() => _gateway.Dispose();
    }

    /// One thread with a SynchronizationContext, like the app's UI thread: every run
    /// continuation lands here, so the test sees the app's real interleaving.
    private sealed class UiThread : SynchronizationContext
    {
        private readonly BlockingCollection<(SendOrPostCallback Callback, object? State)> _queue = new();

        public override void Post(SendOrPostCallback d, object? state) => _queue.Add((d, state));

        public static void Run(Func<Task> test)
        {
            var context = new UiThread();
            Exception? failure = null;
            var thread = new Thread(() =>
            {
                SetSynchronizationContext(context);
                var task = test();
                task.ContinueWith(_ => context._queue.CompleteAdding(), TaskScheduler.Default);
                foreach (var (callback, state) in context._queue.GetConsumingEnumerable()) callback(state);
                failure = task.Exception?.InnerException;
            });
            thread.Start();
            thread.Join();
            if (failure is not null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
        }
    }
}
