// Copyright (c) 2026 DOTS
// Agent-facing report of the sandbox boundary the run is inside. Mirrors the
// macOS sandbox_status tool (AgentBridge+Tools.swift) so the model can tell
// where it writes and whether it has network.

using System.Text.Json.Nodes;

namespace DotsHarnessCore;

/// <summary>What the agent may touch in this run. A null boundary means no sandbox.</summary>
public sealed record SandboxBoundary(
    string WorkspacePath,
    string Branch,
    bool NetworkAccess,
    IReadOnlyList<string> WritableRoots);

public static class SandboxStatusTool
{
    public const string Name = "sandbox_status";

    public static NativeToolDefinition Definition { get; } = new(
        Name,
        "Report whether the current workspace is running inside a HerNess sandbox and its process boundaries.",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject(),
        });

    /// <summary>The tool answer. The text names the branch so the model can cite it.</summary>
    public static string Describe(SandboxBoundary? boundary)
    {
        if (boundary is null)
            return "Sandbox inactive. The current workspace is the user's checkout.";
        var branch = string.IsNullOrWhiteSpace(boundary.Branch) ? "unknown" : boundary.Branch;
        var network = boundary.NetworkAccess ? "enabled for new processes" : "disabled for new processes";
        return string.Join('\n', new[]
        {
            "Sandbox active",
            $"workspace: {boundary.WorkspacePath}",
            $"branch: {branch}",
            "writes: workspace and temporary directories only",
            $"network: {network}",
            "origin writes: unavailable to agent processes",
        });
    }

    /// <summary>The prompt block. Empty when no sandbox is active.</summary>
    public static string PromptSection(SandboxBoundary? boundary)
    {
        if (boundary is null) return "";
        var branch = string.IsNullOrWhiteSpace(boundary.Branch) ? "unknown" : boundary.Branch;
        var network = boundary.NetworkAccess ? "enabled" : "disabled";
        return $"""

            Sandbox execution
            - This run is inside the HerNess sandbox worktree {boundary.WorkspacePath}.
            - Sandbox branch: {branch}.
            - Agent writes are limited to this worktree and temporary directories; the origin checkout is unavailable.
            - Network access for new processes is {network}.
            - Pushing and deploying (git push, scp, rsync, wrangler, publish) are unavailable here; the user does them after merging.
            - Do not attempt to merge, discard, or write to the origin; only the user can approve those actions in Settings.
            """;
    }
}
