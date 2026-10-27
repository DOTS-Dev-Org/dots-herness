// Copyright (c) 2026 DOTS
// Keeps git metadata that can execute code read-only inside agent sandboxes.

namespace DotsHarnessCore;

/// <summary>
/// Git metadata a sandboxed agent must not be able to rewrite: <c>hooks/</c>
/// would run on the user's next git command, and <c>config</c> can point git
/// at another pager, hook path or ssh command — both are ways out of the
/// sandbox that need no code to run in here.
///
/// A writable root is a git metadata directory when it holds a <c>HEAD</c>
/// file. A linked worktree's own <c>.git</c> is a *file* pointing at the real
/// directory, so only the origin's <c>.git</c> and its
/// <c>worktrees/&lt;name&gt;</c> entries are picked up — never the agent's own
/// workspace.
/// </summary>
public static class GitMetadataGuards
{
    private static readonly string[] ProtectedFileNames = ["config", "config.worktree"];

    public static bool IsGitMetadataDirectory(string root)
    {
        try
        {
            var head = Path.Combine(root, "HEAD");
            return File.Exists(head) && !Directory.Exists(head);
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Paths inside the given writable roots that stay read-only.</summary>
    public static IReadOnlyList<string> ProtectedPaths(IEnumerable<string> writableRoots)
    {
        var result = new List<string>();
        foreach (var root in writableRoots)
        {
            string full;
            try { full = Path.GetFullPath(root); }
            catch { continue; }
            if (!IsGitMetadataDirectory(full)) continue;
            var hooks = Path.Combine(full, "hooks");
            if (Directory.Exists(hooks)) result.Add(hooks);
            foreach (var name in ProtectedFileNames)
            {
                var file = Path.Combine(full, name);
                if (File.Exists(file)) result.Add(file);
            }
        }
        return result;
    }
}
