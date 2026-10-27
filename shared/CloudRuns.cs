// Copyright (c) 2026 DOTS
// Cloud work location for Windows and Linux (parity with macOS CloudRuns.swift).
//
// The app creates a run record in the HerNess API, then dispatches the
// herness-cloud.yml workflow with the user's own GitHub token. The runner
// (CloudRunner.cs) streams the transcript back to the API and pushes its
// changes to a herness/cloud-* branch. This file is the client side: git
// origin detection, the GitHub and HerNess API clients, and CloudRunService,
// the state the desktop UIs bind to.

using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using PluginRuntime;

namespace DotsHarnessCore;

/// <summary>A git remote reduced to host and <c>owner/repo</c> path.</summary>
public sealed record GitRemote(string Host, string Path)
{
    /// Accepts https/ssh URLs and scp-style <c>git@host:owner/repo</c>.
    public static GitRemote? Parse(string? raw)
    {
        var remote = raw?.Trim() ?? "";
        if (remote.EndsWith(".git", StringComparison.Ordinal)) remote = remote[..^4];
        string host, path;
        var scheme = remote.IndexOf("://", StringComparison.Ordinal);
        if (scheme >= 0)
        {
            var rest = remote[(scheme + 3)..];
            var slash = rest.IndexOf('/');
            if (slash < 0) return null;
            host = rest[..slash];
            path = rest[(slash + 1)..];
            var at = host.LastIndexOf('@');
            if (at >= 0) host = host[(at + 1)..];
            var port = host.IndexOf(':');
            if (port >= 0) host = host[..port];
        }
        else
        {
            var at = remote.IndexOf('@');
            var colon = remote.IndexOf(':');
            if (at < 0 || colon < at) return null;
            host = remote[(at + 1)..colon];
            path = remote[(colon + 1)..];
        }
        path = path.Trim('/');
        return host.Length == 0 || path.Length == 0 ? null : new GitRemote(host, path);
    }

    public string WebUrl => $"https://{Host}/{Path}";

    /// The <c>origin</c> URL, read from the git files (worktrees included) without spawning git.
    public static string? OriginUrl(string repositoryPath)
    {
        if (GitDirectory(repositoryPath) is not { } gitDir) return null;
        var common = gitDir;
        var commonFile = System.IO.Path.Combine(gitDir, "commondir");
        if (File.Exists(commonFile)) common = Resolve(File.ReadAllText(commonFile).Trim(), gitDir);
        var config = System.IO.Path.Combine(common, "config");
        if (!File.Exists(config)) return null;
        var inOrigin = false;
        foreach (var raw in File.ReadLines(config))
        {
            var line = raw.Trim();
            if (line.StartsWith('[')) inOrigin = line.Replace(" ", "") == "[remote\"origin\"]";
            else if (inOrigin && line.StartsWith("url", StringComparison.Ordinal) && line.IndexOf('=') is var eq and > 0)
            {
                var value = line[(eq + 1)..].Trim();
                return value.Length == 0 ? null : value;
            }
        }
        return null;
    }

    /// The checked-out branch, or null when HEAD is detached.
    public static string? CurrentBranch(string repositoryPath)
    {
        if (GitDirectory(repositoryPath) is not { } gitDir) return null;
        var head = System.IO.Path.Combine(gitDir, "HEAD");
        if (!File.Exists(head)) return null;
        const string prefix = "ref: refs/heads/";
        var line = File.ReadAllText(head).Trim();
        return line.StartsWith(prefix, StringComparison.Ordinal) ? line[prefix.Length..] : null;
    }

    private static string? GitDirectory(string repositoryPath)
    {
        if (string.IsNullOrWhiteSpace(repositoryPath)) return null;
        var dotGit = System.IO.Path.Combine(repositoryPath, ".git");
        if (Directory.Exists(dotGit)) return dotGit;
        if (!File.Exists(dotGit)) return null;
        var line = File.ReadLines(dotGit).FirstOrDefault() ?? "";
        return line.StartsWith("gitdir:", StringComparison.Ordinal) ? Resolve(line["gitdir:".Length..].Trim(), repositoryPath) : null;
    }

