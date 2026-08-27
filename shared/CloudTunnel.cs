// Copyright (c) 2026 DOTS
// Explicitly downloaded, checksum-pinned Quick Tunnel process.

using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using PluginRuntime;

namespace DotsHarnessCore;

public sealed class CloudTunnelProcess : IDisposable
{
    private const string Release = "2026.5.2";
    private readonly SupportPaths _paths;
    private Process? _process;
    private TaskCompletionSource<string>? _url;

    public CloudTunnelProcess(SupportPaths paths) => _paths = paths;

    public async Task<string> StartAsync(int gatewayPort, Action<FileDownloader.Progress>? progress = null, CancellationToken ct = default)
    {
        Stop();
        _paths.Ensure();
        var asset = AssetForCurrentPlatform();
        var binary = Path.Combine(_paths.Runtime, asset.FileName);
        await FileDownloader.DownloadAsync(asset.Url, binary, progress: progress, ct: ct, sha256: asset.Sha256);
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(binary, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }

        _url = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = binary,
                WorkingDirectory = _paths.Runtime,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            },
            EnableRaisingEvents = true,
        };
        process.StartInfo.ArgumentList.Add("tunnel");
        process.StartInfo.ArgumentList.Add("--no-autoupdate");
        process.StartInfo.ArgumentList.Add("--url");
        process.StartInfo.ArgumentList.Add($"http://127.0.0.1:{gatewayPort}");
        process.OutputDataReceived += OnLine;
        process.ErrorDataReceived += OnLine;
        process.Exited += (_, _) => _url?.TrySetException(new RouterException("The sharing process stopped before it produced a public URL."));
        if (!process.Start()) throw new RouterException("The sharing process could not start.");
        _process = process;
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(45));
        try
        {
            return await _url.Task.WaitAsync(timeout.Token);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            Stop();
            throw new RouterException("The sharing process did not produce a public URL in time.");
        }
        catch
        {
            Stop();
            throw;
        }
    }

    public void Stop()
    {
        try
        {
            if (_process is { HasExited: false }) _process.Kill(entireProcessTree: true);
        }
        catch { }
        _process?.Dispose();
        _process = null;
        _url = null;
    }

    public void Dispose() => Stop();

    private void OnLine(object sender, DataReceivedEventArgs args)
    {
        if (string.IsNullOrWhiteSpace(args.Data) || _url is null) return;
        var match = Regex.Match(args.Data, @"https://[a-z0-9-]+\.trycloudflare\.com", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        if (match.Success) _url.TrySetResult(match.Value.TrimEnd('.'));
    }

    private static CloudTunnelAsset AssetForCurrentPlatform()
    {
        const string root = $"https://github.com/cloudflare/cloudflared/releases/download/{Release}/";
        return (OperatingSystem.IsWindows(), OperatingSystem.IsLinux(), RuntimeInformation.ProcessArchitecture) switch
        {
            (true, _, Architecture.X64) => new CloudTunnelAsset("cloudflared-windows-amd64.exe", new Uri(root + "cloudflared-windows-amd64.exe"), "20b9638f685333d623798e733effbad2487093f15ba592f6c7752360ff3b7ab7"),
            (true, _, Architecture.X86) => new CloudTunnelAsset("cloudflared-windows-386.exe", new Uri(root + "cloudflared-windows-386.exe"), "6736615e8d2b3b61e868e32907e85641b4ec7b2b8c26bd3361ec15e56e53e242"),
            (_, true, Architecture.X64) => new CloudTunnelAsset("cloudflared-linux-amd64", new Uri(root + "cloudflared-linux-amd64"), "5286698547f03df745adb2355f04c12dde52ef425491e81f433642d695521886"),
            (_, true, Architecture.Arm64) => new CloudTunnelAsset("cloudflared-linux-arm64", new Uri(root + "cloudflared-linux-arm64"), "5a4e8ce2701105271412059f44b6a0bf1ae4542b4d98ff3180c0c019443a5815"),
            _ => throw new RouterException("Sharing is not available for this platform architecture."),
        };
    }

    private sealed record CloudTunnelAsset(string FileName, Uri Url, string Sha256);
}
