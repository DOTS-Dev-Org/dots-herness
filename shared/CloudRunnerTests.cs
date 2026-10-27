// Copyright (c) 2026 DOTS

using System.Collections.Concurrent;
using System.Text;
using System.Text.Json.Nodes;
using DotsHarnessCore;
using PluginRuntime;
using Xunit;

namespace DotsHarness.Tests;

public sealed class CloudRunnerTests : IDisposable
{
    private const string RunId = "6f1c2a9e-4b7d-4e2a-9c1f-0a1b2c3d4e5f";
    private readonly string _root = Path.Combine(Path.GetTempPath(), "DotsHarnessCloudRunner-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    private static Func<string, string?> Env(params (string Name, string Value)[] values)
    {
        var map = values.ToDictionary(v => v.Name, v => v.Value);
        return name => map.TryGetValue(name, out var value) ? value : null;
    }

    [Fact]
    public void OptionsReadTheWorkflowEnvironment()
    {
        var options = CloudRunnerOptions.FromEnvironment(Env(
            ("HERNESS_RUN_ID", RunId),
            ("HERNESS_PROMPT", "  fix the build  "),
            ("HERNESS_API_KEY", "key"),
            ("HERNESS_PROVIDER", "OpenAI"),
            ("GITHUB_WORKSPACE", "/work/repo")));

        Assert.Equal(CloudRunnerOptions.DefaultApiUrl, options.ApiUrl);
        Assert.Equal("fix the build", options.Prompt);
        Assert.Equal("openai", options.Provider);
        Assert.Equal("/work/repo", options.Workspace);
        Assert.Null(options.Model);
    }

    [Theory]
    [InlineData(null, "https://api.example")]
    [InlineData("not-a-run-id", "https://api.example")]
    [InlineData(RunId, "http://api.example")]
    public void OptionsRejectAMissingRunIdOrAnInsecureApi(string? runId, string apiUrl)
    {
        var values = new List<(string, string)> { ("HERNESS_API_URL", apiUrl) };
        if (runId is not null) values.Add(("HERNESS_RUN_ID", runId));
        Assert.Throws<ArgumentException>(() => CloudRunnerOptions.FromEnvironment(Env(values.ToArray())));
    }

    [Fact]
    public void OnlyApiKeyProvidersWithAnEndpointCanRunInTheCloud()
    {
        Assert.NotNull(CloudRunnerOptions.ResolveProvider("anthropic"));
        Assert.NotNull(CloudRunnerOptions.ResolveProvider("openrouter"));
        // Browser sign-in and CLI passthrough need a person at the machine.
        Assert.Null(CloudRunnerOptions.ResolveProvider("claude"));
        Assert.Null(CloudRunnerOptions.ResolveProvider("claude-cli"));
        Assert.Null(CloudRunnerOptions.ResolveProvider("glm"));
    }

    [Fact]
    public void TranscriptSendsEachRowOnceWhenItIsFinal()
    {
        var transcript = new CloudRunTranscript();
        var user = new CloudTranscriptMessage("1", ChatKind.User, "task", false);
        var tool = new CloudTranscriptMessage("2", ChatKind.Tool, "run_command: ls", false);
        var streaming = new CloudTranscriptMessage("3", ChatKind.Assistant, "Wor", true);

        // The last row may still be rewritten, so it waits for a successor.
        Assert.Equal(["user"], transcript.Take([user, tool], final: false).Select(e => e.Kind));
        Assert.Equal(["tool"], transcript.Take([user, tool, streaming], final: false).Select(e => e.Kind));
        Assert.Empty(transcript.Take([user, tool, streaming], final: false));

        var done = streaming with { Text = "Working tree is clean.", Streaming = false };
        var events = transcript.Take([user, tool, done, new CloudTranscriptMessage("4", ChatKind.System, "  ", false)], final: true);
        Assert.Equal([new CloudRunEvent("assistant", "Working tree is clean.")], events);
    }

    [Fact]
    public void ResultResolutionReportsCrashesCancelsAndLostPushes()
    {
        Assert.Equal("cancelled", CloudRunResult.Resolve(null, "cancelled", "success").Status);
        Assert.Equal("failed", CloudRunResult.Resolve(null, "failure", "success").Status);

        var succeeded = new CloudRunResult("succeeded", "Done", null);
        Assert.Equal(succeeded, CloudRunResult.Resolve(succeeded, "success", "success"));
        var lost = CloudRunResult.Resolve(succeeded, "success", "failure");
        Assert.Equal("failed", lost.Status);
        Assert.NotNull(lost.Error);
    }

    [Fact]
    public void ResultRoundTripsThroughTheFileTheCompleteStepReads()
    {
        var path = Path.Combine(_root, "nested", "result.json");
        new CloudRunResult("succeeded", "All tests pass.", null).Write(path);
        Assert.Equal(new CloudRunResult("succeeded", "All tests pass.", null), CloudRunResult.Read(path));
        Assert.Null(CloudRunResult.Read(Path.Combine(_root, "missing.json")));
    }

    [Fact]
    public async Task ReporterBatchesEventsAndRelaysCancellation()
    {
        using var api = new FakeHerNessApi { CancelAfterEvents = 60 };
        using var http = new HttpClient();
        var reporter = new CloudRunReporter(http, api.Url, RunId, _ => Task.FromResult("oidc-token"));
        var events = Enumerable.Range(0, 60).Select(i => new CloudRunEvent("tool", $"step {i}")).ToList();

        Assert.True(await reporter.PostEventsAsync(events, CancellationToken.None));
        Assert.Equal([50, 10], api.Batches.Select(b => b.Count));
        Assert.All(api.Tokens, token => Assert.Equal("oidc-token", token));
    }

    [Fact]
    public async Task ReporterDoesNotRetryAForbiddenRun()
    {
        using var api = new FakeHerNessApi { Status = 403 };
        using var http = new HttpClient();
        var reporter = new CloudRunReporter(http, api.Url, RunId, _ => Task.FromResult("wrong-repository"));

        await Assert.ThrowsAsync<HttpRequestException>(() => reporter.PostEventsAsync([], CancellationToken.None));
        Assert.Single(api.Tokens);
    }

    [Fact]
    public async Task RunnerExecutesThePromptStreamsTheTranscriptAndReportsTheResult()
    {
        var workspace = Path.Combine(_root, "workspace");
        Directory.CreateDirectory(workspace);
        using var model = LocalTestGateway.Start(request =>
        {
            var body = new JsonObject
            {
                ["choices"] = new JsonArray(new JsonObject
                {
                    ["message"] = new JsonObject { ["role"] = "assistant", ["content"] = "Cloud task done." },
                }),
            };
            return Task.FromResult(new NativeGatewayResponse(200, Encoding.UTF8.GetBytes(body.ToJsonString())));
        });
        using var api = new FakeHerNessApi();
        using var http = new HttpClient();
        var options = CloudRunnerOptions.FromEnvironment(Env(
            ("HERNESS_RUN_ID", RunId),
            ("HERNESS_API_URL", api.Url),
            ("HERNESS_PROMPT", "Summarize the repository."),
            ("HERNESS_API_KEY", "test-key"),
            ("HERNESS_MODEL", "test-model"),
            ("HERNESS_BASE_URL", model.Url.ToString().TrimEnd('/')),
            ("HERNESS_RESULT", Path.Combine(_root, "result.json")),
            ("GITHUB_WORKSPACE", workspace)));
        var reporter = new CloudRunReporter(http, options.ApiUrl, options.RunId, _ => Task.FromResult("oidc-token"));
        var runner = new CloudRunner(options, reporter, _ => { }, Paths());

        Assert.Equal(0, await runner.RunAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(60)));

        var result = CloudRunResult.Read(options.ResultPath);
        Assert.Equal("succeeded", result?.Status);
        Assert.Equal("Cloud task done.", result?.Summary);
        var sent = api.Batches.SelectMany(b => b).ToList();
        Assert.Equal("status", sent[0].Kind);
        Assert.Contains(sent, e => e.Kind == "user" && e.Text == "Summarize the repository.");
        Assert.Contains(sent, e => e.Kind == "assistant" && e.Text == "Cloud task done.");

        Assert.Equal(0, await CloudRunner.CompleteAsync(options, reporter, Env(("HERNESS_AGENT_OUTCOME", "success"), ("HERNESS_PUSH_OUTCOME", "success"), ("HERNESS_RESULT_BRANCH", "herness/cloud-6f1c2a9e")), CancellationToken.None));
        var complete = Assert.Single(api.Completions);
        Assert.Equal("succeeded", complete["status"]?.GetValue<string>());
        Assert.Equal("herness/cloud-6f1c2a9e", complete["branch"]?.GetValue<string>());
    }