    private static string Resolve(string path, string relativeTo) =>
        System.IO.Path.IsPathRooted(path) ? path : System.IO.Path.GetFullPath(System.IO.Path.Combine(relativeTo, path));
}

/// <summary>A github.com repository a cloud run can target.</summary>
public sealed record GitHubRepository(string Owner, string Name)
{
    public string FullName => $"{Owner}/{Name}";
    public string WebUrl => $"https://github.com/{FullName}";
    public string ActionsSecretsUrl => WebUrl + "/settings/secrets/actions";
    public string BranchUrl(string branch) => $"{WebUrl}/tree/{branch}";

    public static GitHubRepository? Parse(string? fullName)
    {
        var parts = (fullName ?? "").Split('/');
        if (parts.Length != 2 || parts.Any(part => part.Length == 0 || !part.All(c => char.IsLetterOrDigit(c) || c is '-' or '_' or '.')))
            return null;
        return new GitHubRepository(parts[0], parts[1]);
    }

    public static GitHubRepository? FromRemote(GitRemote? remote) =>
        remote is not null && remote.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase) ? Parse(remote.Path) : null;

    public static GitHubRepository? FromWorkspace(string? workspacePath) =>
        string.IsNullOrWhiteSpace(workspacePath) ? null : FromRemote(GitRemote.Parse(GitRemote.OriginUrl(workspacePath)));
}

// Reads the API's lowercase names; the converter matches enum names case-insensitively.
[JsonConverter(typeof(JsonStringEnumConverter<CloudRunStatus>))]
public enum CloudRunStatus
{
    Queued,
    Running,
    Succeeded,
    Failed,
    Cancelled,
}

public sealed record CloudRun(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("repository")] string Repository,
    [property: JsonPropertyName("base_ref")] string BaseRef,
    [property: JsonPropertyName("prompt")] string Prompt,
    [property: JsonPropertyName("model")] string? Model,
    [property: JsonPropertyName("status")] CloudRunStatus Status,
    [property: JsonPropertyName("cancel_requested")] bool CancelRequested,
    [property: JsonPropertyName("github_run_id")] string? GitHubRunId,
    [property: JsonPropertyName("github_run_url")] string? GitHubRunUrl,
    [property: JsonPropertyName("result_branch")] string? ResultBranch,
    [property: JsonPropertyName("result_commit")] string? ResultCommit,
    [property: JsonPropertyName("summary")] string? Summary,
    [property: JsonPropertyName("error")] string? Error,
    [property: JsonPropertyName("event_count")] int EventCount,
    [property: JsonPropertyName("created_at")] DateTimeOffset CreatedAt)
{
    public bool IsActive => Status is CloudRunStatus.Queued or CloudRunStatus.Running;
    public string StatusKey => "cloud.status." + Status.ToString().ToLowerInvariant();
}

/// <summary>One transcript row of a cloud run as the HerNess API returns it.</summary>
public sealed record CloudRunLogEntry(
    [property: JsonPropertyName("seq")] int Seq,
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("text")] string Text);

/// <summary>A failure with a localized, user-facing message.</summary>
public sealed class CloudRunException(string message) : Exception(message);

/// <summary>Localizes a cloud-run message key (AppModel.L on the desktop).</summary>
public delegate string CloudRunText(string key, params object?[] arguments);

/// <summary>
/// The user's own GitHub token: a token saved in HerNess, then GH_TOKEN /
/// GITHUB_TOKEN, then the GitHub CLI's login. It is only sent to api.github.com.
/// </summary>
public static class GitHubCredential
{
    public const string CredentialId = "cloud.github-token";

    public static void Store(IProviderSecretStore secrets, string? token)
    {
        var value = token?.Trim();
        if (string.IsNullOrEmpty(value)) secrets.Delete(CredentialId);
        else secrets.Write(CredentialId, value);
    }

    /// Blocking: may run <c>gh auth token</c>. Call off the UI thread.
    public static string? Resolve(IProviderSecretStore secrets, Func<string, string?>? environment = null)
    {
        if (secrets.Read(CredentialId) is { Length: > 0 } stored) return stored;
        environment ??= Environment.GetEnvironmentVariable;
        foreach (var name in new[] { "GH_TOKEN", "GITHUB_TOKEN" })
        {
            if (environment(name)?.Trim() is { Length: > 0 } token) return token;
        }
        return GhCliToken();
    }

