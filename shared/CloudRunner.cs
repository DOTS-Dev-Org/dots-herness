// Copyright (c) 2026 DOTS
// Headless HerNess agent for cloud runs (parity with the macOS Cloud work location).
//
// The herness-cloud.yml workflow in the user's repository runs this on a
// GitHub-hosted runner in two steps: `run` executes the task in the checkout
// and streams the transcript to the HerNess API, and `complete` reports the
// final status once the workflow has pushed the changes to a branch. Both
// authenticate with a GitHub Actions OIDC token; the API checks that its
// repository and workflow match the run, so no HerNess secret is stored in
// the repository.

using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using PluginRuntime;

namespace DotsHarnessCore;

public sealed record CloudRunnerOptions(
    string RunId,
    string ApiUrl,
    string Workspace,
    string ResultPath,
    string OidcAudience,
    string? Prompt,
    string Provider,
    string? ApiKey,
    string? Model,
    string? BaseUrl)
{
    public const string DefaultApiUrl = "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev";
    public const string DefaultOidcAudience = "https://dots.net.tr/herness-cloud";
    public const string DefaultProvider = "anthropic";

    /// Reads the workflow environment. Throws <see cref="ArgumentException"/> with a user-facing reason.
    public static CloudRunnerOptions FromEnvironment(Func<string, string?> get)
    {
        string? Value(string name) => string.IsNullOrWhiteSpace(get(name)) ? null : get(name)!.Trim();

        var runId = Value("HERNESS_RUN_ID") ?? throw new ArgumentException("HERNESS_RUN_ID is required.");
        if (!Guid.TryParse(runId, out _)) throw new ArgumentException("HERNESS_RUN_ID must be a run id created by HerNess.");
        var apiUrl = (Value("HERNESS_API_URL") ?? DefaultApiUrl).TrimEnd('/');
        if (!Uri.TryCreate(apiUrl, UriKind.Absolute, out var api)
            || !(api.Scheme == Uri.UriSchemeHttps || (api.Scheme == Uri.UriSchemeHttp && api.IsLoopback)))
        {
            throw new ArgumentException("HERNESS_API_URL must be an https URL.");
        }
        var baseUrl = Value("HERNESS_BASE_URL");
        if (baseUrl is not null && !Uri.TryCreate(baseUrl, UriKind.Absolute, out _))
        {
            throw new ArgumentException("HERNESS_BASE_URL must be an absolute URL.");
        }
        return new CloudRunnerOptions(
            runId,
            apiUrl,
            Value("GITHUB_WORKSPACE") ?? Directory.GetCurrentDirectory(),
            Value("HERNESS_RESULT") ?? Path.Combine(Path.GetTempPath(), "herness-result.json"),
            Value("HERNESS_OIDC_AUDIENCE") ?? DefaultOidcAudience,
            get("HERNESS_PROMPT")?.Trim() is { Length: > 0 } prompt ? prompt : null,
            (Value("HERNESS_PROVIDER") ?? DefaultProvider).ToLowerInvariant(),
            Value("HERNESS_API_KEY"),
            Value("HERNESS_MODEL"),
            baseUrl);
    }

    /// Catalog providers a cloud run can use with an API key alone.
    public static IReadOnlyList<RouterProviderKind> ApiKeyProviders =>
        RouterCatalog.Providers.Where(p => p.Kind == RouterAuthKind.ApiKey && !string.IsNullOrWhiteSpace(p.BaseUrl)).ToList();

    public static RouterProviderKind? ResolveProvider(string id) =>
        ApiKeyProviders.FirstOrDefault(p => string.Equals(p.Id, id, StringComparison.OrdinalIgnoreCase));
}

public sealed record CloudRunEvent(string Kind, string Text);

/// One transcript row as the runner sees it at a polling tick.
public sealed record CloudTranscriptMessage(string Id, ChatKind Kind, string Text, bool Streaming);

