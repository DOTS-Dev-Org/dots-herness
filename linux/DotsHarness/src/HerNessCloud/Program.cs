// Copyright (c) 2026 DOTS
// HerNess cloud runner: the headless agent behind the herness-cloud.yml workflow.
//
//   HerNessCloud run        execute HERNESS_PROMPT in GITHUB_WORKSPACE and stream the transcript
//   HerNessCloud complete   report the final status after the workflow pushed the changes

using DotsHarnessCore;

var command = args.FirstOrDefault();
if (command is not ("run" or "complete"))
{
    Console.Error.WriteLine("usage: HerNessCloud run|complete");
    return 2;
}

CloudRunnerOptions options;
try
{
    options = CloudRunnerOptions.FromEnvironment(Environment.GetEnvironmentVariable);
}
catch (ArgumentException ex)
{
    Console.Error.WriteLine(ex.Message);
    return 2;
}

using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
var oidc = GitHubOidcTokenSource.FromEnvironment(http, Environment.GetEnvironmentVariable, options.OidcAudience);
if (oidc is null)
{
    Console.Error.WriteLine("No GitHub OIDC token is available: the workflow needs `permissions: id-token: write`.");
    return 2;
}
var reporter = new CloudRunReporter(http, options.ApiUrl, options.RunId, oidc.TokenAsync);

using var cancellation = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cancellation.Cancel(); };
AppDomain.CurrentDomain.ProcessExit += (_, _) => cancellation.Cancel();

if (command == "complete")
{
    return await CloudRunner.CompleteAsync(options, reporter, Environment.GetEnvironmentVariable, cancellation.Token);
}

CloudRunner.ScrubEnvironment();
return await new CloudRunner(options, reporter, Console.WriteLine).RunAsync(cancellation.Token);
