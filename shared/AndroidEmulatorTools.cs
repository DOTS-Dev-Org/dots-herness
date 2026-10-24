// Copyright (c) 2026 DOTS
// Agent-facing Android emulator and device control via the Android SDK.

using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public sealed record AndroidDevice(string Id, string Name, string State, bool IsEmulator)
{
    public bool IsOnline => State.Equals("device", StringComparison.OrdinalIgnoreCase);
}

public sealed class AndroidEmulatorException(string message) : Exception(message);

public static class AndroidSDKLocator
{
    public static string? FindAdb() => FindTool("adb", "platform-tools");
    public static string? FindEmulator() => FindTool("emulator", "emulator");

    private static string? FindTool(string name, string sdkSubdirectory)
    {
        var executable = OperatingSystem.IsWindows() ? name + ".exe" : name;
        var roots = new List<string>();
        foreach (var variable in new[] { "ANDROID_HOME", "ANDROID_SDK_ROOT" })
            if (!string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(variable)))
                roots.Add(Environment.GetEnvironmentVariable(variable)!);

        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (OperatingSystem.IsWindows())
        {
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (!string.IsNullOrWhiteSpace(local)) roots.Add(Path.Combine(local, "Android", "Sdk"));
            if (!string.IsNullOrWhiteSpace(home)) roots.Add(Path.Combine(home, "AppData", "Local", "Android", "Sdk"));
            roots.AddRange([@"C:\Android\Sdk", @"C:\Android\sdk"]);
        }
        else
        {
            if (!string.IsNullOrWhiteSpace(home)) roots.Add(Path.Combine(home, "Android", "Sdk"));
            roots.AddRange(["/usr/lib/android-sdk", "/usr/local/lib/android-sdk", "/usr/local/share/android-sdk", "/opt/android-sdk"]);
        }

        foreach (var root in roots.Distinct(StringComparer.Ordinal))
        {
            var candidate = Path.Combine(root, sdkSubdirectory, executable);
            if (IsExecutable(candidate)) return Path.GetFullPath(candidate);
        }

        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "")
                     .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(directory, executable);
            if (IsExecutable(candidate)) return Path.GetFullPath(candidate);
        }
        return null;
    }

    private static bool IsExecutable(string path)
    {
        if (!File.Exists(path)) return false;
        if (OperatingSystem.IsWindows()) return true;
        try
        {
            var mode = File.GetUnixFileMode(path);
            return (mode & (UnixFileMode.UserExecute | UnixFileMode.GroupExecute | UnixFileMode.OtherExecute)) != 0;
        }
        catch { return false; }
    }
}