    private static string? GhCliToken()
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo("gh", "auth token --hostname github.com")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            });
            if (process is null) return null;
            var output = process.StandardOutput.ReadToEndAsync();
            if (!process.WaitForExit(10_000))
            {
                process.Kill();
                return null;
            }
            var token = output.Result.Trim();
            return process.ExitCode == 0 && token.Length > 0 ? token : null;
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException)
        {
            return null;
        }
    }
}

public sealed class GitHubActionsClient
{
    public const string WorkflowFile = "herness-cloud.yml";
    public const string WorkflowPath = ".github/workflows/" + WorkflowFile;
    private readonly HttpClient _http;
    private readonly string _token;
    private readonly Uri _apiBase;
    private readonly CloudRunText _text;

    public GitHubActionsClient(HttpClient http, string token, CloudRunText text, Uri? apiBase = null)
    {
        _http = http;
        _token = token;
        _text = text;
        _apiBase = apiBase ?? new Uri("https://api.github.com/");
    }

    public async Task<string> DefaultBranchAsync(GitHubRepository repository, CancellationToken ct = default)
    {
        var (status, body) = await SendAsync(HttpMethod.Get, $"repos/{repository.FullName}", null, ct);
        if (status != HttpStatusCode.OK) throw Failure(status, body);
        return body?["default_branch"]?.GetValue<string>() ?? throw Failure(status, body);
    }

    public async Task DispatchCloudRunAsync(GitHubRepository repository, string reference, IReadOnlyDictionary<string, string> inputs, CancellationToken ct = default)
    {
        var payload = new JsonObject
        {
            ["ref"] = reference,
            ["inputs"] = new JsonObject(inputs.Select(pair => KeyValuePair.Create(pair.Key, (JsonNode?)pair.Value))),
        };
        var (status, body) = await SendAsync(HttpMethod.Post, $"repos/{repository.FullName}/actions/workflows/{WorkflowFile}/dispatches", payload, ct);
        if (status == HttpStatusCode.NotFound) throw new CloudRunException(_text("cloud.error.workflowMissing", repository.FullName, reference));
        if (status is not (HttpStatusCode.NoContent or HttpStatusCode.OK)) throw Failure(status, body);
    }

    /// Commits the workflow file to <paramref name="branch"/>, replacing an older copy.
    public async Task InstallWorkflowAsync(GitHubRepository repository, string branch, string content, CancellationToken ct = default)
    {
        var path = $"repos/{repository.FullName}/contents/{WorkflowPath}";
        var (existingStatus, existing) = await SendAsync(HttpMethod.Get, $"{path}?ref={Uri.EscapeDataString(branch)}", null, ct);
        var payload = new JsonObject
        {
            ["message"] = "Add HerNess cloud workflow",
            ["content"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(content)),
            ["branch"] = branch,
        };
        if (existingStatus == HttpStatusCode.OK && existing?["sha"]?.GetValue<string>() is { } sha) payload["sha"] = sha;
        var (status, body) = await SendAsync(HttpMethod.Put, path, payload, ct);
        if (status is HttpStatusCode.Forbidden or HttpStatusCode.NotFound) throw new CloudRunException(_text("cloud.error.installForbidden"));
        if (status is not (HttpStatusCode.OK or HttpStatusCode.Created)) throw Failure(status, body);
    }

    public async Task CancelRunAsync(GitHubRepository repository, string runId, CancellationToken ct = default)
    {
        var (status, body) = await SendAsync(HttpMethod.Post, $"repos/{repository.FullName}/actions/runs/{Uri.EscapeDataString(runId)}/cancel", null, ct);
        // 409: the run already finished.
        if (status is not (HttpStatusCode.Accepted or HttpStatusCode.Conflict)) throw Failure(status, body);
    }

