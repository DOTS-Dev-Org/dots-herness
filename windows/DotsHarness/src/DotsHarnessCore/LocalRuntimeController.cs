// Copyright (c) 2026 DOTS
// Native local model install / serve, then register as a local endpoint.

using PluginRuntime;

namespace DotsHarnessCore;

public sealed class LocalRuntimeController : ObservableObject
{
    private bool _runtimeReady;
    private string? _runtimeVersion = LocalRuntime.LlamaTag;
    private string? _runningModelId;
    private bool _serving;
    private string _status = "Idle";
    private string? _error;
    private int? _servedContext;
    private HashSet<string> _installed = new(StringComparer.Ordinal);
    private Dictionary<string, double> _downloads = new(StringComparer.Ordinal);
    private IReadOnlyList<LocalDevice> _devices = [];

    public LocalRuntime Runtime { get; }
    public RouterController Router { get; }
    public LocalRuntimeSettings Settings { get; }

    public bool RuntimeReady
    {
        get => _runtimeReady;
        private set => SetProperty(ref _runtimeReady, value);
    }

    public string? RuntimeVersion
    {
        get => _runtimeVersion;
        private set => SetProperty(ref _runtimeVersion, value);
    }

    public string? RunningModelId
    {
        get => _runningModelId;
        private set => SetProperty(ref _runningModelId, value);
    }

    public bool Serving
    {
        get => _serving;
        private set => SetProperty(ref _serving, value);
    }

    public string Status
    {
        get => _status;
        set => SetProperty(ref _status, value);
    }

    public string? Error
    {
        get => _error;
        set => SetProperty(ref _error, value);
    }

    /// <summary>Context window of the model being served, as the server reports it.</summary>
    public int? ServedContext
    {
        get => _servedContext;
        private set => SetProperty(ref _servedContext, value);
    }

    public IReadOnlySet<string> Installed => _installed;

    public IReadOnlyDictionary<string, double> Downloads => _downloads;

    public IReadOnlyList<LocalDevice> Devices => _devices;

    /// <summary>Catalog GGUFs plus the files the user imported.</summary>
    public IReadOnlyList<LocalModelSpec> Models =>
        LocalModelCatalog.Models.Concat(Settings.ImportedModels.Select(LocalModelSpec.Imported)).ToList();

    /// <summary>Memory a model must fit in: the largest GPU, or system RAM without one.</summary>
    public long AvailableMemoryBytes =>
        _devices.Count > 0 ? _devices.Max(device => device.MemoryMiB) * 1_048_576L : LocalHardware.TotalMemoryBytes;

    /// <summary>"Vulkan · AMD Radeon RX 7900 XT · 20 GB" once a build is installed, else RAM only.</summary>
    public string HardwareSummary
    {
        get
        {
            var ram = LocalModelCatalog.PrettyBytes(LocalHardware.TotalMemoryBytes) + " RAM";
            if (Runtime.ActiveBackend is not { } backend) return ram;
            var gpu = _devices.OrderByDescending(device => device.MemoryMiB).FirstOrDefault();
            return gpu is null
                ? $"{backend} · {ram}"
                : $"{backend} · {gpu.Name} · {LocalModelCatalog.PrettyBytes(gpu.MemoryMiB * 1_048_576L)} GPU memory · {ram}";
        }
    }

    public bool Fits(LocalModelSpec spec) => spec.MinMemoryGb * 1_073_741_824L <= AvailableMemoryBytes;

    public LocalRuntimeController(SupportPaths paths, RouterController router)
    {
        Runtime = new LocalRuntime(paths);
        Router = router;
        Settings = Runtime.LoadSettings();
        RefreshInstalled();
    }

    public void SaveSettings() => Runtime.SaveSettings(Settings);

    public void RefreshInstalled()
    {
        _installed = Models.Where(Runtime.IsInstalled).Select(m => m.Id).ToHashSet(StringComparer.Ordinal);
        Serving = Runtime.IsServing();
        RunningModelId = Runtime.RunningModelId();
        RuntimeReady = Runtime.RuntimeInstalled();
        if (!Serving) ServedContext = null;
        OnPropertyChanged(nameof(Installed));
        OnPropertyChanged(nameof(Downloads));
    }

    public async Task RefreshDevicesAsync()
    {
        _devices = await Runtime.DevicesAsync();
        OnPropertyChanged(nameof(Devices));
        OnPropertyChanged(nameof(HardwareSummary));
    }