/// <summary>
/// Turns conversation snapshots into append-only events. A row is sent once,
/// when it is final: it stopped streaming and a later row exists (a tool row
/// is rewritten with its output before the next row appears), or the run ended.
/// </summary>
public sealed class CloudRunTranscript
{
    private readonly HashSet<string> _sent = new(StringComparer.Ordinal);

    public IReadOnlyList<CloudRunEvent> Take(IReadOnlyList<CloudTranscriptMessage> messages, bool final)
    {
        var events = new List<CloudRunEvent>();
        for (var index = 0; index < messages.Count; index++)
        {
            var message = messages[index];
            if (_sent.Contains(message.Id)) continue;
            var settled = final || (!message.Streaming && index < messages.Count - 1);
            if (!settled) break;
            _sent.Add(message.Id);
            if (string.IsNullOrWhiteSpace(message.Text)) continue;
            events.Add(new CloudRunEvent(KindName(message.Kind), message.Text));
        }
        return events;
    }

    public static string KindName(ChatKind kind) => kind switch
    {
        ChatKind.User => "user",
        ChatKind.Assistant => "assistant",
        ChatKind.Tool => "tool",
        ChatKind.Plan => "plan",
        _ => "system",
    };
}

/// What the `run` step leaves for the `complete` step.
public sealed record CloudRunResult(string Status, string? Summary, string? Error)
{
    public const int MaxSummaryChars = 4000;

    public void Write(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var json = new JsonObject { ["status"] = Status, ["summary"] = Summary, ["error"] = Error };
        File.WriteAllText(path, json.ToJsonString());
    }

