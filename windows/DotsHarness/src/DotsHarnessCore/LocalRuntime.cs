// Copyright (c) 2026 DOTS
// Downloads llama.cpp and serves a GGUF over OpenAI-compatible HTTP.

using System.Diagnostics;
using System.IO.Compression;
using HarnessPluginKit;
using PluginRuntime;

namespace DotsHarnessCore;

public sealed class LocalRuntime
{
    public const int DefaultPort = 18765;
    public const string NodePrefix = "local";

    public SupportPaths Paths { get; }
    public int Port { get; }

    private Process? _process;
    private string? _runningModel;

    public LocalRuntime(SupportPaths paths, int port = DefaultPort)
    {
        Paths = paths;
        Port = port;
        paths.Ensure();
    }

    public Uri ServerUrl => new($"http://127.0.0.1:{Port}/v1");
    public string BinaryPath => Path.Combine(Paths.Runtime, "llama-server.exe");
    public string ArchivePath => Path.Combine(Paths.Runtime, "llama.cpp.zip");

    public string ModelPath(LocalModelSpec spec) => Path.Combine(Paths.Models, spec.Filename);

    public bool IsInstalled(LocalModelSpec spec)
    {
        var path = ModelPath(spec);
        if (!File.Exists(path)) return false;
        var size = new FileInfo(path).Length;
        return size >= Math.Max(1, spec.Bytes / 2);
    }

    public long InstalledBytes(LocalModelSpec spec)
    {
        var path = ModelPath(spec);
        return File.Exists(path) ? new FileInfo(path).Length : 0;
    }

    public bool RuntimeInstalled() => File.Exists(BinaryPath);

    public string? RunningModelId() => _runningModel;

    public bool IsServing() => _process is { HasExited: false };

    public async Task EnsureRuntimeAsync(Action<FileDownloader.Progress>? progress = null, CancellationToken ct = default)
    {
        if (RuntimeInstalled()) return;
        var asset = await LatestWindowsAssetAsync(ct);
        await FileDownloader.DownloadAsync(asset.Url, ArchivePath, asset.Size, progress, ct);
        UnpackRuntime(ArchivePath);
        if (!RuntimeInstalled()) throw new RouterException("llama-server missing after unpack");
    }

    public Task DownloadModelAsync(LocalModelSpec spec, Action<FileDownloader.Progress>? progress = null, CancellationToken ct = default) =>
        FileDownloader.DownloadAsync(spec.Url, ModelPath(spec), spec.Bytes, progress, ct);

