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
        : "Strict agent command sandbox is not available on this platform.";

    public static bool TryConfigure(ProcessStartInfo info, string workspace, out string error)
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
        info.ArgumentList.Add("--new-session");
        info.ArgumentList.Add("--unshare-net");
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
        info.ArgumentList.Add("--bind");
        info.ArgumentList.Add(root);
        info.ArgumentList.Add(root);
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
