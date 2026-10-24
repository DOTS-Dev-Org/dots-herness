// Copyright (c) 2026 DOTS
// Installs a pinned llama.cpp build matched to the machine's GPU and serves a
// GGUF over OpenAI-compatible HTTP. Shared by the Windows and Linux apps.

using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;
using PluginRuntime;

namespace DotsHarnessCore;

/// <summary>llama.cpp builds, best first for the hardware they target.</summary>
public enum LocalBackend
{
    Cuda13,
    Cuda12,
    Rocm,
    Vulkan,
    Cpu,
}

/// <summary>A compute device as <c>llama-server --list-devices</c> reports it.</summary>
public sealed record LocalDevice(string Id, string Name, int MemoryMiB);

/// <summary>A graphics adapter found before any runtime is installed.</summary>
public sealed record LocalGpu(string Vendor, string Name, int DriverMajor = 0);

/// <summary>
/// User tuning for the bundled server. Zero / empty / "auto" leave the choice
/// to llama.cpp, which already fits layers to the device memory.
/// </summary>
public sealed class LocalRuntimeSettings
{
    public string Backend { get; set; } = "auto";
    public int ContextSize { get; set; }
    public string GpuLayers { get; set; } = "auto";
    public int Threads { get; set; }
    public int BatchSize { get; set; }
    public string FlashAttention { get; set; } = "auto";
    public string KvCacheType { get; set; } = "";
    public string ExtraArgs { get; set; } = "";
    public List<string> ImportedModels { get; set; } = [];
}

public static class LocalHardware
{
    /// <summary>
    /// Adapters in this machine. Only a hint for which build to try first: the
    /// installed build's own device list is what confirms a GPU works.
    /// </summary>
    public static IReadOnlyList<LocalGpu> Detect()
    {
        var gpus = ParseNvidiaSmi(RunQuiet("nvidia-smi", "--query-gpu=name,driver_version", "--format=csv,noheader")).ToList();
        IEnumerable<LocalGpu> adapters = [];
        if (OperatingSystem.IsWindows())
        {
            adapters = ParsePnp(RunQuiet("powershell", "-NoProfile", "-NonInteractive", "-Command",
                "Get-CimInstance Win32_VideoController | ForEach-Object { $_.PNPDeviceID + '|' + $_.Name }"));
        }
        else if (OperatingSystem.IsLinux() && Directory.Exists("/sys/class/drm"))
        {
            adapters = Directory.EnumerateDirectories("/sys/class/drm", "card*")
                .Select(card => Path.Combine(card, "device", "vendor"))
                .Where(File.Exists)
                .Select(file => VendorFromId(File.ReadAllText(file)))
                .Distinct()
                .Select(vendor => new LocalGpu(vendor, vendor));
        }
        // nvidia-smi already described NVIDIA cards, with the driver version.
        gpus.AddRange(adapters.Where(gpu => gpu.Vendor != "nvidia" || gpus.Count == 0));
        return gpus;
    }

