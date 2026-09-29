using DotsHarnessCore;
using Xunit;

public sealed class SSHConfigStoreTests
{
    [Fact]
    public void ParsesStanzasWithMixedSyntax()
    {
        var config = "# a comment\nHost build-box\n    HostName 10.0.0.4\n    User birkan\n    Port 2222\n\n"
            + "Host\tquoted\n\tHostName=\"example.internal\"\n\tUser=ops\n\nHost bare\n";
        var hosts = SSHConfigStore.Parse(config, followIncludes: false);
        Assert.Equal(new[] { "build-box", "quoted", "bare" }, hosts.Select(h => h.Alias));
        Assert.Equal("10.0.0.4", hosts[0].HostName);
        Assert.Equal("birkan", hosts[0].User);
        Assert.Equal(2222, hosts[0].Port);
        Assert.Equal("example.internal", hosts[1].HostName);
        Assert.Equal("ops", hosts[1].User);
        // No HostName: ssh falls back to the alias, and so do we.
        Assert.Equal("bare", hosts[2].HostName);
        Assert.Equal(22, hosts[2].Port);
    }

    [Fact]
    public void SkipsPatternsMatchBlocksAndBadPorts()
    {
        var config = "Host *\n    User everyone\n\nHost web? !bastion\n    HostName pattern.example\n\n"
            + "Match host anything\n    HostName matched.example\n\nHost real\n    HostName real.example\n    Port not-a-number\n";
        var hosts = SSHConfigStore.Parse(config, followIncludes: false);
        Assert.Equal(new[] { "real" }, hosts.Select(h => h.Alias));
        Assert.Equal(22, hosts[0].Port);
    }

    [Fact]
    public void FollowsIncludeOnce()
    {
        var config = "Include extra\n\nHost main\n    HostName main.example\n";
        var hosts = SSHConfigStore.Parse(config, path =>
            path.EndsWith("extra", StringComparison.Ordinal) ? "Host included\n    HostName inc.example\n" : null);
        Assert.Equal(new HashSet<string> { "included", "main" }, hosts.Select(h => h.Alias).ToHashSet());
    }

    [Fact]
    public void UpsertPreservesHandWrittenContentAndRefusesCollisions()
    {
        var original = "# user's own file\nHost laptop\n    HostName laptop.local\n\n";
        var host = new SSHHost("box", "10.0.0.9", "ops", 22, "~/.ssh/dots_harness_ed25519", true);
        var written = SSHConfigStore.Upsert(host, original);
        Assert.StartsWith(original.Trim('\n'), written);
        Assert.Contains("Host box", written);
        Assert.Contains("IdentityFile ~/.ssh/dots_harness_ed25519", written);

        var again = SSHConfigStore.Upsert(host, written);
        Assert.Equal(1, again.Split("Host box").Length - 1);

        Assert.Throws<SSHException>(() =>
            SSHConfigStore.Upsert(new SSHHost("laptop", "elsewhere", "ops"), written));

        var removed = SSHConfigStore.Remove("box", again);
        Assert.DoesNotContain("Host box", removed);
        Assert.Contains("Host laptop", removed);
    }

    [Fact]
    public void RenderedStanzaNeverCarriesASecret()
    {
        var rendered = SSHConfigStore.Render(new SSHHost("box", "h", "u", 22, null, true));
        foreach (var word in new[] { "password", "Password", "secret" })
            Assert.DoesNotContain(word, rendered);
    }

    [Fact]
    public void AliasValidation()
    {
        Assert.True(SSHConfigStore.IsValidAlias("build-box.2"));
        Assert.False(SSHConfigStore.IsValidAlias(""));
        Assert.False(SSHConfigStore.IsValidAlias("-rf"));
        Assert.False(SSHConfigStore.IsValidAlias("a b"));
        Assert.False(SSHConfigStore.IsValidAlias("box\nHost other"));
    }

    [Fact]
    public void ConfigFileRoundTripsAndKeepsBackup()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"ssh-config-{Guid.NewGuid():N}");
        try
        {
            var path = Path.Combine(directory, "config");
            Directory.CreateDirectory(directory);
            File.WriteAllText(path, "Host mine\n    HostName m.example\n");
            var file = new SSHConfigFile(path);
            file.Add(new SSHHost("box", "b.example", "ops", 22, null, true));
            Assert.Equal(new[] { "mine", "box" }, file.Hosts().Select(h => h.Alias));
            Assert.True(File.Exists(path + ".dots-backup"));
            file.Remove("box");
            Assert.Equal(new[] { "mine" }, file.Hosts().Select(h => h.Alias));
        }
        finally { Directory.Delete(directory, true); }
    }
}

