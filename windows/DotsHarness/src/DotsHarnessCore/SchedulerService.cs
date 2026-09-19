// Copyright (c) 2026 DOTS
// Installs/removes the background scheduler as a per-user OS job.
// Windows: Task Scheduler (schtasks, logon trigger). Linux: systemd --user unit.
// Mirrors the macOS SchedulerService.swift (launchd).

using System.Diagnostics;

namespace DotsHarnessCore;

public static class SchedulerService
{
    public const string JobName = "DotsHarnessScheduler";
    private const string LinuxUnit = "dots-harness-scheduler.service";

    public static string DefaultExecutablePath()
    {
        var current = Environment.ProcessPath
                      ?? Process.GetCurrentProcess().MainModule?.FileName
                      ?? "DotsHarness";
        var dir = Path.GetDirectoryName(current) ?? ".";
        var exe = OperatingSystem.IsWindows() ? "DotsHarnessScheduler.exe" : "DotsHarnessScheduler";
        return Path.Combine(dir, exe);
    }

    public static string LinuxUnitPath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".config", "systemd", "user", LinuxUnit);

    public static bool IsInstalled()
    {
        if (OperatingSystem.IsWindows())
        {
            return Run("schtasks", $"/Query /TN \"{JobName}\"") == 0;
        }
        if (OperatingSystem.IsLinux())
        {
            return File.Exists(LinuxUnitPath);
        }
        return false;
    }

    public static void Install(string? executablePath = null)
    {
        var exe = executablePath ?? DefaultExecutablePath();

        if (OperatingSystem.IsWindows())
        {
            // Logon trigger; the daemon runs its own 60s tick loop afterwards.
            Run("schtasks", $"/Create /F /SC ONLOGON /RL LIMITED /TN \"{JobName}\" /TR \"\\\"{exe}\\\"\"");
            Run("schtasks", $"/Run /TN \"{JobName}\"");
            return;
        }

        if (OperatingSystem.IsLinux())
        {
            var path = LinuxUnitPath;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, LinuxUnitContent(exe));
            Run("systemctl", "--user daemon-reload");
            Run("systemctl", $"--user enable --now {LinuxUnit}");
            return;
        }

        throw new PlatformNotSupportedException("Background scheduler is not supported on this OS.");
    }

    public static void Uninstall()
    {
        if (OperatingSystem.IsWindows())
        {
            Run("schtasks", $"/Delete /F /TN \"{JobName}\"");
            return;
        }
        if (OperatingSystem.IsLinux())
        {
            Run("systemctl", $"--user disable --now {LinuxUnit}");
            try { File.Delete(LinuxUnitPath); } catch { }
            Run("systemctl", "--user daemon-reload");
        }
    }

    public static string LinuxUnitContent(string exe) =>
        "[Unit]\n" +
        "Description=Dots Harness scheduled task runner\n" +
        "After=default.target\n\n" +
        "[Service]\n" +
        "Type=simple\n" +
        $"ExecStart={exe}\n" +
        "Restart=on-failure\n" +
        "RestartSec=10\n\n" +
        "[Install]\n" +
        "WantedBy=default.target\n";

    private static int Run(string file, string arguments)
    {
        try
        {
            var process = new Process
            {
                StartInfo = new ProcessStartInfo(file, arguments)
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                },
            };
            process.Start();
            process.WaitForExit(15_000);
            return process.HasExited ? process.ExitCode : -1;
        }
        catch
        {
            return -1;
        }
    }
}