    private async Task<(HttpStatusCode Status, JsonNode? Body)> SendAsync(HttpMethod method, string path, JsonNode? payload, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(method, new Uri(_apiBase, path));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _token);
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        request.Headers.UserAgent.ParseAdd("HerNess");
        if (payload is not null) request.Content = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json");
        using var response = await _http.SendAsync(request, ct).ConfigureAwait(false);
        var text = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        JsonNode? body = null;
        try { if (!string.IsNullOrWhiteSpace(text)) body = JsonNode.Parse(text); } catch (JsonException) { }
        return (response.StatusCode, body);
    }

    private CloudRunException Failure(HttpStatusCode status, JsonNode? body) =>
        new(_text("cloud.error.github", (int)status, body?["message"]?.GetValue<string>() ?? status.ToString()));
}

/// <summary>The HerNess API side of cloud runs, behind an interface so the service can be tested.</summary>
public interface ICloudRunApi
{
    bool IsSignedIn { get; }
    string ApiBase { get; }
    Task<CloudRun> CreateAsync(GitHubRepository repository, string baseRef, string prompt, string? model, CancellationToken ct = default);
    Task<IReadOnlyList<CloudRun>> ListAsync(CancellationToken ct = default);
    Task<(CloudRun Run, IReadOnlyList<CloudRunLogEntry> Events)> DetailAsync(string id, int after, CancellationToken ct = default);
    Task<CloudRun> CancelAsync(string id, string? error = null, CancellationToken ct = default);
}

public sealed class CloudRunApi(MarketplaceSession session, CloudRunText text) : ICloudRunApi
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public bool IsSignedIn => session.IsSignedIn;
    public string ApiBase => MarketplaceSession.DefaultApiBase.TrimEnd('/');

    public async Task<CloudRun> CreateAsync(GitHubRepository repository, string baseRef, string prompt, string? model, CancellationToken ct = default)
    {
        var body = new JsonObject { ["repository"] = repository.FullName, ["base_ref"] = baseRef, ["prompt"] = prompt };
        if (!string.IsNullOrWhiteSpace(model)) body["model"] = model;
        return Run(await RequestAsync("api/cloud-runs", HttpMethod.Post, body, ct));
    }

    public async Task<IReadOnlyList<CloudRun>> ListAsync(CancellationToken ct = default) =>
        (await RequestAsync("api/cloud-runs", HttpMethod.Get, null, ct))["runs"]?.Deserialize<List<CloudRun>>(Json) ?? [];

    public async Task<(CloudRun Run, IReadOnlyList<CloudRunLogEntry> Events)> DetailAsync(string id, int after, CancellationToken ct = default)
    {
        var json = await RequestAsync($"api/cloud-runs/{Uri.EscapeDataString(id)}?after={after}", HttpMethod.Get, null, ct);
        return (Run(json), json["events"]?.Deserialize<List<CloudRunLogEntry>>(Json) ?? []);
    }

    public async Task<CloudRun> CancelAsync(string id, string? error = null, CancellationToken ct = default)
    {
        var body = new JsonObject();
        if (!string.IsNullOrWhiteSpace(error)) body["error"] = error.Length > 500 ? error[..500] : error;
        return Run(await RequestAsync($"api/cloud-runs/{Uri.EscapeDataString(id)}/cancel", HttpMethod.Post, body, ct));
    }

    private static CloudRun Run(JsonNode json) =>
        json["run"]?.Deserialize<CloudRun>(Json) ?? throw new InvalidDataException("HerNess returned no run.");

    private async Task<JsonNode> RequestAsync(string path, HttpMethod method, JsonNode? body, CancellationToken ct)
    {
        if (!session.IsSignedIn) throw new CloudRunException(text("cloud.error.notSignedIn"));
        var result = await session.AuthorizedDataAsync(
            path,
            method,
            body is null ? null : Encoding.UTF8.GetBytes(body.ToJsonString()),
            body is null ? null : "application/json",
            ct);
        JsonNode? json = null;
        try { json = JsonNode.Parse(result.Data); } catch (JsonException) { }
        if (result.IsSuccess && json is not null) return json;
        var error = json?["error"]?.GetValue<string>() ?? result.Text;
        if (result.StatusCode == HttpStatusCode.TooManyRequests && error == "cloud_run_limit")
            throw new CloudRunException(text("cloud.error.limit", json?["limit"]?.GetValue<int>() ?? 3));
        if (result.StatusCode == HttpStatusCode.Unauthorized) throw new CloudRunException(text("cloud.error.notSignedIn"));
        throw new CloudRunException(text("cloud.error.api", (int)result.StatusCode, error));
    }
}

