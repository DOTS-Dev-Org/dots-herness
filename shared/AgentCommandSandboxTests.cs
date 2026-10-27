using System.Diagnostics;
using DotsHarnessCore;
using Xunit;

// Escape checks for the bubblewrap command boundary. They run only where the sandbox exists
// (Linux with bwrap installed); elsewhere each case returns early and proves nothing.
// Port of the macOS SandboxProfileTests/SandboxGitEscapeTests intent: writes stay in the
// workspace, the host home is hidden, and the network namespace has no interfaces but loopback.
public sealed class AgentCommandSandboxTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"AgentCommandSandboxTests-{Guid.NewGuid():N}");
    private readonly string _workspace;
    private readonly string _outside;

    public AgentCommandSandboxTests()
    {
        _workspace = Path.Combine(_root, "workspace");
        _outside = Path.Combine(_root, "outside");
        Directory.CreateDirectory(_workspace);
        Directory.CreateDirectory(_outside);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    [Fact]
    public void UnavailableSandboxFailsClosedWithAStableCode()
    {
        if (AgentCommandSandbox.IsAvailable) return;
        var info = new ProcessStartInfo("/bin/sh") { RedirectStandardOutput = true, RedirectStandardError = true };
        info.ArgumentList.Add("-c");
        info.ArgumentList.Add("echo should-not-run");

        Assert.False(AgentCommandSandbox.TryConfigure(info, _workspace, out var error));
        Assert.StartsWith(AgentCommandSandbox.UnavailableCode, error, StringComparison.Ordinal);
    }

    [Fact]
    public void CommandsWriteInsideTheWorkspaceOnly()
    {
        if (!AgentCommandSandbox.IsAvailable) return;

        var inside = Run($"echo ok > \"{Path.Combine(_workspace, "inside.txt")}\"");
        var outside = Run($"echo no > \"{Path.Combine(_outside, "outside.txt")}\"");

        Assert.Equal(0, inside.ExitCode);
        Assert.True(File.Exists(Path.Combine(_workspace, "inside.txt")));
        Assert.NotEqual(0, outside.ExitCode);
        Assert.False(File.Exists(Path.Combine(_outside, "outside.txt")));
    }

    [Fact]
    public void HostHomeIsHiddenFromCommands()
    {
        if (!AgentCommandSandbox.IsAvailable) return;
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var sensitive = Path.Combine(home, ".ssh");
        if (!Directory.Exists(sensitive)) return;

        var result = Run($"ls \"{sensitive}\" > /dev/null 2>&1");

        Assert.NotEqual(0, result.ExitCode);
    }

    [Fact]
    public void NetworkNamespaceHasOnlyLoopbackByDefault()
    {
        if (!AgentCommandSandbox.IsAvailable) return;

        // Exit 0 only when no interface other than lo exists inside the namespace.
        var result = Run("[ -z \"$(ls /sys/class/net | grep -v '^lo$')\" ]");

        Assert.Equal(0, result.ExitCode);
    }

    private sealed record CommandResult(int ExitCode, string Output);

    private CommandResult Run(string shellCommand)
    {
        var info = new ProcessStartInfo("/bin/sh")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            WorkingDirectory = _workspace,
        };
        info.ArgumentList.Add("-c");
        info.ArgumentList.Add(shellCommand);
        Assert.True(AgentCommandSandbox.TryConfigure(info, _workspace, out var error), error);

        using var process = Process.Start(info)!;
        var output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
        Assert.True(process.WaitForExit(TimeSpan.FromSeconds(15)), "sandboxed command timed out");
        return new CommandResult(process.ExitCode, output);
    }
}