    public Uri Start(LocalModelSpec spec)
    {
        if (_process is { HasExited: false } && _runningModel == spec.Id) return ServerUrl;
        Stop();
        if (!RuntimeInstalled()) throw new RouterException("Install the local runtime first");
        if (!IsInstalled(spec)) throw new RouterException($"Download {spec.Name} first");

        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = BinaryPath,
                ArgumentList =
                {
                    "--model", ModelPath(spec),
                    "--host", "127.0.0.1",
                    "--port", Port.ToString(),
                    "--ctx-size", Math.Min(spec.Context, 8192).ToString(),
                    "--alias", spec.Id,
                    "--jinja",
                },
                WorkingDirectory = Paths.Runtime,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            },
        };
        if (!process.Start()) throw new RouterException("failed to start llama-server");
        _process = process;
        _runningModel = spec.Id;
        return ServerUrl;
    }

    public void Stop()
    {
        try
        {
            if (_process is { HasExited: false }) _process.Kill(entireProcessTree: true);
        }
        catch
        {
            // best-effort
        }
        _process = null;
        _runningModel = null;
    }

    public async Task<bool> WaitUntilReadyAsync(int timeoutMs = 20_000, CancellationToken ct = default)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            if (_process is { HasExited: true }) return false;
            if (await PingAsync(ct)) return true;
            await Task.Delay(250, ct);
        }
        return await PingAsync(ct);
    }

    public async Task<bool> PingAsync(CancellationToken ct = default)
    {
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromMilliseconds(1500) };
            using var response = await http.GetAsync($"http://127.0.0.1:{Port}/health", ct);
            var status = (int)response.StatusCode;
            return status is >= 200 and < 500;
        }
        catch
        {
            try
            {
                using var http = new HttpClient { Timeout = TimeSpan.FromMilliseconds(1500) };
                using var response = await http.GetAsync($"http://127.0.0.1:{Port}/v1/models", ct);
                var status = (int)response.StatusCode;
                return status is >= 200 and < 500;
            }
            catch
            {
                return false;
            }
        }
    }

    public sealed record ReleaseAsset(string Tag, Uri Url, long Size);

    public async Task<ReleaseAsset> LatestWindowsAssetAsync(CancellationToken ct = default)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest");
        request.Headers.UserAgent.ParseAdd("DotsHarness");
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        using var response = await http.SendAsync(request, ct);
        if (!response.IsSuccessStatusCode)
        {
            throw new RouterException($"GitHub release HTTP {(int)response.StatusCode}");
        }
        var json = DshJson.Parse(await response.Content.ReadAsByteArrayAsync(ct));
        return WindowsAsset(json, HostArch);
    }

    public static ReleaseAsset WindowsAsset(JsonValue json, string arch)
    {
        var tag = json["tag_name"]?.AsString() ?? "latest";
        var needles = new[]
        {
            $"bin-win-cuda-12.4-{arch}",
            $"bin-win-cuda-12-{arch}",
            $"bin-win-cpu-{arch}",
            $"bin-win-{arch}",
        };
        var assets = json["assets"]?.AsArray() ?? throw new RouterException("No llama.cpp assets");
        foreach (var needle in needles)
        {
            foreach (var asset in assets)
            {
                var name = asset["name"]?.AsString() ?? "";
                if (!name.Contains(needle, StringComparison.OrdinalIgnoreCase)) continue;
                if (!name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) continue;
                var href = asset["browser_download_url"]?.AsString();
                if (href is null || !Uri.TryCreate(href, UriKind.Absolute, out var remote)) continue;
                return new ReleaseAsset(tag, remote, asset["size"]?.AsInt() ?? 0);
            }
        }
        throw new RouterException($"No Windows {arch} llama.cpp build in {tag}");
    }

    public static string HostArch => Environment.Is64BitOperatingSystem
        ? (RuntimeInformationCompat.IsArm64 ? "arm64" : "x64")
        : "x86";

    private void UnpackRuntime(string archive)
    {
        var extract = Path.Combine(Paths.Runtime, "extract");
        if (Directory.Exists(extract)) Directory.Delete(extract, recursive: true);
        Directory.CreateDirectory(extract);
        ZipFile.ExtractToDirectory(archive, extract, overwriteFiles: true);
        var found = FirstFile("llama-server.exe", extract) ?? FirstFile("llama-server", extract)
            ?? throw new RouterException("llama-server not in archive");
        if (File.Exists(BinaryPath)) File.Delete(BinaryPath);
        File.Copy(found, BinaryPath, overwrite: true);
        // Copy sibling DLLs next to the server binary.
        var foundDir = Path.GetDirectoryName(found);
        if (foundDir is not null)
        {
            foreach (var dll in Directory.GetFiles(foundDir, "*.dll"))
            {
                File.Copy(dll, Path.Combine(Paths.Runtime, Path.GetFileName(dll)), overwrite: true);
            }
        }
        try { Directory.Delete(extract, recursive: true); } catch { /* leftover extract is fine */ }
    }

    private static string? FirstFile(string name, string root)
    {
        return Directory.EnumerateFiles(root, name, SearchOption.AllDirectories).FirstOrDefault();
    }
}

internal static class RuntimeInformationCompat
{
    public static bool IsArm64 =>
        System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture
            is System.Runtime.InteropServices.Architecture.Arm64;
}