    /// <summary>Lines look like <c>NVIDIA GeForce RTX 4070, 581.29</c>.</summary>
    public static IEnumerable<LocalGpu> ParseNvidiaSmi(string output)
    {
        foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var parts = line.Split(',', StringSplitOptions.TrimEntries);
            if (parts.Length < 2 || parts[0].Length == 0) continue;
            _ = int.TryParse(parts[1].Split('.')[0], out var major);
            yield return new LocalGpu("nvidia", parts[0], major);
        }
    }

    /// <summary>Lines look like <c>PCI\VEN_1002&amp;DEV_744C&amp;...|AMD Radeon RX 7900 XT</c>.</summary>
    public static IEnumerable<LocalGpu> ParsePnp(string output)
    {
        foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var parts = line.Split('|', 2);
            var match = Regex.Match(parts[0], "VEN_([0-9A-Fa-f]{4})");
            if (!match.Success) continue;
            yield return new LocalGpu(VendorFromId(match.Groups[1].Value), parts.Length > 1 ? parts[1].Trim() : "GPU");
        }
    }

    public static string VendorFromId(string id) => id.Trim().ToLowerInvariant().Replace("0x", "") switch
    {
        "10de" => "nvidia",
        "1002" or "1022" => "amd",
        "8086" => "intel",
        _ => "other",
    };

    /// <summary>
    /// Builds worth trying on this machine, best first. CUDA 13 needs NVIDIA
    /// driver 580+; an unknown driver version is tried and left to validation.
    /// </summary>
    public static IReadOnlyList<LocalBackend> Candidates(IReadOnlyList<LocalGpu> gpus, string arch, bool windows)
    {
        var order = new List<LocalBackend>();
        if (gpus.FirstOrDefault(gpu => gpu.Vendor == "nvidia") is { } nvidia)
        {
            if (nvidia.DriverMajor is 0 or >= 580) order.Add(LocalBackend.Cuda13);
            order.Add(LocalBackend.Cuda12);
        }
        if (gpus.Any(gpu => gpu.Vendor == "amd")) order.Add(LocalBackend.Rocm);
        // Vulkan drives every vendor's GPU, so it backs up the vendor builds.
        if (gpus.Count > 0) order.Add(LocalBackend.Vulkan);
        order.Add(LocalBackend.Cpu);
        return order.Where(backend => LocalRuntime.Assets(backend, arch, windows) is not null).ToList();
    }

    public static long TotalMemoryBytes => GC.GetGCMemoryInfo().TotalAvailableMemoryBytes;

    /// <summary>Output of a helper that may not exist; empty on any failure.</summary>
    private static string RunQuiet(string file, params string[] arguments)
    {
        try
        {
            var info = new ProcessStartInfo(file) { UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true };
            foreach (var argument in arguments) info.ArgumentList.Add(argument);
            using var process = Process.Start(info);
            if (process is null) return "";
            var output = process.StandardOutput.ReadToEndAsync();
            if (!process.WaitForExit(8000))
            {
                process.Kill(entireProcessTree: true);
                return "";
            }
            return output.GetAwaiter().GetResult();
        }
        catch
        {
            return "";
        }
    }
}

public sealed class LocalRuntime
{
    public const int DefaultPort = 18765;
    public const string NodePrefix = "local";

    /// <summary>
    /// The build behind llama.cpp's stable v0.5.0 (<c>nightly-tag.txt</c>).
    /// Pinned with checksums because the binary is executed: <c>releases/latest</c>
    /// no longer carries binaries, and a moving tag would run unreviewed code.
    /// </summary>
    public const string LlamaTag = "b11146";
    public const int IdleUnloadSeconds = 15;

    public sealed record PinnedAsset(string Name, long Size, string Sha256)
    {
        public Uri Url => new($"https://github.com/ggml-org/llama.cpp/releases/download/{LlamaTag}/{Name}");
    }

    /// <summary>A build plus, for CUDA, the NVIDIA runtime libraries it loads.</summary>
    public sealed record BackendAssets(PinnedAsset Main, PinnedAsset? CudaRuntime = null);

    public SupportPaths Paths { get; }
    public int Port { get; }

    private readonly object _logLock = new();
    private readonly Queue<string> _log = new();
    private Process? _process;
    private string? _runningModel;

    public LocalRuntime(SupportPaths paths, int port = DefaultPort)
    {
        Paths = paths;
        Port = port;
        paths.Ensure();
    }

    public Uri ServerUrl => new($"http://127.0.0.1:{Port}/v1");
    public string SettingsPath => Path.Combine(Paths.Runtime, "local-runtime.json");
    private string ActiveBackendPath => Path.Combine(Paths.Runtime, "llama-backend.txt");
    private static string ServerFileName => OperatingSystem.IsWindows() ? "llama-server.exe" : "llama-server";

    public static string HostArch =>
        RuntimeInformation.ProcessArchitecture is Architecture.Arm64 ? "arm64" : "x64";