    public static CloudRunResult? Read(string path)
    {
        try
        {
            var json = JsonNode.Parse(File.ReadAllText(path)) as JsonObject;
            var status = json?["status"]?.GetValue<string>();
            return status is null ? null : new CloudRunResult(status, json!["summary"]?.GetValue<string>(), json["error"]?.GetValue<string>());
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// The status reported to HerNess. A missing result means the agent step
    /// crashed or was cancelled before it wrote one; a failed push turns a
    /// successful run into a failure, because its changes were not kept.
    /// </summary>
    public static CloudRunResult Resolve(CloudRunResult? result, string? agentOutcome, string? pushOutcome)
    {
        var resolved = result ?? (agentOutcome == "cancelled"
            ? new CloudRunResult("cancelled", null, null)
            : new CloudRunResult("failed", null, "The agent step ended without a result."));
        if (pushOutcome == "failure" && resolved.Status != "failed")
        {
            resolved = resolved with { Status = "failed", Error = "The changes could not be pushed to a branch." };
        }
        return resolved;
    }
}

/// Mints GitHub Actions OIDC tokens for the HerNess API audience.
public sealed class GitHubOidcTokenSource
{
    private static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(4);
    private readonly HttpClient _http;
    private readonly string _requestUrl;
    private readonly string _requestToken;
    private readonly string _audience;
    private string? _token;
    private DateTimeOffset _expiresAt;

    public GitHubOidcTokenSource(HttpClient http, string requestUrl, string requestToken, string audience)
    {
        _http = http;
        _requestUrl = requestUrl;
        _requestToken = requestToken;
        _audience = audience;
    }

    /// Null outside GitHub Actions or without `permissions: id-token: write`.
    public static GitHubOidcTokenSource? FromEnvironment(HttpClient http, Func<string, string?> get, string audience)
    {
        var url = get("ACTIONS_ID_TOKEN_REQUEST_URL");
        var token = get("ACTIONS_ID_TOKEN_REQUEST_TOKEN");
        return string.IsNullOrWhiteSpace(url) || string.IsNullOrWhiteSpace(token) ? null : new GitHubOidcTokenSource(http, url, token, audience);
    }

    public async Task<string> TokenAsync(CancellationToken ct)
    {
        if (_token is not null && DateTimeOffset.UtcNow < _expiresAt) return _token;
        var separator = _requestUrl.Contains('?') ? '&' : '?';
        using var request = new HttpRequestMessage(HttpMethod.Get, $"{_requestUrl}{separator}audience={Uri.EscapeDataString(_audience)}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _requestToken);
        using var response = await _http.SendAsync(request, ct).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        var body = JsonNode.Parse(await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
        _token = body?["value"]?.GetValue<string>() ?? throw new InvalidOperationException("GitHub returned no OIDC token.");
        _expiresAt = DateTimeOffset.UtcNow + Lifetime;
        return _token;
    }
}

/// The runner side of the HerNess cloud-run API.
public sealed class CloudRunReporter
{
    public const int MaxEventsPerBatch = 50;
    private readonly HttpClient _http;
    private readonly string _runUrl;
    private readonly Func<CancellationToken, Task<string>> _token;

    public CloudRunReporter(HttpClient http, string apiUrl, string runId, Func<CancellationToken, Task<string>> token)
    {
        _http = http;
        _runUrl = $"{apiUrl.TrimEnd('/')}/api/cloud-runs/{Uri.EscapeDataString(runId)}";
        _token = token;
    }

    /// Sends events (an empty list is a heartbeat). Returns whether the user asked to cancel.
    public async Task<bool> PostEventsAsync(IReadOnlyList<CloudRunEvent> events, CancellationToken ct)
    {
        var cancel = false;
        var offset = 0;
        do
        {
            var batch = events.Skip(offset).Take(MaxEventsPerBatch)
                .Select(e => (JsonNode)new JsonObject { ["kind"] = e.Kind, ["text"] = e.Text })
                .ToArray();
            var response = await PostAsync("runner/events", new JsonObject { ["events"] = new JsonArray(batch) }, ct).ConfigureAwait(false);
            cancel |= response?["cancel_requested"]?.GetValue<bool>() == true;
            offset += MaxEventsPerBatch;
        } while (offset < events.Count);
        return cancel;
    }

    public Task CompleteAsync(CloudRunResult result, string? branch, string? commit, CancellationToken ct)
    {
        var body = new JsonObject { ["status"] = result.Status };
        if (!string.IsNullOrWhiteSpace(result.Summary)) body["summary"] = Truncate(result.Summary, CloudRunResult.MaxSummaryChars);
        if (!string.IsNullOrWhiteSpace(result.Error)) body["error"] = Truncate(result.Error, 2000);
        if (!string.IsNullOrWhiteSpace(branch)) body["branch"] = branch;
        if (!string.IsNullOrWhiteSpace(commit)) body["commit"] = commit;
        return PostAsync("runner/complete", body, ct);
    }

    private Task<JsonNode?> PostAsync(string path, JsonObject body, CancellationToken ct) =>
        RetryAsync(async () =>
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, $"{_runUrl}/{path}")
            {
                Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
            };
            request.Headers.Add("X-HerNess-OIDC-Token", await _token(ct).ConfigureAwait(false));
            using var response = await _http.SendAsync(request, ct).ConfigureAwait(false);
            var text = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                throw new HttpRequestException($"HerNess API {(int)response.StatusCode} on {path}: {Truncate(text, 300)}", null, response.StatusCode);
            }
            return string.IsNullOrWhiteSpace(text) ? null : JsonNode.Parse(text);
        }, ct);

    private static async Task<T> RetryAsync<T>(Func<Task<T>> action, CancellationToken ct)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                return await action().ConfigureAwait(false);
            }
            catch (HttpRequestException ex) when (attempt < 4 && IsRetryable(ex))
            {
                await Task.Delay(TimeSpan.FromSeconds(2 << (attempt - 1)), ct).ConfigureAwait(false);
            }
        }
    }

    // A 4xx other than a rate limit is a contract or permission error: retrying cannot fix it.
    private static bool IsRetryable(HttpRequestException ex) =>
        ex.StatusCode is null || (int)ex.StatusCode >= 500 || (int)ex.StatusCode == 429;

    internal static string Truncate(string value, int max) => value.Length <= max ? value : value[..max];
}

