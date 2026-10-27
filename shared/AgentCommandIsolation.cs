// Copyright (c) 2026 DOTS
// Platform-neutral seam for agent command isolation. Linux isolates with bubblewrap in
// AgentCommandSandbox; Windows registers an AppContainer runner at startup. With no runner
// registered, StrictNoDesktop run_command stays fail-closed.

namespace DotsHarnessCore;

/// <summary>A null <paramref name="Error"/> means the command ran; otherwise nothing ran and Error says why.</summary>
public sealed record IsolatedCommandResult(int? ExitCode, string Stdout, string Stderr, bool TimedOut, string? Error = null);

public interface IAgentCommandIsolation
{
    /// Null when this workspace can be isolated; otherwise the reason it cannot.
    string? Unavailable(string workspace, IReadOnlyList<string> writableRoots, bool networkAccess);

    Task<IsolatedCommandResult> RunAsync(
        string command,
        string workspace,
        IReadOnlyList<string> writableRoots,
        Action<string>? onOutput,
        TimeSpan timeout,
        CancellationToken ct);

    /// <summary>
    /// Gives back every permission this runner granted. Callers must invoke
    /// it when the sandbox ends — otherwise the isolation SID keeps its
    /// access to the user's files for the rest of the session.
    /// </summary>
    void Release() { }
}

public static class AgentCommandIsolation
{
    public static IAgentCommandIsolation? Current { get; set; }
}