    public static BackendAssets? Assets(LocalBackend backend, string arch, bool windows) => (windows, arch, backend) switch
    {
        (true, "x64", LocalBackend.Cuda13) => new(
            new($"llama-{LlamaTag}-bin-win-cuda-13.4-x64.zip", 149_758_833, "b1866c0ce76bc7bfb0c24b33e9a37e9669f1be18539b12c74ce361f81c41f047"),
            new("cudart-llama-bin-win-cuda-13.4-x64.zip", 423_535_356, "738f8c251ac22b70c3ae6f83a10cf222725df0395246a2cf58f32bdb85fbe668")),
        (true, "x64", LocalBackend.Cuda12) => new(
            new($"llama-{LlamaTag}-bin-win-cuda-12.4-x64.zip", 253_869_799, "3c806a6ceccc3dae1c743ceb1a1fb2cce5b76f40bfbd4c6b7b8afb6ef45a5807"),
            new("cudart-llama-bin-win-cuda-12.4-x64.zip", 391_443_627, "8c79a9b226de4b3cacfd1f83d24f962d0773be79f1e7b75c6af4ded7e32ae1d6")),
        (true, "x64", LocalBackend.Rocm) => new(
            new($"llama-{LlamaTag}-bin-win-rocm-10.0-x64.zip", 251_910_679, "5dee283ec0fd5f38f29df0929769a07266ac6047f74381c153eb54b441e4ef99")),
        (true, "x64", LocalBackend.Vulkan) => new(
            new($"llama-{LlamaTag}-bin-win-vulkan-x64.zip", 32_127_004, "55a378aa095b466979d85075234f66d7655c7a7483222af0c006c0e55b4d7bd6")),
        (true, "x64", LocalBackend.Cpu) => new(
            new($"llama-{LlamaTag}-bin-win-cpu-x64.zip", 18_560_055, "14cf1303ca9ac3abd94816850532f9f9a69ac66fbaca3776fc6f9061c2fac1d1")),
        (true, "arm64", LocalBackend.Cuda13) => new(
            new($"llama-{LlamaTag}-bin-win-cuda-13.4-arm64.zip", 142_599_200, "a4060b5031a0e862e225d4a7c4aa403852ebedf598906ef8258a86cb77de8351"),
            new("cudart-llama-bin-win-cuda-13.4-arm64.zip", 153_262_407, "642dcde8805b3e3165ca710a5443b3b4044b27d96bd3ee3132473988c9bcb774")),
        (true, "arm64", LocalBackend.Cpu) => new(
            new($"llama-{LlamaTag}-bin-win-cpu-arm64.zip", 12_034_624, "1727d241f3bf6d27360e984e851cf013928fd655bf89f8628e70da027f377b7d")),
        (false, "x64", LocalBackend.Cuda13) => new(
            new($"llama-{LlamaTag}-bin-ubuntu-cuda-13.4-x64.tar.gz", 149_265_156, "1603d9c00a4b6eac8298c5c7868cdb080a3ac31948ab1e457441d71ce274dd7e"),
            new($"cudart-llama-{LlamaTag}-bin-ubuntu-cuda-13.4-x64.tar.gz", 440_231_388, "7c2af505f8b26ecd3707ab7723fa985fee1df233b7c1d60e5e17724b536d15bb")),
        (false, "x64", LocalBackend.Cuda12) => new(
            new($"llama-{LlamaTag}-bin-ubuntu-cuda-12.8-x64.tar.gz", 168_920_581, "c2ab9e19838513ff69d1af8d999ad717dd3c7ee4714ac04c7ed5ab9077c50e4e"),
            new($"cudart-llama-{LlamaTag}-bin-ubuntu-cuda-12.8-x64.tar.gz", 594_373_356, "1466daea60aad1144819e151b2bae19d54556cf1da6c129c4f55a5ded2637c25")),
        (false, "x64", LocalBackend.Rocm) => new(
            new($"llama-{LlamaTag}-bin-ubuntu-rocm-10.0-x64.tar.gz", 234_721_151, "50e79dc559a11af3ea59391d416e9a704a715ac6be94352dbba710782c5dd7d1")),
        (false, "x64", LocalBackend.Vulkan) => new(
            new($"llama-{LlamaTag}-bin-ubuntu-vulkan-x64.tar.gz", 30_598_492, "d3ce40fce7403cc93bcf5718fc46c6efb61ed9709f8e5d9f10c86bf0e30e8fb3")),
        (false, "x64", LocalBackend.Cpu) => new(
            new($"llama-{LlamaTag}-bin-ubuntu-x64.tar.gz", 16_998_357, "c150306eb16b5ab696f76a8bdf810c35fd98a24e82158742e6fa28f420ff8410")),
        (false, "arm64", LocalBackend.Cuda13) => new(
            new($"llama-{LlamaTag}-bin-ubuntu-cuda-13.4-arm64.tar.gz", 145_033_340, "4e00496ab6cdee9c00afb11de3cb9d10f9da7e17147d8ed14ca3af05209b400f"),
            new($"cudart-llama-{LlamaTag}-bin-ubuntu-cuda-13.4-arm64.tar.gz", 552_520_827, "7f46057efcba6338c58ed9f91c06f268c290f3a228fdbdd4bea229dd60b0e094")),
        (false, "arm64", LocalBackend.Vulkan) => new(
            new($"llama-{LlamaTag}-bin-ubuntu-vulkan-arm64.tar.gz", 24_410_274, "5dcebe3ecbcb43a1ed85e3284453f9edf54dcca833e1cb1f54b4022b753c1da5")),
        (false, "arm64", LocalBackend.Cpu) => new(
            new($"llama-{LlamaTag}-bin-ubuntu-arm64.tar.gz", 13_598_346, "4aeda6fe68831547e49b7fa87607383ca5352b3d72ca5f70d52ed265f58c131f")),
        _ => null,
    };