public sealed class CloudRunner
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan HeartbeatInterval = TimeSpan.FromSeconds(20);
    // Read once, then removed so agent commands never inherit them.
    private static readonly string[] SensitiveVariables =
    [
        "HERNESS_API_KEY",
        "ACTIONS_ID_TOKEN_REQUEST_URL",
        "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
        "ACTIONS_RUNTIME_TOKEN",
    ];

    private readonly CloudRunnerOptions _options;
    private readonly CloudRunReporter _reporter;
    private readonly Action<string> _log;
    private readonly SupportPaths _paths;

    public CloudRunner(CloudRunnerOptions options, CloudRunReporter reporter, Action<string> log, SupportPaths? paths = null)
    {
        _options = options;
        _reporter = reporter;
        _log = log;
        _paths = paths ?? SupportPaths.Default();
    }

    public static void ScrubEnvironment()
    {
        foreach (var name in SensitiveVariables) Environment.SetEnvironmentVariable(name, null);
    }

    /// Runs the task and writes the result file. Returns the process exit code.
    public async Task<int> RunAsync(CancellationToken ct)
    {
        CloudRunResult result;
        try
        {
            result = await ExecuteAsync(ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            _log($"Cloud run failed: {ex.Message}");
            result = new CloudRunResult("failed", null, CloudRunReporter.Truncate(ex.Message, 2000));
        }
        result.Write(_options.ResultPath);
        WriteStepSummary(result);
        return result.Status == "failed" ? 1 : 0;
    }

    /// Reports the final status after the workflow pushed (or failed to push) the changes.
    public static async Task<int> CompleteAsync(CloudRunnerOptions options, CloudRunReporter reporter, Func<string, string?> get, CancellationToken ct)
    {
        var result = CloudRunResult.Resolve(
            CloudRunResult.Read(options.ResultPath),
            get("HERNESS_AGENT_OUTCOME"),
            get("HERNESS_PUSH_OUTCOME"));
        await reporter.CompleteAsync(result, get("HERNESS_RESULT_BRANCH"), get("HERNESS_RESULT_COMMIT"), ct).ConfigureAwait(false);
        return 0;
    }

    private async Task<CloudRunResult> ExecuteAsync(CancellationToken ct)
    {
        var prompt = _options.Prompt ?? throw new ArgumentException("HERNESS_PROMPT is empty.");
        var apiKey = _options.ApiKey ?? throw new ArgumentException("Add the HERNESS_API_KEY secret to this repository's Actions secrets.");
        if (await _reporter.PostEventsAsync([new CloudRunEvent("status", "Runner started.")], ct).ConfigureAwait(false))
        {
            return new CloudRunResult("cancelled", null, null);
        }

        using var router = new RouterController(_paths, providerStore: new NativeProviderStore(_paths.Root, new MemoryProviderSecretStore()));
        AddAccount(router, apiKey);
        await router.RefreshAsync().ConfigureAwait(false);
        if (!string.IsNullOrWhiteSpace(_options.Model)) router.SelectedModelID = _options.Model;
        if (!router.HasActiveRoute) throw new InvalidOperationException(router.Error ?? "No model provider is active.");

        var bridge = new AgentBridge(router, _paths)
        {
            // The runner is a throwaway VM with a token-free checkout: nothing to approve.
            NonInteractive = true,
            AutoApproveCommands = true,
        };
        await bridge.StartAsync(_options.Workspace).ConfigureAwait(false);
        await bridge.NewConversationAsync(_options.Workspace).ConfigureAwait(false);
        var conversationId = bridge.SelectedId ?? throw new InvalidOperationException("Could not open a conversation.");
        _log($"Model: {router.SelectedModelID}");

        var transcript = new CloudRunTranscript();
        var pending = new List<CloudRunEvent>();
        var cancelled = false;
        var lastPost = DateTimeOffset.UtcNow;
        var send = bridge.SendAsync(prompt);
        while (true)
        {
            var finished = await Task.WhenAny(send, Task.Delay(PollInterval, ct)).ConfigureAwait(false) == send;
            ct.ThrowIfCancellationRequested();
            if (Snapshot(bridge, conversationId) is { } messages) pending.AddRange(transcript.Take(messages, final: finished));
            if (pending.Count > 0 || DateTimeOffset.UtcNow - lastPost >= HeartbeatInterval || finished)
            {
                try
                {
                    var cancel = await _reporter.PostEventsAsync(pending, ct).ConfigureAwait(false);
                    pending.Clear();
                    lastPost = DateTimeOffset.UtcNow;
                    if (cancel && !cancelled && !finished)
                    {
                        cancelled = true;
                        _log("Cancellation requested from HerNess.");
                        await bridge.CancelAsync().ConfigureAwait(false);
                    }
                }
                catch (HttpRequestException ex)
                {
                    // Keep the events for the next tick; the agent's work matters more than the stream.
                    _log($"Event upload failed, will retry: {ex.Message}");
                }
            }
            if (finished) break;
        }
        await send.ConfigureAwait(false);

        if (cancelled) return new CloudRunResult("cancelled", null, null);
        var last = Snapshot(bridge, conversationId)?.LastOrDefault();
        return last is { Kind: ChatKind.Assistant } && !string.IsNullOrWhiteSpace(last.Text)
            ? new CloudRunResult("succeeded", CloudRunReporter.Truncate(last.Text, CloudRunResult.MaxSummaryChars), null)
            : new CloudRunResult("failed", null, CloudRunReporter.Truncate(last?.Text ?? bridge.Status, 2000));
    }

    private void AddAccount(RouterController router, string apiKey)
    {
        if (_options.BaseUrl is { } baseUrl)
        {
            var endpoint = router.Store.AddCustom("Cloud", "cloud", baseUrl.TrimEnd('/'), NativeProviderProtocol.OpenAiCompatible, "chat", apiKey, _options.Model);
            router.Store.AddCustomAccount(endpoint, apiKey);
            return;
        }
        var provider = CloudRunnerOptions.ResolveProvider(_options.Provider)
            ?? throw new ArgumentException(
                $"HERNESS_PROVIDER '{_options.Provider}' is not supported. Use one of: {string.Join(", ", CloudRunnerOptions.ApiKeyProviders.Select(p => p.Id))}, or set HERNESS_BASE_URL.");
        router.Store.AddAccount(RouterCatalog.Descriptor(provider), "Cloud", apiKey, model: _options.Model);
    }

    private static IReadOnlyList<CloudTranscriptMessage>? Snapshot(AgentBridge bridge, string conversationId)
    {
        try
        {
            return bridge.Conversations.FirstOrDefault(c => c.Id == conversationId)?.Messages
                .ToArray()
                .Select(m => new CloudTranscriptMessage(m.Id, m.Kind, m.Text, m.Streaming))
                .ToList();
        }
        catch (InvalidOperationException)
        {
            // The agent changed the collection mid-copy; the next tick reads it again.
            return null;
        }
    }

    private void WriteStepSummary(CloudRunResult result)
    {
        var path = Environment.GetEnvironmentVariable("GITHUB_STEP_SUMMARY");
        if (string.IsNullOrWhiteSpace(path)) return;
        var text = new StringBuilder()
            .AppendLine($"### HerNess cloud run `{_options.RunId}`")
            .AppendLine()
            .AppendLine($"**Status:** {result.Status}")
            .AppendLine();
        if (!string.IsNullOrWhiteSpace(result.Summary)) text.AppendLine(result.Summary);
        if (!string.IsNullOrWhiteSpace(result.Error)) text.AppendLine($"> {result.Error}");
        try { File.AppendAllText(path, text.ToString()); } catch (IOException) { }
    }
}