    private SupportPaths Paths() => new(
        _root,
        Path.Combine(_root, "plugins"),
        Path.Combine(_root, "presets"),
        Path.Combine(_root, "settings.json"),
        Path.Combine(_root, "host.patch.yml"),
        Path.Combine(_root, "trust.json"),
        Path.Combine(_root, "models"),
        Path.Combine(_root, "runtime"));

    /// The two runner routes of the HerNess cloud-run API.
    private sealed class FakeHerNessApi : IDisposable
    {
        private readonly NativeProviderGateway _gateway;
        private int _events;

        public FakeHerNessApi() => _gateway = LocalTestGateway.Start(HandleAsync);

        public string Url => _gateway.Url.ToString().TrimEnd('/');
        public int Status { get; init; } = 200;
        public int CancelAfterEvents { get; init; } = int.MaxValue;
        public ConcurrentQueue<List<CloudRunEvent>> Batches { get; } = new();
        public ConcurrentQueue<JsonObject> Completions { get; } = new();
        public ConcurrentQueue<string?> Tokens { get; } = new();

        private Task<NativeGatewayResponse> HandleAsync(NativeGatewayRequest request)
        {
            Tokens.Enqueue(request.Headers.FirstOrDefault(h => h.Key.Equals("X-HerNess-OIDC-Token", StringComparison.OrdinalIgnoreCase)).Value);
            if (Status != 200) return Task.FromResult(Reply(Status, new JsonObject { ["error"] = "forbidden" }));
            var body = JsonNode.Parse(Encoding.UTF8.GetString(request.Body))!.AsObject();
            if (request.Path.EndsWith($"/api/cloud-runs/{RunId}/runner/complete", StringComparison.Ordinal))
            {
                Completions.Enqueue(body);
                return Task.FromResult(Reply(200, new JsonObject()));
            }
            Assert.EndsWith($"/api/cloud-runs/{RunId}/runner/events", request.Path);
            var batch = body["events"]!.AsArray()
                .Select(e => new CloudRunEvent(e!["kind"]!.GetValue<string>(), e["text"]!.GetValue<string>()))
                .ToList();
            Batches.Enqueue(batch);
            var total = Interlocked.Add(ref _events, batch.Count);
            return Task.FromResult(Reply(200, new JsonObject { ["accepted"] = batch.Count, ["cancel_requested"] = total >= CancelAfterEvents }));
        }

        private static NativeGatewayResponse Reply(int status, JsonObject body) => new(status, Encoding.UTF8.GetBytes(body.ToJsonString()));

        public void Dispose() => _gateway.Dispose();
    }
}