/// <summary>Cloud run state for the Windows and Linux shells. Call from the UI thread.</summary>
public sealed class CloudRunService : ObservableObject
{
    private const int EventPage = 200;
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(4);
    private readonly ICloudRunApi _api;
    private readonly IProviderSecretStore _secrets;
    private readonly Func<string?> _workspace;
    private readonly Func<string> _model;
    private readonly Func<string?, GitHubActionsClient?> _github;
    private readonly Func<string?> _workflowTemplate;
    private readonly CloudRunText _text;
    private readonly Dictionary<string, List<CloudRunLogEntry>> _events = new(StringComparer.Ordinal);
    private IReadOnlyList<CloudRun> _runs = [];
    private string? _notice;
    private bool _busy;
    private bool _polling;

    public CloudRunService(
        ICloudRunApi api,
        IProviderSecretStore secrets,
        Func<string?> workspace,
        Func<string> model,
        CloudRunText text,
        HttpClient? http = null,
        Uri? gitHubApiBase = null,
        Func<string?>? workflowTemplate = null)
    {
        _api = api;
        _secrets = secrets;
        _workspace = workspace;
        _model = model;
        _text = text;
        var client = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        _github = token => token is null ? null : new GitHubActionsClient(client, token, text, gitHubApiBase);
        _workflowTemplate = workflowTemplate ?? CloudWorkflowTemplate.Read;
    }

    public IReadOnlyList<CloudRun> Runs { get => _runs; private set => SetProperty(ref _runs, value); }
    public string? Notice { get => _notice; set => SetProperty(ref _notice, value); }
    public bool Busy { get => _busy; private set => SetProperty(ref _busy, value); }
    public bool IsSignedIn => _api.IsSignedIn;
    public bool HasStoredGitHubToken => _secrets.Read(GitHubCredential.CredentialId) is { Length: > 0 };
    public GitHubRepository? Repository => GitHubRepository.FromWorkspace(_workspace());

    /// Raised when a run's transcript grows; the argument is the run id.
    public event Action<string>? EventsChanged;

    public IReadOnlyList<CloudRunLogEntry> Events(string runId) =>
        _events.TryGetValue(runId, out var list) ? list : [];

    public void SaveGitHubToken(string? token)
    {
        GitHubCredential.Store(_secrets, token);
        OnPropertyChanged(nameof(HasStoredGitHubToken));
    }

    public async Task<bool> StartAsync(string prompt, CancellationToken ct = default)
    {
        if (Busy) return false;
        Busy = true;
        Notice = null;
        try
        {
            var workspace = _workspace();
            var repository = GitHubRepository.FromWorkspace(workspace)
                ?? throw new CloudRunException(_text("cloud.error.notGitHub"));
            if (!_api.IsSignedIn) throw new CloudRunException(_text("cloud.error.notSignedIn"));
            var github = await GitHubAsync();
            // The runner checks out what GitHub has: unpushed commits are not part of the run.
            var baseRef = GitRemote.CurrentBranch(workspace!) ?? await github.DefaultBranchAsync(repository, ct);
            var model = _model().Trim();
            var run = await _api.CreateAsync(repository, baseRef, prompt, model.Length == 0 ? null : model, ct);
            Upsert(run);
            try
            {
                var inputs = new Dictionary<string, string> { ["run_id"] = run.Id, ["prompt"] = prompt, ["api_url"] = _api.ApiBase };
                if (model.Length > 0) inputs["model"] = model;
                await github.DispatchCloudRunAsync(repository, baseRef, inputs, ct);
            }
            catch (Exception error)
            {
                // Close the record so a failed dispatch does not hold an active-run slot.
                try { Upsert(await _api.CancelAsync(run.Id, error.Message, ct)); } catch (Exception) { }
                throw;
            }
            EnsurePolling();
            return true;
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            Notice = error.Message;
            return false;
        }
        finally
        {
            Busy = false;
        }
    }

