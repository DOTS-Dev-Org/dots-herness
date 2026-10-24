// Copyright (c) 2026 DOTS

using System.Collections.Concurrent;
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
        var endpoint = router.Store.AddCustom("Parallel test", "parallel-test", provider.Url.ToString().TrimEnd('/'), NativeProviderProtocol.OpenAiCompatible, "chat", null, "test-model");
        router.Store.AddCustomAccount(endpoint, null);
        await router.RefreshAsync();
        var bridge = new AgentBridge(router, paths);
        await bridge.StartAsync(workspace);

        await bridge.NewConversationAsync(workspace);
        var first = bridge.SelectedId!;
        var firstRun = bridge.SendAsync("alpha");
        await WaitUntil(() => bridge.Selected?.Running == true);

        await bridge.NewConversationAsync(workspace);
        var second = bridge.SelectedId!;
        Assert.NotEqual(first, second);
        Assert.False(bridge.CanContinue);
        var secondRun = bridge.SendAsync("beta");
        await WaitUntil(() => bridge.Conversations.Count(c => c.Running) == 2);
        Assert.True(bridge.AnyRunBusy);
        Assert.True(bridge.Conversations.Single(c => c.Id == first).Running);

        await Task.WhenAll(firstRun, secondRun).WaitAsync(TimeSpan.FromSeconds(10));
        // Overlap, not wall-clock time: serialized runs can never have two provider calls in flight.
        Assert.Equal(2, provider.PeakConcurrency);
        Assert.False(bridge.AnyRunBusy);

        string Answer(string id) => Assert.Single(bridge.Conversations.Single(c => c.Id == id).Messages, m => m.Kind == ChatKind.Assistant).Text;
        Assert.EndsWith("alpha", Answer(first));
        Assert.EndsWith("beta", Answer(second));
    });

    /// Answers each chat completion after a delay, echoing the last user message.
    /// Sends are admitted in submission order after the workspace content loads, so a
    /// run's Running flag is set on a later UI turn, not inside SendAsync itself.
    private static async Task WaitUntil(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(10);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) throw new TimeoutException("Run state was not reached.");
            await Task.Delay(10);
        }
    }

    private sealed class SlowEchoProvider : IDisposable
    {
        private readonly NativeProviderGateway _gateway;

        public SlowEchoProvider()
        {
            _gateway = LocalTestGateway.Start(HandleAsync);
        }

        public Uri Url => _gateway.Url;
        public int PeakConcurrency => Volatile.Read(ref _peak);
        private int _inFlight;
        private int _peak;

        private async Task<NativeGatewayResponse> HandleAsync(NativeGatewayRequest request)
        {
            Interlocked.Increment(ref _inFlight);
            InterlockedMax(ref _peak, Volatile.Read(ref _inFlight));
            try
            {
                return await ReplyAsync(request);
            }
            finally
            {
                Interlocked.Decrement(ref _inFlight);
            }
        }

        private static void InterlockedMax(ref int target, int value)
        {
            int seen;
            do
            {
                seen = Volatile.Read(ref target);
                if (value <= seen) return;
            } while (Interlocked.CompareExchange(ref target, value, seen) != seen);
        }

        private static async Task<NativeGatewayResponse> ReplyAsync(NativeGatewayRequest request)
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

        public override void Post(SendOrPostCallback d, object? state)
        {
            // Background work can finish after the test body returns; there is no UI thread left to run it.
            try { _queue.Add((d, state)); }
            catch (InvalidOperationException) { }
        }

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
