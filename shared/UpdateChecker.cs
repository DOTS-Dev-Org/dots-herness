// Copyright (c) 2026 DOTS
// Multiplatform version checking, release discovery and update management for Windows and Linux.

using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace DotsHarnessCore;

public sealed record UpdateCheckResult(
    [property: JsonPropertyName("platform")] string Platform,
    [property: JsonPropertyName("current_version")] string CurrentVersion,
    [property: JsonPropertyName("latest_version")] string LatestVersion,
    [property: JsonPropertyName("build_number")] int BuildNumber,
    [property: JsonPropertyName("min_supported_version")] string MinSupportedVersion,
    [property: JsonPropertyName("update_available")] bool UpdateAvailable,
    [property: JsonPropertyName("mandatory")] bool Mandatory,
    [property: JsonPropertyName("release_notes")] string ReleaseNotes,
    [property: JsonPropertyName("download_url")] string DownloadUrl,
    [property: JsonPropertyName("published_at")] string PublishedAt);

public sealed class CrossPlatformUpdateChecker
{
    public const string DefaultCheckEndpoint = "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev/harness/check-update";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };

    private readonly string _endpoint;

    public CrossPlatformUpdateChecker(string? endpoint = null)
    {
        _endpoint = endpoint ?? DefaultCheckEndpoint;
    }

    public async Task<UpdateCheckResult?> CheckForUpdatesAsync(
        string platform,
        string currentVersion,
        int currentBuild = 1,
        CancellationToken cancellationToken = default)
    {
        var url = $"{_endpoint}?platform={Uri.EscapeDataString(platform)}&version={Uri.EscapeDataString(currentVersion)}&build={currentBuild}";

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Accept.ParseAdd("application/json");

        using var response = await Http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            return null;
        }

        var json = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        return JsonSerializer.Deserialize<UpdateCheckResult>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        });
    }

    /// <summary>Startup check: returns a result only when an update exists; swallows all errors.</summary>
    public static async Task<UpdateCheckResult?> CheckOnStartupAsync(string platform)
    {
        try
        {
            var v = Assembly.GetEntryAssembly()?.GetName().Version ?? new Version(0, 1, 0);
            var result = await new CrossPlatformUpdateChecker()
                .CheckForUpdatesAsync(platform, $"{v.Major}.{v.Minor}.{Math.Max(v.Build, 0)}")
                .ConfigureAwait(false);
            return result is { UpdateAvailable: true } ? result : null;
        }
        catch
        {
            return null;
        }
    }
}

/// <summary>
/// Downloads a release archive, swaps it in for the running install once the app
/// exits, and relaunches. Returns false when the install can't be replaced in place
/// (non-writable folder, unexpected archive), so callers fall back to the download page.
/// </summary>
public static class UpdateInstaller
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(10) };

    // ponytail: no Authenticode/GPG check on Windows/Linux builds (they aren't signed yet);
    // integrity rests on HTTPS to our own release path. Add signature verification once releases are signed.
    public static bool IsAllowedDownloadUrl(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var u)
        && u.Scheme == Uri.UriSchemeHttps
        && string.IsNullOrEmpty(u.UserInfo)
        && u.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase)
        && u.AbsolutePath.StartsWith("/DOTS-Dev-Org/dots-herness/releases/", StringComparison.Ordinal);

    public static async Task<bool> InstallAndRelaunchAsync(UpdateCheckResult update, CancellationToken cancellationToken = default)
    {
        var exePath = Environment.ProcessPath;
        var appDir = Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory);
        var parent = Path.GetDirectoryName(appDir);
        if (exePath is null || parent is null || !IsAllowedDownloadUrl(update.DownloadUrl) || !CanWrite(parent)) return false;
        var exeName = Path.GetFileName(exePath);

        var work = Path.Combine(Path.GetTempPath(), "DotsHarnessUpdate-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        try
        {
            var archive = Path.Combine(work, OperatingSystem.IsWindows() ? "update.zip" : "update.tar.xz");
            using (var response = await Http.GetAsync(update.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false))
            {
                response.EnsureSuccessStatusCode();
                await using var file = File.Create(archive);
                await response.Content.CopyToAsync(file, cancellationToken).ConfigureAwait(false);
            }

            var extracted = Path.Combine(work, "x");
            Directory.CreateDirectory(extracted);
            if (OperatingSystem.IsWindows()) ZipFile.ExtractToDirectory(archive, extracted);
            else if (!await RunAsync("tar", cancellationToken, "-xJf", archive, "-C", extracted).ConfigureAwait(false)) return false;

            // The Linux tarball wraps everything in one top-level folder; the Windows zip doesn't.
            var root = extracted;
            if (Directory.GetFiles(root).Length == 0 && Directory.GetDirectories(root) is [var only]) root = only;
            if (!File.Exists(Path.Combine(root, exeName))) return false;

            // Paths travel as environment variables so nothing is interpolated into the script.
            var psi = OperatingSystem.IsWindows()
                ? new ProcessStartInfo("powershell.exe") { ArgumentList = { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", WindowsSwapScript } }
                : new ProcessStartInfo("/bin/sh") { ArgumentList = { "-c", UnixSwapScript } };
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.Environment["DH_PID"] = Environment.ProcessId.ToString();
            psi.Environment["DH_SRC"] = root;
            psi.Environment["DH_DEST"] = appDir;
            psi.Environment["DH_EXE"] = exeName;
            psi.Environment["DH_TMP"] = work;
            Process.Start(psi)?.Dispose();
            return true;
        }
        catch (Exception) when (!cancellationToken.IsCancellationRequested)
        {
            try { Directory.Delete(work, true); } catch { }
            return false;
        }
    }

    private const string UnixSwapScript = """
        while kill -0 "$DH_PID" 2>/dev/null; do sleep 0.2; done
        rm -rf "$DH_DEST.old"
        if mv "$DH_DEST" "$DH_DEST.old" && cp -a "$DH_SRC" "$DH_DEST"; then rm -rf "$DH_DEST.old"; else rm -rf "$DH_DEST"; mv "$DH_DEST.old" "$DH_DEST"; fi
        rm -rf "$DH_TMP"
        nohup "$DH_DEST/$DH_EXE" >/dev/null 2>&1 &
        """;

    private const string WindowsSwapScript = """
        while (Get-Process -Id $env:DH_PID -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 200 }
        $d = $env:DH_DEST; $o = "$d.old"
        if (Test-Path -LiteralPath $o) { Remove-Item -LiteralPath $o -Recurse -Force }
        try {
            Move-Item -LiteralPath $d -Destination $o -ErrorAction Stop
            Copy-Item -LiteralPath $env:DH_SRC -Destination $d -Recurse -ErrorAction Stop
            Remove-Item -LiteralPath $o -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            if (Test-Path -LiteralPath $o) {
                if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
                Move-Item -LiteralPath $o -Destination $d
            }
        }
        Remove-Item -LiteralPath $env:DH_TMP -Recurse -Force -ErrorAction SilentlyContinue
        Start-Process -FilePath (Join-Path $d $env:DH_EXE)
        """;

    private static bool CanWrite(string dir)
    {
        try
        {
            var probe = Path.Combine(dir, ".dh-write-" + Guid.NewGuid().ToString("N"));
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return true;
        }
        catch { return false; }
    }

    private static async Task<bool> RunAsync(string tool, CancellationToken ct, params string[] args)
    {
        var psi = new ProcessStartInfo(tool) { UseShellExecute = false };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi);
        if (p is null) return false;
        await p.WaitForExitAsync(ct).ConfigureAwait(false);
        return p.ExitCode == 0;
    }
}
