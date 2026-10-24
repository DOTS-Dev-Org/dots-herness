// Copyright (c) 2026 DOTS
// Strict model-command process boundary for Windows/Linux.

using System.Diagnostics;

namespace DotsHarnessCore;

public static class AgentCommandSandbox
{
    public const string UnavailableCode = "agent_command_sandbox_unavailable";

    public static bool IsAvailable => OperatingSystem.IsLinux() && FindBubblewrap() is not null;

    public static string? AvailabilityError => OperatingSystem.IsLinux()
        ? (FindBubblewrap() is null ? "Strict agent command sandbox requires bubblewrap (bwrap)." : null)
        : OperatingSystem.IsWindows()
            ? "Windows process isolation is unavailable. Agent shell commands remain fail-closed and interactive terminals are disabled while a sandbox worktree is active."
            : "Strict agent command sandbox is not available on this platform.";

    public static bool TryConfigure(
        ProcessStartInfo info,
        string workspace,
        out string error,
        IReadOnlyList<string>? additionalWritableRoots = null,
        bool networkAccess = false,
        bool newSession = true)
    {
        error = "";
        if (!OperatingSystem.IsLinux())
        {
            error = $"{UnavailableCode}: {AvailabilityError ?? "Strict agent command sandbox is unavailable."}";
            return false;
        }

        var bwrap = FindBubblewrap();
        if (bwrap is null)
        {
            error = $"{UnavailableCode}: {AvailabilityError ?? "Strict agent command sandbox is unavailable."}";
            return false;
        }

        var root = Path.GetFullPath(workspace);
        info.FileName = bwrap;
        info.ArgumentList.Clear();
        info.ArgumentList.Add("--die-with-parent");
        if (newSession) info.ArgumentList.Add("--new-session");
        if (!networkAccess) info.ArgumentList.Add("--unshare-net");
        info.ArgumentList.Add("--unshare-ipc");
        info.ArgumentList.Add("--unshare-uts");
        info.ArgumentList.Add("--unshare-pid");
        info.ArgumentList.Add("--cap-drop");
        info.ArgumentList.Add("ALL");
        info.ArgumentList.Add("--ro-bind");
        info.ArgumentList.Add("/");
        info.ArgumentList.Add("/");

        // The read-only root mount would otherwise expose the real home
        // directory, including Chrome/Chromium profiles and Native Messaging
        // sockets. Hide the host home first, then re-bind only the selected
        // workspace below. This remains safe when the workspace itself lives
        // under the user's home directory.
        var hiddenMounts = new HashSet<string>(StringComparer.Ordinal);
        void AddTmpfs(string path)
        {
            if (!hiddenMounts.Add(path)) return;
            info.ArgumentList.Add("--tmpfs");
            info.ArgumentList.Add(path);
        }

        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (!string.IsNullOrWhiteSpace(home))
        {
            home = Path.GetFullPath(home);
            if (!string.Equals(home, Path.DirectorySeparatorChar.ToString(), StringComparison.Ordinal)) AddTmpfs(home);
        }
        AddTmpfs("/tmp");
        AddTmpfs("/run");
        AddTmpfs("/root");
        foreach (var directory in new[]
        {
            "/tmp/agent-home",
            "/tmp/agent-home/config",
            "/tmp/agent-home/cache",
            "/tmp/agent-home/data",
            "/tmp/agent-home/state",
        })
        {
            info.ArgumentList.Add("--dir");
            info.ArgumentList.Add(directory);
        }
        var createdHomeDirectories = new HashSet<string>(StringComparer.Ordinal);
        void AddHiddenHomePath(string target)
        {
            if (string.IsNullOrWhiteSpace(home) || string.Equals(home, Path.DirectorySeparatorChar.ToString(), StringComparison.Ordinal)) return;
            var fullTarget = Path.GetFullPath(target);
            var homePrefix = home.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (!fullTarget.StartsWith(homePrefix, StringComparison.Ordinal)) return;
            var relative = Path.GetRelativePath(home, fullTarget);
            var current = home;
            foreach (var segment in relative.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
            {
                current = Path.Combine(current, segment);
                if (!createdHomeDirectories.Add(current)) continue;
                info.ArgumentList.Add("--dir");
                info.ArgumentList.Add(current);
            }
        }

        AddHiddenHomePath(root);
        info.ArgumentList.Add("--bind");
        info.ArgumentList.Add(root);
        info.ArgumentList.Add(root);
        if (Directory.Exists(Path.Combine(root, ".mem")))
        {
            info.ArgumentList.Add("--tmpfs");
            info.ArgumentList.Add(Path.Combine(root, ".mem"));
        }
        foreach (var writableRoot in (additionalWritableRoots ?? Array.Empty<string>()).Select(Path.GetFullPath).Distinct(StringComparer.Ordinal))
        {
            if (!Directory.Exists(writableRoot)
                || writableRoot == Path.DirectorySeparatorChar.ToString()
                || string.Equals(writableRoot, root, StringComparison.Ordinal)
                || writableRoot.StartsWith(root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.Ordinal))
                continue;
            AddHiddenHomePath(writableRoot);
            info.ArgumentList.Add("--bind");
            info.ArgumentList.Add(writableRoot);
            info.ArgumentList.Add(writableRoot);
        }
        // Git metadata stays read-only even though its directory is writable:
        // bubblewrap applies the mounts in order, so these shadow the
        // writable bind above. A rewritten hook or config would run on the
        // user's next git command, outside this sandbox.
        foreach (var protectedPath in GitMetadataGuards.ProtectedPaths(additionalWritableRoots ?? Array.Empty<string>()))
        {
            info.ArgumentList.Add("--ro-bind");
            info.ArgumentList.Add(protectedPath);
            info.ArgumentList.Add(protectedPath);
        }
        info.ArgumentList.Add("--proc");
        info.ArgumentList.Add("/proc");
        info.ArgumentList.Add("--dev");
        info.ArgumentList.Add("/dev");
        info.ArgumentList.Add("--clearenv");
        info.ArgumentList.Add("--setenv");
        info.ArgumentList.Add("PATH");
        info.ArgumentList.Add("/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
        info.ArgumentList.Add("--setenv");
        info.ArgumentList.Add("HOME");
        info.ArgumentList.Add("/tmp/agent-home");
        info.ArgumentList.Add("--setenv");
        info.ArgumentList.Add("XDG_CONFIG_HOME");
        info.ArgumentList.Add("/tmp/agent-home/config");
        info.ArgumentList.Add("--setenv");
        info.ArgumentList.Add("XDG_CACHE_HOME");
        info.ArgumentList.Add("/tmp/agent-home/cache");
        info.ArgumentList.Add("--setenv");
        info.ArgumentList.Add("XDG_DATA_HOME");
        info.ArgumentList.Add("/tmp/agent-home/data");
        info.ArgumentList.Add("--setenv");
        info.ArgumentList.Add("XDG_STATE_HOME");
        info.ArgumentList.Add("/tmp/agent-home/state");
        info.ArgumentList.Add("--setenv");
        info.ArgumentList.Add("TERM");
        info.ArgumentList.Add("xterm-256color");
        info.ArgumentList.Add("--setenv");
        info.ArgumentList.Add("COLORTERM");
        info.ArgumentList.Add("truecolor");
        info.ArgumentList.Add("--chdir");
        info.ArgumentList.Add(root);
        info.ArgumentList.Add("/bin/sh");
        info.ArgumentList.Add("-lc");

        foreach (var key in new[]
        {
            "DISPLAY",
            "WAYLAND_DISPLAY",
            "DBUS_SESSION_BUS_ADDRESS",
            "XDG_RUNTIME_DIR",
            "XDG_DATA_HOME",
            "XDG_STATE_HOME",
            "BROWSER",
            "CHROME_CONFIG_HOME",
            "CHROME_USER_DATA_DIR",
        })
            info.Environment.Remove(key);

        info.Environment["HOME"] = "/tmp/agent-home";
        info.Environment["XDG_CONFIG_HOME"] = "/tmp/agent-home/config";
        info.Environment["XDG_CACHE_HOME"] = "/tmp/agent-home/cache";
        info.Environment["XDG_DATA_HOME"] = "/tmp/agent-home/data";
        info.Environment["XDG_STATE_HOME"] = "/tmp/agent-home/state";
        return true;
    }

    private static string? FindBubblewrap()
    {
        foreach (var path in new[] { "/usr/bin/bwrap", "/bin/bwrap", "/usr/local/bin/bwrap" })
        {
            if (File.Exists(path) && new FileInfo(path).Length > 0) return path;
        }
        return null;
    }
}
