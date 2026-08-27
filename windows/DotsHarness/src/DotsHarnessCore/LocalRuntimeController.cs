// Copyright (c) 2026 DOTS
// Native local model install / serve, then register as a local endpoint.

using PluginRuntime;

namespace DotsHarnessCore;

public sealed class LocalRuntimeController : ObservableObject
{
    private bool _runtimeReady;
    private string? _runtimeVersion;
    private string? _runningModelId;
    private bool _serving;
    private string _status = "Idle";
    private string? _error;
    private HashSet<string> _installed = new(StringComparer.Ordinal);
    private Dictionary<string, double> _downloads = new(StringComparer.Ordinal);

    public LocalRuntime Runtime { get; }
    public RouterController Router { get; }

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

    public IReadOnlySet<string> Installed => _installed;

    public IReadOnlyDictionary<string, double> Downloads => _downloads;

    public LocalRuntimeController(SupportPaths paths, RouterController router)
    {
        Runtime = new LocalRuntime(paths);
        Router = router;
        RefreshInstalled();
        RuntimeReady = Runtime.RuntimeInstalled();
    }

    public void RefreshInstalled()
    {
        _installed = LocalModelCatalog.Models.Where(Runtime.IsInstalled).Select(m => m.Id).ToHashSet(StringComparer.Ordinal);
        Serving = Runtime.IsServing();
        RunningModelId = Runtime.RunningModelId();
        RuntimeReady = Runtime.RuntimeInstalled();
        OnPropertyChanged(nameof(Installed));
        OnPropertyChanged(nameof(Downloads));
    }

    public async Task InstallRuntimeAsync()
    {
        Error = null;
        Status = "Downloading llama.cpp…";
        SetDownload("runtime", 0);
        try
        {
            await Runtime.EnsureRuntimeAsync(progress =>
            {
                SetDownload("runtime", progress.Fraction);
                Status = $"Downloading llama.cpp {(int)(progress.Fraction * 100)}%";
            });
            RuntimeReady = true;
            SetDownload("runtime", 1);
            Status = "Local runtime ready";
        }
        catch (Exception ex)
        {
            Error = ex.Message;
            Status = "Runtime install failed";
        }
    }

    public async Task DownloadAsync(LocalModelSpec spec)
    {
        Error = null;
        SetDownload(spec.Id, 0);
        Status = $"Downloading {spec.Name}…";
        try
        {
            if (!Runtime.RuntimeInstalled()) await InstallRuntimeAsync();
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
            if (!Runtime.RuntimeInstalled()) throw new RouterException("Install the local runtime first.");
            if (!Runtime.IsInstalled(spec)) throw new RouterException($"Download {spec.Name} first.");
            Status = $"Starting {spec.Name}…";
            _ = Runtime.Start(spec);
            var ready = await Runtime.WaitUntilReadyAsync();
            RefreshInstalled();
            if (!ready) throw new RouterException($"llama-server did not become ready on :{LocalRuntime.DefaultPort}");
            await PublishNodeAsync(spec);
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
        try { File.Delete(Runtime.ModelPath(spec)); } catch { /* ignore */ }
        try { File.Delete(Runtime.ModelPath(spec) + ".part"); } catch { /* ignore */ }
        _downloads.Remove(spec.Id);
        RefreshInstalled();
        Status = $"Removed {spec.Name}";
    }

    private async Task PublishNodeAsync(LocalModelSpec spec)
    {
        Router.CustomName = spec.Name;
        Router.CustomPrefix = LocalRuntime.NodePrefix;
        Router.CustomBaseUrl = Runtime.ServerUrl.ToString().TrimEnd('/');
        Router.CustomApiKey = "";
        Router.CustomKind = CustomApiKind.OpenaiCompatible;
        Router.CustomApiType = CustomOpenAiApiType.Chat;
        var existing = Router.Nodes.FirstOrDefault(n =>
            n.Prefix == LocalRuntime.NodePrefix || n.BaseUrl.Contains($":{LocalRuntime.DefaultPort}"));
        if (existing is not null) await Router.ConnectExistingNodeAsync(existing);
        else await Router.CreateCustomNodeAsync(registerKey: true);
    }

    private void SetDownload(string id, double fraction)
    {
        _downloads[id] = fraction;
        OnPropertyChanged(nameof(Downloads));
    }
}
