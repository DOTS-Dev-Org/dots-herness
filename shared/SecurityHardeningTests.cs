// Copyright (c) 2026 DOTS
// Regression tests for the security hardening.

using System.Net;
using Xunit;

namespace DotsHarnessCore;

public sealed class SecurityHardeningTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "dots-security-" + Guid.NewGuid().ToString("N"));

    public SecurityHardeningTests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch { }
        GC.SuppressFinalize(this);
    }

    private string MakeGitDirectory()
    {
        var git = Path.Combine(_root, "git-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(git);
        File.WriteAllText(Path.Combine(git, "HEAD"), "ref: refs/heads/main\n");
        File.WriteAllText(Path.Combine(git, "config"), "[core]\n");
        Directory.CreateDirectory(Path.Combine(git, "hooks"));
        return git;
    }

    [Fact]
    public void Git_metadata_hooks_and_config_stay_read_only()
    {
        var git = MakeGitDirectory();
        var protectedPaths = GitMetadataGuards.ProtectedPaths(new[] { git });
        Assert.Contains(Path.Combine(git, "hooks"), protectedPaths);
        Assert.Contains(Path.Combine(git, "config"), protectedPaths);
    }

    [Fact]
    public void A_workspace_without_git_metadata_is_not_locked_down()
    {
        var workspace = Path.Combine(_root, "workspace-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(workspace);
        Assert.Empty(GitMetadataGuards.ProtectedPaths(new[] { workspace }));
    }

    [Fact]
    public void The_remote_gateway_stays_on_loopback_until_the_user_shares_it()
    {
        using var certificate = RemoteTls.LoadOrCreate(_root);
        using var gateway = new RemoteControlGateway(0, (_, _, _) => Task.CompletedTask, certificate);
        gateway.Start();
        Assert.Equal(IPAddress.Loopback, gateway.BoundAddress);

        gateway.SharesWithLan = true;
        Assert.Equal(IPAddress.Any, gateway.BoundAddress);
    }

    [Fact]
    public void A_broken_symlink_cannot_point_a_write_outside_the_workspace()
    {
        var workspace = Path.Combine(_root, "ws-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(workspace);
        var outside = Path.Combine(_root, "outside-" + Guid.NewGuid().ToString("N"));
        // The target does not exist yet, which is what makes the link broken.
        var link = Path.Combine(workspace, "escape");
        File.CreateSymbolicLink(link, outside);

        // A broken link has no target to follow, but a write through it would
        // still land on the raw target — so the path is refused.
        Assert.Throws<InvalidOperationException>(() => NativeWorkspaceTools.Resolve("escape", workspace));
    }
}