public static class AndroidEmulatorService
{
    public static async Task<IReadOnlyList<AndroidDevice>> DevicesAsync(CancellationToken ct = default)
    {
        var text = Encoding.UTF8.GetString(await AndroidShell.AdbAsync(["devices", "-l"], TimeSpan.FromSeconds(15), ct));
        var result = new List<AndroidDevice>();
        foreach (var line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith("List of devices", StringComparison.OrdinalIgnoreCase)) continue;
            var fields = trimmed.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length < 2) continue;
            var model = fields.Skip(2).FirstOrDefault(field => field.StartsWith("model:", StringComparison.Ordinal))?[6..] ?? fields[0];
            result.Add(new AndroidDevice(fields[0], model, fields[1], fields[0].StartsWith("emulator-", StringComparison.Ordinal)));
        }
        return result;
    }

    public static async Task<IReadOnlyList<string>> AvdsAsync(CancellationToken ct = default)
    {
        var text = Encoding.UTF8.GetString(await AndroidShell.EmulatorAsync(["-list-avds"], TimeSpan.FromSeconds(15), ct));
        return text.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(line => line.Trim()).Where(line => line.Length > 0).ToArray();
    }

    /// <summary>Starts an AVD; <paramref name="headless"/> skips the emulator window for panels that mirror it over gRPC.</summary>
    public static void Boot(string avdName, bool headless = false)
    {
        if (string.IsNullOrWhiteSpace(avdName) || avdName.StartsWith('-'))
            throw new AndroidEmulatorException("Enter a valid AVD name.");
        var executable = AndroidSDKLocator.FindEmulator()
            ?? throw new AndroidEmulatorException("Android emulator tool not found. Install Android SDK Emulator or set ANDROID_HOME.");
        AndroidShell.StartBackground(executable, headless
            ? ["-avd", avdName, "-no-snapshot-load", "-no-boot-anim", "-no-window"]
            : ["-avd", avdName, "-no-snapshot-load", "-no-boot-anim"]);
    }

    public static Task ShutdownAsync(string serial, CancellationToken ct = default) =>
        AndroidShell.AdbAsync(["-s", serial, "emu", "kill"], TimeSpan.FromSeconds(10), ct);

    public static Task<byte[]> ScreenshotAsync(string serial, CancellationToken ct = default) =>
        AndroidShell.AdbAsync(["-s", serial, "exec-out", "screencap", "-p"], TimeSpan.FromSeconds(20), ct);

    public static Task InstallAsync(string serial, string apkPath, CancellationToken ct = default) =>
        AndroidShell.AdbAsync(["-s", serial, "install", "-r", apkPath], TimeSpan.FromSeconds(120), ct);

    public static async Task<string> LaunchAsync(string serial, string component, CancellationToken ct = default) =>
        Encoding.UTF8.GetString(await AndroidShell.AdbAsync(["-s", serial, "shell", "am", "start", "-n", component], TimeSpan.FromSeconds(20), ct)).Trim();

    public static Task TerminateAsync(string serial, string package, CancellationToken ct = default) =>
        AndroidShell.AdbAsync(["-s", serial, "shell", "am", "force-stop", package], TimeSpan.FromSeconds(15), ct);

    public static Task OpenUrlAsync(string serial, string url, CancellationToken ct = default) =>
        AndroidShell.AdbAsync(["-s", serial, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", url], TimeSpan.FromSeconds(20), ct);

    public static Task TapAsync(string serial, int x, int y, CancellationToken ct = default) =>
        AndroidShell.AdbAsync(["-s", serial, "shell", "input", "tap", x.ToString(), y.ToString()], TimeSpan.FromSeconds(10), ct);

    public static Task TextInputAsync(string serial, string text, CancellationToken ct = default) =>
        AndroidShell.AdbAsync(["-s", serial, "shell", "input", "text", text.Replace(" ", "%s", StringComparison.Ordinal)], TimeSpan.FromSeconds(15), ct);

    public static Task SwipeAsync(string serial, int x1, int y1, int x2, int y2, CancellationToken ct = default) =>
        AndroidShell.AdbAsync(["-s", serial, "shell", "input", "swipe", x1.ToString(), y1.ToString(), x2.ToString(), y2.ToString(), "300"], TimeSpan.FromSeconds(10), ct);

    public static async Task<string> LogcatAsync(string serial, CancellationToken ct = default) =>
        Encoding.UTF8.GetString(await AndroidShell.AdbAsync(["-s", serial, "logcat", "-d", "-t", "100", "*:E"], TimeSpan.FromSeconds(15), ct)).Trim();
}

internal static class AndroidShell
{
    public static Task<byte[]> AdbAsync(IReadOnlyList<string> arguments, TimeSpan timeout, CancellationToken ct) =>
        RunAsync(AndroidSDKLocator.FindAdb()
            ?? throw new AndroidEmulatorException("Android adb tool not found. Install Android SDK Platform Tools or set ANDROID_HOME."), arguments, timeout, ct);

    public static Task<byte[]> EmulatorAsync(IReadOnlyList<string> arguments, TimeSpan timeout, CancellationToken ct) =>
        RunAsync(AndroidSDKLocator.FindEmulator()
            ?? throw new AndroidEmulatorException("Android emulator tool not found. Install Android SDK Emulator or set ANDROID_HOME."), arguments, timeout, ct);

    public static void StartBackground(string executable, IReadOnlyList<string> arguments)
    {
        var start = StartInfo(executable, arguments);
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        var process = Process.Start(start) ?? throw new AndroidEmulatorException("The Android emulator could not start.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        _ = Task.Run(async () =>
        {
            try { await process.WaitForExitAsync().ConfigureAwait(false); }
            catch { }
            finally { process.Dispose(); }
        });
    }

    private static async Task<byte[]> RunAsync(string executable, IReadOnlyList<string> arguments, TimeSpan timeout, CancellationToken ct)
    {
        using var process = new Process { StartInfo = StartInfo(executable, arguments) };
        process.StartInfo.RedirectStandardOutput = true;
        process.StartInfo.RedirectStandardError = true;
        try
        {
            if (!process.Start()) throw new AndroidEmulatorException($"Failed to execute {Path.GetFileName(executable)}.");
        }
        catch (AndroidEmulatorException) { throw; }
        catch (Exception error) { throw new AndroidEmulatorException($"Failed to execute {Path.GetFileName(executable)}: {error.Message}"); }

        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cancellation.CancelAfter(timeout);
        using var output = new MemoryStream();
        var copy = process.StandardOutput.BaseStream.CopyToAsync(output, cancellation.Token);
        var errors = process.StandardError.ReadToEndAsync(cancellation.Token);
        try
        {
            await process.WaitForExitAsync(cancellation.Token).ConfigureAwait(false);
            await Task.WhenAll(copy, errors).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
            try { await Task.WhenAll(copy, errors).ConfigureAwait(false); } catch { }
            ct.ThrowIfCancellationRequested();
            throw new AndroidEmulatorException($"{Path.GetFileName(executable)} timed out after {timeout.TotalSeconds:0}s.");
        }

        if (process.ExitCode != 0)
        {
            var detail = (await errors.ConfigureAwait(false)).Trim();
            if (detail.Length > 4_000) detail = detail[..4_000];
            throw new AndroidEmulatorException(detail.Length == 0 ? $"Exit status {process.ExitCode}." : detail);
        }
        return output.ToArray();
    }

    private static ProcessStartInfo StartInfo(string executable, IReadOnlyList<string> arguments)
    {
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        return info;
    }
}

public static class AndroidEmulatorTools
{
    public const string Name = "android_emulator";
    private static JsonObject StringParameter(string description) => new() { ["type"] = "string", ["description"] = description };
    private static JsonObject IntegerParameter(string description) => new() { ["type"] = "integer", ["description"] = description };

    public static NativeToolDefinition Definition { get; } = new(Name,
        "Control Android emulators and connected devices. Before verification, list devices and reuse an online emulator by its exact serial. Do not boot another emulator while one is already online unless the user asks for a different AVD. Only boot an AVD if no compatible emulator is running. Supports install/launch, screenshots, input, and logs.",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["action"] = new JsonObject
                {
                    ["type"] = "string",
                    ["enum"] = new JsonArray("list_devices", "list_avds", "boot", "shutdown", "screenshot", "install", "launch", "terminate", "open_url", "tap", "text", "swipe", "logcat"),
                    ["description"] = "Operation to perform.",
                },
                ["device"] = StringParameter("Device serial. Defaults to an online emulator, then the first online device. List devices first and reuse the existing emulator."),
                ["avd_name"] = StringParameter("Name of the AVD to boot."),
                ["component"] = StringParameter("Package and activity name, for example com.example.app/.MainActivity."),
                ["package"] = StringParameter("Package identifier to terminate."),
                ["apk_path"] = StringParameter("Path to an APK, relative to the workspace or absolute."),
                ["url"] = StringParameter("URL to open on the device."),
                ["path"] = StringParameter("Workspace-relative screenshot destination. Defaults to android.png."),
                ["x"] = IntegerParameter("Tap X coordinate."), ["y"] = IntegerParameter("Tap Y coordinate."),
                ["text"] = StringParameter("Text to enter into the focused element."),
                ["x1"] = IntegerParameter("Swipe start X."), ["y1"] = IntegerParameter("Swipe start Y."),
                ["x2"] = IntegerParameter("Swipe end X."), ["y2"] = IntegerParameter("Swipe end Y."),
            },
            ["required"] = new JsonArray("action"),
        });

    public static bool RequiresApproval(NativeToolCall call)
    {
        try
        {
            var action = JsonNode.Parse(call.Arguments)?["action"]?.GetValue<string>();
            return action is not ("list_devices" or "list_avds");
        }
        catch { return true; }
    }

    public static async Task<string> ExecuteAsync(NativeToolCall call, string workspace, CancellationToken ct = default)
    {
        try
        {
            var input = JsonNode.Parse(call.Arguments)?.AsObject() ?? new JsonObject();
            var action = input["action"]?.GetValue<string>() ?? throw new AndroidEmulatorException("Missing action.");
            switch (action)
            {
                case "list_devices":
                {
                    var devices = await AndroidEmulatorService.DevicesAsync(ct);
                    return devices.Count == 0 ? "No Android devices or emulators found." : string.Join("\n", devices.Select(device =>
                        $"{(device.IsEmulator ? "Emulator" : "Connected device")} — {device.Name} — {(device.IsOnline ? "online" : device.State)} — serial: {device.Id}"));
                }
                case "list_avds":
                {
                    var avds = await AndroidEmulatorService.AvdsAsync(ct);
                    return avds.Count == 0 ? "No Android Virtual Devices (AVDs) configured." : string.Join("\n", avds);
                }
                case "boot":
                {
                    var avd = Required(input, "avd_name");
                    AndroidEmulatorService.Boot(avd);
                    return $"Booting Android emulator '{avd}' in background.";
                }
                case "shutdown":
                {
                    var serial = await ResolveDevice(input["device"]?.GetValue<string>(), ct);
                    await AndroidEmulatorService.ShutdownAsync(serial, ct);
                    return $"Shut down emulator {serial}.";
                }
                case "screenshot":
                {
                    var serial = await ResolveDevice(input["device"]?.GetValue<string>(), ct);
                    var relative = input["path"]?.GetValue<string>() ?? "android.png";
                    var destination = ResolveWorkspacePath(relative, workspace);
                    var bytes = await AndroidEmulatorService.ScreenshotAsync(serial, ct);
                    Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                    var temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
                    try { await File.WriteAllBytesAsync(temporary, bytes, ct); File.Move(temporary, destination, overwrite: true); }
                    finally { try { File.Delete(temporary); } catch { } }
                    return $"Saved Android screenshot to {relative} ({bytes.Length} bytes).";
                }
                case "install":
                {
                    var serial = await ResolveDevice(input["device"]?.GetValue<string>(), ct);
                    var apk = Required(input, "apk_path");
                    var resolved = ResolveApkPath(apk, workspace);
                    await AndroidEmulatorService.InstallAsync(serial, resolved, ct);
                    return $"Installed {apk} onto {serial}.";
                }
                case "launch":
                {
                    var serial = await ResolveDevice(input["device"]?.GetValue<string>(), ct);
                    var component = Required(input, "component");
                    var output = await AndroidEmulatorService.LaunchAsync(serial, component, ct);
                    return output.Length == 0 ? $"Launched {component} on {serial}." : output;
                }
                case "terminate":
                {
                    var serial = await ResolveDevice(input["device"]?.GetValue<string>(), ct);
                    var package = Required(input, "package");
                    await AndroidEmulatorService.TerminateAsync(serial, package, ct);
                    return $"Terminated {package} on {serial}.";
                }
                case "open_url":
                {
                    var serial = await ResolveDevice(input["device"]?.GetValue<string>(), ct);
                    var url = Required(input, "url");
                    if (!Uri.TryCreate(url, UriKind.Absolute, out var parsed) || parsed.Scheme is not ("http" or "https"))
                        throw new AndroidEmulatorException("Enter an absolute HTTP or HTTPS URL.");
                    await AndroidEmulatorService.OpenUrlAsync(serial, url, ct);
                    return $"Opened URL on {serial}.";
                }
                case "tap":
                {
                    var serial = await ResolveDevice(input["device"]?.GetValue<string>(), ct);
                    var (x, y) = (RequiredInt(input, "x"), RequiredInt(input, "y"));
                    await AndroidEmulatorService.TapAsync(serial, x, y, ct);
                    return $"Tapped at ({x}, {y}) on {serial}.";
                }
                case "text":
                {
                    var serial = await ResolveDevice(input["device"]?.GetValue<string>(), ct);
                    await AndroidEmulatorService.TextInputAsync(serial, Required(input, "text"), ct);
                    return $"Entered text into {serial}.";
                }
                case "swipe":
                {
                    var serial = await ResolveDevice(input["device"]?.GetValue<string>(), ct);
                    await AndroidEmulatorService.SwipeAsync(serial, RequiredInt(input, "x1"), RequiredInt(input, "y1"), RequiredInt(input, "x2"), RequiredInt(input, "y2"), ct);
                    return $"Swiped on {serial}.";
                }
                case "logcat":
                {
                    var serial = await ResolveDevice(input["device"]?.GetValue<string>(), ct);
                    var logs = await AndroidEmulatorService.LogcatAsync(serial, ct);
                    return logs.Length == 0 ? "No error logs found in logcat." : logs;
                }
                default: return $"Unknown android_emulator action: {action}";
            }
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception error) { return $"android_emulator error: {error.Message}"; }
    }

    private static string Required(JsonObject input, string name)
    {
        var value = input[name]?.GetValue<string>()?.Trim();
        return string.IsNullOrWhiteSpace(value) ? throw new AndroidEmulatorException($"Missing {name}.") : value;
    }

    private static int RequiredInt(JsonObject input, string name) =>
        int.TryParse(input[name]?.ToString(), out var value) && value >= 0 ? value : throw new AndroidEmulatorException($"Missing or invalid {name} coordinate.");

    private static async Task<string> ResolveDevice(string? candidate, CancellationToken ct)
    {
        var serial = candidate?.Trim();
        if (!string.IsNullOrEmpty(serial) && !serial.Equals("first", StringComparison.OrdinalIgnoreCase)) return serial;
        var devices = await AndroidEmulatorService.DevicesAsync(ct);
        return devices.FirstOrDefault(device => device.IsEmulator && device.IsOnline)?.Id
            ?? devices.FirstOrDefault(device => device.IsOnline)?.Id
            ?? throw new AndroidEmulatorException("No connected Android device or running emulator found.");
    }

    private static string ResolveWorkspacePath(string path, string workspace)
    {
        if (Path.IsPathRooted(path)) throw new AndroidEmulatorException("Screenshot destination must be relative to the workspace.");
        return ResolveContained(path, workspace);
    }

    private static string ResolveApkPath(string path, string workspace) =>
        Path.IsPathRooted(path) ? Path.GetFullPath(path) : ResolveContained(path, workspace);

    private static string ResolveContained(string path, string workspace)
    {
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) throw new AndroidEmulatorException("An open workspace is required.");
        var root = ResolveExistingPrefix(Path.GetFullPath(workspace));
        var full = ResolveExistingPrefix(Path.GetFullPath(Path.Combine(root, path)));
        var prefix = Path.EndsInDirectorySeparator(root) ? root : root + Path.DirectorySeparatorChar;
        if (!full.Equals(root, PathComparison) && !full.StartsWith(prefix, PathComparison))
            throw new AndroidEmulatorException($"Path outside workspace: {path}");
        return full;
    }

    private static string ResolveExistingPrefix(string path)
    {
        var missing = new Stack<string>();
        var current = path;
        while (!File.Exists(current) && !Directory.Exists(current))
        {
            var name = Path.GetFileName(current);
            var parent = Path.GetDirectoryName(current);
            if (string.IsNullOrEmpty(name) || string.IsNullOrEmpty(parent)) break;
            missing.Push(name);
            current = parent;
        }
        FileSystemInfo info = Directory.Exists(current) ? new DirectoryInfo(current) : new FileInfo(current);
        try { current = info.ResolveLinkTarget(returnFinalTarget: true)?.FullName ?? info.FullName; }
        catch { current = info.FullName; }
        while (missing.Count > 0) current = Path.Combine(current, missing.Pop());
        return Path.GetFullPath(current);
    }

    private static StringComparison PathComparison => OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
}