public sealed class SSHRunnerArgumentTests
{
    [Fact]
    public void ShellQuotingContainsEveryMetacharacter()
    {
        var quoted = SSHRunner.ShellQuote("/srv/a b/$(rm -rf ~)/'quoted'/;\nnewline");
        Assert.StartsWith("'", quoted);
        Assert.EndsWith("'", quoted);
        Assert.Equal(0, quoted.Count(c => c == '\'') % 2);
        Assert.DoesNotContain("'$(", quoted);
    }

    [Fact]
    public void RemoteCommandRunsInTheChosenFolderWithPosixShell() =>
        Assert.Equal("cd -- '/srv/app' && exec /bin/sh -lc 'ls -1'", SSHRunner.RemoteCommand("/srv/app", "ls -1"));

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void LaunchPrefixNeverRelaxesHostKeyChecking(bool interactive)
    {
        var arguments = SSHRunner.LaunchPrefix("box", interactive);
        Assert.Contains("StrictHostKeyChecking=yes", arguments);
        Assert.DoesNotContain(arguments, a => a.Contains("StrictHostKeyChecking=no"));
        Assert.DoesNotContain(arguments, a => a.Contains("accept-new"));
        Assert.Equal(new[] { "box", "--" }, arguments.TakeLast(2));
        Assert.Equal(!interactive, arguments.Contains("BatchMode=yes"));
    }

    [Fact]
    public void TransportFailureIsToldApartFromACommandFailure()
    {
        Assert.True(SSHRunner.IsTransportFailure("Connection to box closed by remote host."));
        Assert.False(SSHRunner.IsTransportFailure("make: *** [test] Error 1"));
    }

    [Fact]
    public void StderrClassification()
    {
        Assert.Equal(SSHErrorKind.HostKeyChanged,
            SSHRunner.Classify("@@@ REMOTE HOST IDENTIFICATION HAS CHANGED! @@@", "box").Kind);
        Assert.Equal(SSHErrorKind.AuthFailed, SSHRunner.Classify("Permission denied (publickey).", "box").Kind);
        Assert.Equal(SSHErrorKind.NotReachable, SSHRunner.Classify("ssh: Could not resolve hostname box", "box").Kind);
    }
}

public sealed class RemoteWorkLocationTests
{
    [Fact]
    public void RemoteIdentityDoesNotCollideWithALocalPath()
    {
        var target = new SSHTarget("box", "/srv/app");
        Assert.Equal("ssh://box/srv/app", target.Identity);
        Assert.NotEqual("/srv/app", target.Identity);
    }

    [Fact]
    public void WorkLocationSettingRoundTrips()
    {
        foreach (var setting in new[] { WorkLocationSetting.Local, WorkLocationSetting.LocalWorktree, WorkLocationSetting.Remote("box") })
            Assert.Equal(setting, WorkLocationSetting.Parse(setting.StorageValue));
        Assert.Equal(WorkLocationSetting.Local, WorkLocationSetting.Parse("remote:"));
        Assert.Equal(WorkLocationSetting.Local, WorkLocationSetting.Parse("nonsense"));
    }
}

public sealed class RemoteWorkspaceToolsTests
{
    private static readonly SSHTarget Target = new("box", "/srv/app");

    [Fact]
    public async Task FileToolsAreRefusedAndNeverTouchTheLocalDisk()
    {
        var marker = Path.Combine(Environment.CurrentDirectory, $"remote-guard-{Guid.NewGuid():N}.txt");
        var call = new NativeToolCall("1", "write_file", $$"""{"path":"{{marker.Replace("\\", "\\\\")}}","content":"x"}""");
        var result = await RemoteWorkspaceTools.ExecuteAsync(call, Target);
        Assert.False(File.Exists(marker));
        Assert.StartsWith("Tool error", result);
    }

    [Fact]
    public async Task MemDirectoryIsOffLimits()
    {
        var call = new NativeToolCall("1", "run_command", """{"command":"cat .mem/index.json"}""");
        Assert.Contains("unavailable", await RemoteWorkspaceTools.ExecuteAsync(call, Target));
    }

    [Fact]
    public async Task MissingCommandIsReported()
    {
        var call = new NativeToolCall("1", "run_command", "{}");
        Assert.StartsWith("Tool error", await RemoteWorkspaceTools.ExecuteAsync(call, Target));
    }

    [Fact]
    public void OnlyRunCommandIsOffered()
    {
        Assert.Equal(new[] { "run_command" }, RemoteWorkspaceTools.Definitions(planMode: false).Select(t => t.Name));
        Assert.Empty(RemoteWorkspaceTools.Definitions(planMode: true));
    }

    [Fact]
    public void InteractiveArgumentsChangeIntoTheFolderWithoutRelaxingChecks()
    {
        var arguments = SSHRunner.InteractiveArguments(Target);
        Assert.Contains("-tt", arguments);
        Assert.Contains("StrictHostKeyChecking=yes", arguments);
        Assert.Equal("cd -- '/srv/app' && exec ${SHELL:-/bin/sh} -l", arguments[^1]);
    }
}
