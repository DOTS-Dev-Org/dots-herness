// Copyright (c) 2026 DOTS

using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public sealed class CloudRunsTests : IDisposable
{
    private static readonly CloudRunText Text = (key, arguments) => arguments.Length == 0 ? key : $"{key}:{string.Join("|", arguments)}";
    private readonly string _root = Path.Combine(Path.GetTempPath(), "DotsHarnessCloudRuns-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    [Theory]
    [InlineData("https://github.com/octo/hello")]
    [InlineData("https://github.com/octo/hello.git")]
    [InlineData("git@github.com:octo/hello.git")]
    [InlineData("ssh://git@github.com:22/octo/hello.git")]
    [InlineData("https://token@github.com/octo/hello/")]
    public void RemoteUrlsReduceToHostAndPath(string url)
    {
        Assert.Equal(new GitRemote("github.com", "octo/hello"), GitRemote.Parse(url));
        Assert.Equal("octo/hello", GitHubRepository.FromRemote(GitRemote.Parse(url))?.FullName);
    }

    [Fact]
    public void OnlyGitHubDotComRepositoriesCanRunInTheCloud()
    {
        Assert.Null(GitRemote.Parse("/srv/git/hello.git"));
        Assert.Null(GitHubRepository.FromRemote(GitRemote.Parse("https://gitlab.com/octo/hello")));
        Assert.Null(GitHubRepository.FromRemote(GitRemote.Parse("https://github.com/octo/hello/tree/main")));
        Assert.Null(GitHubRepository.Parse("octo/hel lo"));
    }

    [Fact]
    public void RepositoryAndBranchComeFromTheCheckoutFiles()
    {
        var workspace = Checkout("feature/cloud");
        Assert.Equal("octo/hello", GitHubRepository.FromWorkspace(workspace)?.FullName);
        Assert.Equal("feature/cloud", GitRemote.CurrentBranch(workspace));

        File.WriteAllText(Path.Combine(workspace, ".git", "HEAD"), "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n");
        Assert.Null(GitRemote.CurrentBranch(workspace));
    }

    [Fact]
    public void WorktreeCheckoutsReadTheSharedConfig()
    {
        var main = Path.Combine(_root, "main", ".git");
        var worktreeGit = Path.Combine(main, "worktrees", "side");
        var worktree = Path.Combine(_root, "side");
        Directory.CreateDirectory(worktreeGit);
        Directory.CreateDirectory(worktree);
        File.WriteAllText(Path.Combine(main, "config"), "[remote \"origin\"]\n\turl = https://github.com/octo/hello.git\n");
        File.WriteAllText(Path.Combine(worktreeGit, "commondir"), "../..\n");
        File.WriteAllText(Path.Combine(worktreeGit, "HEAD"), "ref: refs/heads/side\n");
        File.WriteAllText(Path.Combine(worktree, ".git"), $"gitdir: {worktreeGit}\n");

        Assert.Equal("octo/hello", GitHubRepository.FromWorkspace(worktree)?.FullName);
        Assert.Equal("side", GitRemote.CurrentBranch(worktree));
    }

    [Fact]
    public void RunDecodesTheWorkerPayload()
    {
        var run = JsonSerializer.Deserialize<CloudRun>(RunJson("running").ToJsonString(), new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
        Assert.Equal(CloudRunStatus.Running, run.Status);
        Assert.True(run.IsActive);
        Assert.Equal("cloud.status.running", run.StatusKey);
        Assert.Equal("42", run.GitHubRunId);
    }

    [Fact]
    public void WorkflowTemplateIsEmbedded()
    {
        var template = CloudWorkflowTemplate.Read();
        Assert.NotNull(template);
        Assert.Contains("workflow_dispatch:", template);
        Assert.Contains("id-token: write", template);
    }

    [Fact]
    public async Task StartCreatesTheRunAndDispatchesTheWorkflowOnTheCheckedOutBranch()
    {
        using var github = new FakeGitHub();
        var api = new FakeApi();
        var service = Service(api, github, Checkout("main"));

        Assert.True(await service.StartAsync("Fix the build"));

        var dispatch = Assert.Single(github.Requests, r => r.Path.EndsWith("/actions/workflows/herness-cloud.yml/dispatches", StringComparison.Ordinal));
        Assert.Equal("Bearer gh-token", dispatch.Authorization);
        Assert.Equal("main", dispatch.Body!["ref"]!.GetValue<string>());
        Assert.Equal(api.Created!.Id, dispatch.Body["inputs"]!["run_id"]!.GetValue<string>());
        Assert.Equal("Fix the build", dispatch.Body["inputs"]!["prompt"]!.GetValue<string>());
        Assert.Equal(("octo/hello", "main"), (api.Repository, api.BaseRef));
        Assert.Single(service.Runs);
        Assert.Null(service.Notice);
    }

    [Fact]
    public async Task AFailedDispatchClosesTheRunAndExplainsTheMissingWorkflow()
    {
        using var github = new FakeGitHub { DispatchStatus = 404 };
        var api = new FakeApi();
        var service = Service(api, github, Checkout("main"));

        Assert.False(await service.StartAsync("Fix the build"));

        Assert.Equal("cloud.error.workflowMissing:octo/hello|main", service.Notice);
        Assert.Equal(service.Notice, api.CancelError);
        Assert.Equal(CloudRunStatus.Failed, Assert.Single(service.Runs).Status);
    }

    [Fact]
    public async Task StartRefusesAProjectWithoutAGitHubOrigin()
    {
        using var github = new FakeGitHub();
        var workspace = Path.Combine(_root, "plain");
        Directory.CreateDirectory(workspace);
        var service = Service(new FakeApi(), github, workspace);

        Assert.False(await service.StartAsync("Fix the build"));
        Assert.Equal("cloud.error.notGitHub", service.Notice);
        Assert.Empty(github.Requests);
    }

    [Fact]
    public async Task InstallReplacesAnExistingWorkflowOnTheDefaultBranch()
    {
        using var github = new FakeGitHub { ExistingSha = "abc123" };
        var service = Service(new FakeApi(), github, Checkout("feature"), template: "name: HerNess Cloud\n");

        await service.InstallWorkflowAsync();

        var put = Assert.Single(github.Requests, r => r.Method == "PUT");
        Assert.Equal("trunk", put.Body!["branch"]!.GetValue<string>());
        Assert.Equal("abc123", put.Body["sha"]!.GetValue<string>());
        Assert.Equal("name: HerNess Cloud\n", Encoding.UTF8.GetString(Convert.FromBase64String(put.Body["content"]!.GetValue<string>())));
        Assert.Equal("cloud.installed:octo/hello|trunk", service.Notice);
    }

    [Fact]
    public async Task RefreshAppendsOnlyNewTranscriptEvents()
    {
        using var github = new FakeGitHub();
        var api = new FakeApi();
        var service = Service(api, github, Checkout("main"));
        Assert.True(await service.StartAsync("Fix the build"));
        var id = service.Runs[0].Id;

        api.Events.AddRange([new CloudRunLogEntry(1, "status", "Runner started."), new CloudRunLogEntry(2, "assistant", "Done.")]);
        await service.RefreshRunAsync(id);
        await service.RefreshRunAsync(id);

        Assert.Equal(["Runner started.", "Done."], service.Events(id).Select(e => e.Text));
        Assert.Equal(2, api.Afters.Last());
    }

    private CloudRunService Service(FakeApi api, FakeGitHub github, string workspace, string? template = null)
    {
        var secrets = new MemoryProviderSecretStore();
        GitHubCredential.Store(secrets, "gh-token");
        return new CloudRunService(api, secrets, () => workspace, () => "", Text,
            gitHubApiBase: new Uri(github.Url + "/"), workflowTemplate: () => template);
    }

    private string Checkout(string branch)
    {
        var workspace = Path.Combine(_root, "repo-" + Guid.NewGuid().ToString("N"));
        var git = Path.Combine(workspace, ".git");
        Directory.CreateDirectory(git);
        File.WriteAllText(Path.Combine(git, "config"), "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:octo/hello.git\n");
        File.WriteAllText(Path.Combine(git, "HEAD"), $"ref: refs/heads/{branch}\n");
        return workspace;
    }

    private static JsonObject RunJson(string status, string id = "6f1c2a9e-4b7d-4e2a-9c1f-0a1b2c3d4e5f") => new()
    {
        ["id"] = id,
        ["repository"] = "octo/hello",
        ["base_ref"] = "main",
        ["prompt"] = "Fix the build",
        ["model"] = null,
        ["status"] = status,
        ["cancel_requested"] = false,
        ["github_run_id"] = "42",
        ["github_run_url"] = "https://github.com/octo/hello/actions/runs/42",
        ["result_branch"] = null,
        ["result_commit"] = null,
        ["summary"] = null,
        ["error"] = null,
        ["event_count"] = 0,
        ["created_at"] = "2026-10-27T17:13:19.444Z",
    };

    private sealed class FakeApi : ICloudRunApi
    {
        private CloudRun? _run;
        public CloudRun? Created { get; private set; }
        public string? Repository { get; private set; }
        public string? BaseRef { get; private set; }
        public string? CancelError { get; private set; }
        public List<CloudRunLogEntry> Events { get; } = [];
        public List<int> Afters { get; } = [];
        public bool IsSignedIn => true;
        public string ApiBase => "https://api.example";

        public Task<CloudRun> CreateAsync(GitHubRepository repository, string baseRef, string prompt, string? model, CancellationToken ct = default)
        {
            (Repository, BaseRef) = (repository.FullName, baseRef);
            Created = _run = Decode(RunJson("queued", Guid.NewGuid().ToString())) with { GitHubRunId = null };
            return Task.FromResult(_run);
        }

        public Task<IReadOnlyList<CloudRun>> ListAsync(CancellationToken ct = default) =>
            Task.FromResult<IReadOnlyList<CloudRun>>(_run is null ? [] : [_run]);

        public Task<(CloudRun Run, IReadOnlyList<CloudRunLogEntry> Events)> DetailAsync(string id, int after, CancellationToken ct = default)
        {
            Afters.Add(after);
            _run = _run! with { Status = CloudRunStatus.Succeeded };
            return Task.FromResult<(CloudRun, IReadOnlyList<CloudRunLogEntry>)>((_run, Events.Where(e => e.Seq > after).ToList()));
        }

        public Task<CloudRun> CancelAsync(string id, string? error = null, CancellationToken ct = default)
        {
            CancelError = error;
            _run = _run! with { Status = error is null ? CloudRunStatus.Cancelled : CloudRunStatus.Failed, Error = error };
            return Task.FromResult(_run);
        }

        private static CloudRun Decode(JsonObject json) =>
            JsonSerializer.Deserialize<CloudRun>(json.ToJsonString(), new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
    }

    private sealed record GitHubRequest(string Method, string Path, string? Authorization, JsonNode? Body);

    /// The four api.github.com routes cloud runs use.
    private sealed class FakeGitHub : IDisposable
    {
        private readonly NativeProviderGateway _gateway;

        public FakeGitHub() => _gateway = LocalTestGateway.Start(HandleAsync);

        public string Url => _gateway.Url.ToString().TrimEnd('/');
        public int DispatchStatus { get; init; } = 204;
        public string? ExistingSha { get; init; }
        public ConcurrentQueue<GitHubRequest> Requests { get; } = new();

        private Task<NativeGatewayResponse> HandleAsync(NativeGatewayRequest request)
        {
            var body = request.Body.Length == 0 ? null : JsonNode.Parse(Encoding.UTF8.GetString(request.Body));
            var authorization = request.Headers.FirstOrDefault(h => h.Key.Equals("Authorization", StringComparison.OrdinalIgnoreCase)).Value;
            Requests.Enqueue(new GitHubRequest(request.Method, request.Path, authorization, body));
            var path = request.Path.Split('?')[0];
            if (path.EndsWith("/dispatches", StringComparison.Ordinal)) return Reply(DispatchStatus, DispatchStatus == 204 ? null : new JsonObject { ["message"] = "Not Found" });
            if (path.Contains("/contents/", StringComparison.Ordinal))
            {
                if (request.Method == "PUT") return Reply(201, new JsonObject());
                return ExistingSha is null ? Reply(404, new JsonObject { ["message"] = "Not Found" }) : Reply(200, new JsonObject { ["sha"] = ExistingSha });
            }
            if (path.EndsWith("/repos/octo/hello", StringComparison.Ordinal)) return Reply(200, new JsonObject { ["default_branch"] = "trunk" });
            return Reply(404, new JsonObject { ["message"] = "Not Found" });
        }

        private static Task<NativeGatewayResponse> Reply(int status, JsonObject? body) =>
            Task.FromResult(new NativeGatewayResponse(status, body is null ? [] : Encoding.UTF8.GetBytes(body.ToJsonString())));

        public void Dispose() => _gateway.Dispose();
    }
}