    // MARK: Settings

    public LocalRuntimeSettings LoadSettings()
    {
        try
        {
            return JsonSerializer.Deserialize<LocalRuntimeSettings>(File.ReadAllText(SettingsPath)) ?? new();
        }
        catch
        {
            return new();
        }
    }

    public void SaveSettings(LocalRuntimeSettings settings)
    {
        try { File.WriteAllText(SettingsPath, JsonSerializer.Serialize(settings)); } catch { /* settings are best-effort */ }
    }

    // MARK: Models

    public string ModelPath(LocalModelSpec spec) => spec.LocalPath ?? Path.Combine(Paths.Models, spec.Filename);

    public bool IsInstalled(LocalModelSpec spec)
    {
        var path = ModelPath(spec);
        if (!File.Exists(path)) return false;
        return spec.LocalPath is not null || new FileInfo(path).Length >= Math.Max(1, spec.Bytes / 2);
    }

    public long InstalledBytes(LocalModelSpec spec)
    {
        var path = ModelPath(spec);
        return File.Exists(path) ? new FileInfo(path).Length : 0;
    }

    public Task DownloadModelAsync(LocalModelSpec spec, Action<FileDownloader.Progress>? progress = null, CancellationToken ct = default) =>
        spec.LocalPath is not null
            ? Task.CompletedTask
            : RetryAsync(() => FileDownloader.DownloadAsync(spec.Url, ModelPath(spec), spec.Bytes, progress, ct, spec.Sha256), ct);