    public async Task InstallRuntimeAsync()
    {
        Error = null;
        Status = "Detecting GPU and downloading llama.cpp…";
        SetDownload("runtime", 0);
        try
        {
            await Runtime.EnsureRuntimeAsync(Settings, progress =>
            {
                // 99%: unpacking and GPU validation still follow the download.
                SetDownload("runtime", progress.Fraction * 0.99);
                Status = $"Downloading llama.cpp {(int)(progress.Fraction * 100)}%";
            });
            await RefreshDevicesAsync();
            RuntimeReady = true;
            SetDownload("runtime", 1);
            Status = $"Local runtime ready ({Runtime.ActiveBackend})";
        }
        catch (Exception ex)
        {
            _downloads.Remove("runtime");
            Error = ex.Message;
            Status = "Runtime install failed";
        }
    }

    /// <summary>Drops the installed build and installs again, re-detecting the GPU.</summary>
    public async Task ReinstallRuntimeAsync()
    {
        Runtime.ResetRuntime();
        RefreshInstalled();
        await InstallRuntimeAsync();
    }

    public async Task DownloadAsync(LocalModelSpec spec)
    {
        Error = null;
        SetDownload(spec.Id, 0);
        Status = $"Downloading {spec.Name}…";
        try
        {
            if (!Runtime.RuntimeInstalled())
            {
                await InstallRuntimeAsync();
                if (Error is { } failure) throw new RouterException(failure);
            }
            await Runtime.DownloadModelAsync(spec, progress =>
            {
                SetDownload(spec.Id, progress.Fraction);
                Status = $"{spec.Name} {(int)(progress.Fraction * 100)}%";
            });
            SetDownload(spec.Id, 1);
            RefreshInstalled();
            Status = $"{spec.Name} downloaded";
        }
        catch (Exception ex)
        {
            Error = ex.Message;
            Status = "Download failed";
        }
    }

    public async Task StartAsync(LocalModelSpec spec)
    {
        Error = null;
        try
        {
            if (!Runtime.RuntimeInstalled())
            {
                await InstallRuntimeAsync();
                if (Error is { } failure) throw new RouterException(failure);
            }
            if (!Runtime.IsInstalled(spec)) throw new RouterException($"Download {spec.Name} first.");
            Status = $"Starting {spec.Name}…";
            if (_devices.Count == 0) await RefreshDevicesAsync();
            _ = Runtime.Start(spec, Settings, AvailableMemoryBytes);
            var ready = await Runtime.WaitUntilReadyAsync();
            RefreshInstalled();
            if (!ready)
            {
                throw new RouterException($"llama-server did not become ready on :{LocalRuntime.DefaultPort}\n{Runtime.LogTail()}");
            }
            // The router must budget against what the server allocated, not what was asked for.
            var context = await Runtime.ServedContextAsync()
                ?? LocalRuntime.RequestedContext(spec, Settings, AvailableMemoryBytes);
            ServedContext = context;
            await Router.PublishLocalNodeAsync(spec.Name, LocalRuntime.NodePrefix, Runtime.ServerUrl.ToString().TrimEnd('/'), spec.Id, context);
            Status = $"Serving {spec.Name} at {Runtime.ServerUrl}";
        }
        catch (Exception ex)
        {
            Error = ex.Message;
            Status = "Start failed";
            Runtime.Stop();
            RefreshInstalled();
        }
    }

    public void Stop()
    {
        Runtime.Stop();
        RefreshInstalled();
        Status = "Local server stopped";
    }

    public void Delete(LocalModelSpec spec)
    {
        if (RunningModelId == spec.Id) Stop();
        if (spec.LocalPath is { } path)
        {
            // An imported file belongs to the user: forget it, never delete it.
            Settings.ImportedModels.Remove(path);
            SaveSettings();
        }
        else
        {
            try { File.Delete(Runtime.ModelPath(spec)); } catch { /* ignore */ }
            try { File.Delete(Runtime.ModelPath(spec) + ".part"); } catch { /* ignore */ }
        }
        _downloads.Remove(spec.Id);
        RefreshInstalled();
        Status = $"Removed {spec.Name}";
    }

    public void ImportModel(string path)
    {
        if (!path.EndsWith(".gguf", StringComparison.OrdinalIgnoreCase) || !File.Exists(path)) return;
        if (Settings.ImportedModels.Contains(path)) return;
        Settings.ImportedModels.Add(path);
        SaveSettings();
        RefreshInstalled();
    }

    private void SetDownload(string id, double fraction)
    {
        _downloads[id] = fraction;
        OnPropertyChanged(nameof(Downloads));
    }
}