    public async Task RefreshAsync(CancellationToken ct = default)
    {
        OnPropertyChanged(nameof(IsSignedIn));
        if (!_api.IsSignedIn) return;
        try
        {
            Runs = await _api.ListAsync(ct);
            EnsurePolling();
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            Notice = error.Message;
        }
    }

    /// Fetches the run and every event after the last one received.
    public async Task RefreshRunAsync(string id, CancellationToken ct = default)
    {
        try
        {
            while (true)
            {
                var after = _events.TryGetValue(id, out var known) && known.Count > 0 ? known[^1].Seq : 0;
                var (run, events) = await _api.DetailAsync(id, after, ct);
                Upsert(run);
                if (events.Count > 0)
                {
                    if (!_events.TryGetValue(id, out var list)) _events[id] = list = [];
                    // A poll and a manual refresh can both ask from the same seq.
                    var added = false;
                    foreach (var entry in events)
                    {
                        if (list.Count > 0 && entry.Seq <= list[^1].Seq) continue;
                        list.Add(entry);
                        added = true;
                    }
                    if (added) EventsChanged?.Invoke(id);
                }
                if (events.Count < EventPage) break;
            }
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            Notice = error.Message;
        }
    }

    public async Task CancelAsync(CloudRun run, CancellationToken ct = default)
    {
        try
        {
            Upsert(await _api.CancelAsync(run.Id, null, ct));
            // The runner stops at its next heartbeat; cancelling the job also stops one still installing.
            if (run.GitHubRunId is { } runId && GitHubRepository.Parse(run.Repository) is { } repository)
            {
                try { await (await GitHubAsync()).CancelRunAsync(repository, runId, ct); } catch (CloudRunException) { }
            }
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            Notice = error.Message;
        }
    }

    /// Commits herness-cloud.yml to the repository's default branch.
    public async Task InstallWorkflowAsync(CancellationToken ct = default)
    {
        if (Busy) return;
        Busy = true;
        Notice = null;
        try
        {
            var repository = Repository ?? throw new CloudRunException(_text("cloud.error.notGitHub"));
            var template = _workflowTemplate() ?? throw new CloudRunException("herness-cloud.yml is missing from the app.");
            var github = await GitHubAsync();
            var branch = await github.DefaultBranchAsync(repository, ct);
            await github.InstallWorkflowAsync(repository, branch, template, ct);
            Notice = _text("cloud.installed", repository.FullName, branch);
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            Notice = error.Message;
        }
        finally
        {
            Busy = false;
        }
    }

    private async Task<GitHubActionsClient> GitHubAsync()
    {
        var token = await Task.Run(() => GitHubCredential.Resolve(_secrets));
        return _github(token) ?? throw new CloudRunException(_text("cloud.error.noToken"));
    }

    private void Upsert(CloudRun run)
    {
        var list = Runs.ToList();
        var index = list.FindIndex(item => item.Id == run.Id);
        if (index >= 0)
        {
            if (list[index] == run) return;
            list[index] = run;
        }
        else list.Insert(0, run);
        Runs = list;
    }

    /// Polls while any run is queued or running, then stops.
    private async void EnsurePolling()
    {
        if (_polling || !Runs.Any(run => run.IsActive)) return;
        _polling = true;
        try
        {
            while (Runs.Where(run => run.IsActive).Select(run => run.Id).ToList() is { Count: > 0 } active)
            {
                foreach (var id in active) await RefreshRunAsync(id);
                await Task.Delay(PollInterval);
            }
        }
        finally
        {
            _polling = false;
        }
    }
}

/// <summary>The workflow template, embedded from shared/cloud/herness-cloud.yml.</summary>
public static class CloudWorkflowTemplate
{
    public static string? Read()
    {
        using var stream = typeof(CloudWorkflowTemplate).Assembly.GetManifestResourceStream("DotsHarnessCore.herness-cloud.yml");
        if (stream is null) return null;
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }
}

public static class CloudLinks
{
    /// Opens an https link (GitHub run, branch, secrets page) in the default browser.
    public static void Open(string? url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps) return;
        try { Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true })?.Dispose(); }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException) { }
    }
}