    /// <summary>Flaky links drop multi-gigabyte downloads; a few attempts absorb that.</summary>
    private static async Task RetryAsync(Func<Task> operation, CancellationToken ct, int attempts = 4)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                await operation();
                return;
            }
            catch (Exception ex) when (ex is not OperationCanceledException && attempt < attempts)
            {
                await Task.Delay(TimeSpan.FromSeconds(attempt * 2), ct);
            }
        }
    }

    // MARK: Runtime

    /// <summary>The build that passed validation on this machine, if any.</summary>
    public LocalBackend? ActiveBackend
    {
        get
        {
            try
            {
                return Enum.TryParse<LocalBackend>(File.ReadAllText(ActiveBackendPath).Trim(), out var backend) ? backend : null;
            }
            catch
            {
                return null;
            }
        }
    }

    public string BackendDirectory(LocalBackend backend) =>
        Path.Combine(Paths.Runtime, $"llama-{LlamaTag}-{backend.ToString().ToLowerInvariant()}");

    /// <summary>The server inside a build's folder; archives nest it at different depths.</summary>
    private static string? FindServer(string directory) =>
        Directory.Exists(directory)
            ? Directory.EnumerateFiles(directory, ServerFileName, SearchOption.AllDirectories).FirstOrDefault()
            : null;

    public string BinaryPath => ActiveBackend is { } backend
        ? FindServer(BackendDirectory(backend)) ?? Path.Combine(BackendDirectory(backend), ServerFileName)
        : Path.Combine(Paths.Runtime, ServerFileName);

    public bool RuntimeInstalled() => ActiveBackend is { } backend && FindServer(BackendDirectory(backend)) is not null;

    public string? RunningModelId() => _runningModel;

    public bool IsServing() => _process is { HasExited: false };

    /// <summary>
    /// Installs the best build for this machine. Each GPU build is validated by
    /// asking it to list its devices; one that finds no GPU (missing driver,
    /// unsupported card) is dropped and the next candidate is tried, ending at CPU.
    /// </summary>
    public async Task EnsureRuntimeAsync(
        LocalRuntimeSettings settings, Action<FileDownloader.Progress>? progress = null, CancellationToken ct = default)
    {
        if (RuntimeInstalled()) return;
        var forced = Enum.TryParse<LocalBackend>(settings.Backend, ignoreCase: true, out var chosen);
        IReadOnlyList<LocalBackend> candidates = forced
            ? [chosen]
            : LocalHardware.Candidates(LocalHardware.Detect(), HostArch, OperatingSystem.IsWindows());
        Exception? last = null;
        foreach (var backend in candidates)
        {
            try
            {
                await InstallAsync(backend, progress, ct);
                // A build the user picked by hand is trusted; so is CPU, which has no device to find.
                if (forced || backend == LocalBackend.Cpu || (await DevicesAsync(backend, ct)).Count > 0)
                {
                    File.WriteAllText(ActiveBackendPath, backend.ToString());
                    return;
                }
                last = new RouterException($"The {backend} build found no usable GPU.");
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                last = ex;
            }
            try { Directory.Delete(BackendDirectory(backend), recursive: true); } catch { /* retried on next install */ }
        }
        throw last ?? new RouterException($"No llama.cpp build for this machine ({HostArch}).");
    }

    /// <summary>Forgets the installed build so the next install re-detects the hardware.</summary>
    public void ResetRuntime()
    {
        Stop();
        try { File.Delete(ActiveBackendPath); } catch { /* nothing to forget */ }
    }

    private async Task InstallAsync(LocalBackend backend, Action<FileDownloader.Progress>? progress, CancellationToken ct)
    {
        var assets = Assets(backend, HostArch, OperatingSystem.IsWindows())
            ?? throw new RouterException($"No {backend} llama.cpp build for {HostArch}.");
        var directory = BackendDirectory(backend);
        if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        Directory.CreateDirectory(directory);
        foreach (var asset in new[] { assets.Main, assets.CudaRuntime })
        {
            if (asset is null) continue;
            var archive = Path.Combine(Paths.Runtime, asset.Name);
            await RetryAsync(() => FileDownloader.DownloadAsync(asset.Url, archive, asset.Size, progress, ct, asset.Sha256), ct);
            await ExtractAsync(archive, directory, ct);
            try { File.Delete(archive); } catch { /* a leftover archive is only disk space */ }
        }
        var server = FindServer(directory) ?? throw new RouterException("llama-server not in archive");
        // The CUDA runtime unpacks beside the build; the server only loads
        // libraries from its own folder.
        var home = Path.GetDirectoryName(server)!;
        foreach (var library in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories).ToList())
        {
            var name = Path.GetFileName(library);
            var isLibrary = name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) || name.Contains(".so", StringComparison.Ordinal);
            if (!isLibrary || Path.GetDirectoryName(library) == home) continue;
            File.Copy(library, Path.Combine(home, name), overwrite: true);
        }
    }

    private static async Task ExtractAsync(string archive, string directory, CancellationToken ct)
    {
        if (archive.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
        {
            await Task.Run(() => ZipFile.ExtractToDirectory(archive, directory, overwriteFiles: true), ct);
            return;
        }
        var info = new ProcessStartInfo("tar") { UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in new[] { "-xzf", archive, "-C", directory }) info.ArgumentList.Add(argument);
        using var tar = Process.Start(info) ?? throw new RouterException("failed to start tar");
        await tar.WaitForExitAsync(ct);
        if (tar.ExitCode != 0) throw new RouterException($"tar failed ({tar.ExitCode})");
    }

    private ProcessStartInfo ServerStartInfo(string server)
    {
        var home = Path.GetDirectoryName(server)!;
        var info = new ProcessStartInfo(server)
        {
            WorkingDirectory = home,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        if (!OperatingSystem.IsWindows())
        {
            var inherited = Environment.GetEnvironmentVariable("LD_LIBRARY_PATH");
            info.Environment["LD_LIBRARY_PATH"] = string.IsNullOrEmpty(inherited) ? home : home + ":" + inherited;
        }
        return info;
    }

    /// <summary>GPUs the active build can offload to. Empty for CPU or before install.</summary>
    public Task<IReadOnlyList<LocalDevice>> DevicesAsync(CancellationToken ct = default) =>
        ActiveBackend is { } backend ? DevicesAsync(backend, ct) : Task.FromResult<IReadOnlyList<LocalDevice>>([]);

    private async Task<IReadOnlyList<LocalDevice>> DevicesAsync(LocalBackend backend, CancellationToken ct)
    {
        if (FindServer(BackendDirectory(backend)) is not { } server) return [];
        try
        {
            var info = ServerStartInfo(server);
            info.ArgumentList.Add("--list-devices");
            using var process = Process.Start(info);
            if (process is null) return [];
            var output = process.StandardOutput.ReadToEndAsync(ct);
            var errors = process.StandardError.ReadToEndAsync(ct);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(30));
            await process.WaitForExitAsync(timeout.Token);
            return ParseDevices(await output + "\n" + await errors);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return [];
        }
    }

    /// <summary>
    /// Lines look like <c>  CUDA0: NVIDIA GeForce RTX 4070 (12282 MiB, 11000 MiB free)</c>.
    /// Entries without memory are CPU accelerators, and llvmpipe is Vulkan
    /// rendered on the CPU: neither is a GPU.
    /// </summary>
    public static IReadOnlyList<LocalDevice> ParseDevices(string output) =>
        Regex.Matches(output, @"^\s+(\w+): (.+) \((\d+) MiB, \d+ MiB free\)\s*$", RegexOptions.Multiline)
            .Select(match => new LocalDevice(match.Groups[1].Value, match.Groups[2].Value, int.Parse(match.Groups[3].Value)))
            .Where(device => device.MemoryMiB > 0 && !device.Name.Contains("llvmpipe", StringComparison.OrdinalIgnoreCase))
            .ToList();

    /// <summary>
    /// Context to request when the user left it automatic: the model's own
    /// limit, capped so the KV cache stays small next to the weights.
    /// </summary>
    public static int AutomaticContext(LocalModelSpec spec, long memoryBytes) =>
        Math.Min(spec.Context, memoryBytes >= 24L * 1_073_741_824 ? 32_768 : 16_384);

    public static int RequestedContext(LocalModelSpec spec, LocalRuntimeSettings settings, long memoryBytes) =>
        settings.ContextSize > 0 ? settings.ContextSize : AutomaticContext(spec, memoryBytes);

    public static IReadOnlyList<string> LlamaArguments(string modelPath, string alias, int port, int context, LocalRuntimeSettings settings)
    {
        var arguments = new List<string>
        {
            "--model", modelPath,
            "--host", "127.0.0.1",
            "--port", port.ToString(),
            "--ctx-size", context.ToString(),
            "--alias", alias,
            "--jinja",
            // One agent talks to this server; more slots would split the context.
            "--parallel", "1",
            // Weights and KV cache leave memory after this long without a request;
            // the next request reloads them. /health and /props do not count.
            "--sleep-idle-seconds", IdleUnloadSeconds.ToString(),
            "--gpu-layers", string.IsNullOrWhiteSpace(settings.GpuLayers) ? "auto" : settings.GpuLayers.Trim(),
        };
        if (settings.Threads > 0) arguments.AddRange(["--threads", settings.Threads.ToString()]);
        if (settings.BatchSize > 0) arguments.AddRange(["--batch-size", settings.BatchSize.ToString()]);
        if (settings.FlashAttention is "on" or "off") arguments.AddRange(["--flash-attn", settings.FlashAttention]);
        if (!string.IsNullOrWhiteSpace(settings.KvCacheType))
            arguments.AddRange(["--cache-type-k", settings.KvCacheType, "--cache-type-v", settings.KvCacheType]);
        // ponytail: whitespace split, no quoting. Paths with spaces need a real parser.
        arguments.AddRange(settings.ExtraArgs.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return arguments;
    }

    public Uri Start(LocalModelSpec spec, LocalRuntimeSettings? settings = null, long memoryBytes = 0)
    {
        if (_process is { HasExited: false } && _runningModel == spec.Id) return ServerUrl;
        Stop();
        if (!RuntimeInstalled()) throw new RouterException("Install the local runtime first");
        if (!IsInstalled(spec)) throw new RouterException($"Download {spec.Name} first");

        settings ??= new();
        var info = ServerStartInfo(BinaryPath);
        var context = RequestedContext(spec, settings, memoryBytes > 0 ? memoryBytes : LocalHardware.TotalMemoryBytes);
        foreach (var argument in LlamaArguments(ModelPath(spec), spec.Id, Port, context, settings)) info.ArgumentList.Add(argument);

        var process = new Process { StartInfo = info };
        lock (_logLock) _log.Clear();
        // The output must be drained: nobody reading a redirected pipe blocks the server once it fills.
        process.OutputDataReceived += (_, e) => AppendLog(e.Data);
        process.ErrorDataReceived += (_, e) => AppendLog(e.Data);
        if (!process.Start()) throw new RouterException("failed to start llama-server");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        _process = process;
        _runningModel = spec.Id;
        return ServerUrl;
    }

    private void AppendLog(string? line)
    {
        if (string.IsNullOrWhiteSpace(line)) return;
        lock (_logLock)
        {
            _log.Enqueue(line);
            while (_log.Count > 40) _log.Dequeue();
        }
    }

    /// <summary>Last lines the server printed, for an error the user can act on.</summary>
    public string LogTail(int lines = 6)
    {
        lock (_logLock) return string.Join('\n', _log.TakeLast(lines));
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

    /// <summary>
    /// Loading weights takes far longer than binding the port, so this waits
    /// for <c>/health</c> to report ready rather than for any HTTP answer.
    /// </summary>
    public async Task<bool> WaitUntilReadyAsync(int timeoutMs = 180_000, CancellationToken ct = default)
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
            return response.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>The context the running server really allocated, or null when it does not say.</summary>
    public async Task<int?> ServedContextAsync(CancellationToken ct = default) =>
        (await LocalServerProbe.ContextWindowsAsync(ServerUrl.ToString(), ct)).TryGetValue(LocalServerProbe.AnyModel, out var context)
            ? context
            : null;
}
