// Copyright (c) 2026 DOTS
// SmolVLM/libmtmd plugin implementation shared by Windows and Linux.

using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using HarnessPluginKit;

namespace VisionPlugin;

public sealed class VisionPlugin : IHarnessPlugin
{
    public PluginManifest Manifest { get; } = new(
        VisionFallbackDefaults.PluginId,
        "Vision fallback",
        "1.0.0",
        PluginPlane.Host,
        Inject: ["support.paths"],
        Description: "Describes images locally with SmolVLM-256M-Instruct and libmtmd.",
        Library: "VisionPlugin.dll");

    public void Apply(IPluginContext ctx)
    {
        if (ctx.PluginDirectory is null)
            throw PluginException.ApplyFailed("Vision plugin directory is unavailable.");
        if (ctx.Get("support.paths") is not PluginSupportPaths paths)
            throw PluginException.MissingService("support.paths");

        var service = new SmolVlmVisionService(ctx.PluginDirectory, paths);
        ctx.Provide(VisionFallbackDefaults.ServiceName, service);
        ctx.Effect(service.Dispose);
    }
}

internal sealed class SmolVlmVisionService : IVisionFallbackService
{
    private const string ModelDirectoryName = "smolvlm-256m-q8";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(30) };
    private readonly string _pluginDirectory;
    private readonly string _modelDirectory;
    private readonly VisionModelManifest _manifest;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private VisionNativeRuntime? _runtime;
    private VisionFallbackState _state;
    private string? _error;
    private bool _disposed;

    public SmolVlmVisionService(string pluginDirectory, PluginSupportPaths paths)
    {
        _pluginDirectory = Path.GetFullPath(pluginDirectory);
        _modelDirectory = Path.Combine(Path.GetFullPath(paths.Models), "vision", ModelDirectoryName);
        _manifest = VisionModelManifest.Load(Path.Combine(_pluginDirectory, "assets", "vision-models.json"));
        _state = _manifest.Files.Count > 0 && _manifest.Files.All(file => ValidFile(Path.Combine(_modelDirectory, file.Name), file))
            ? VisionFallbackState.Preparing
            : VisionFallbackState.ModelMissing;
    }

    public VisionFallbackState State => _state;
    public long ModelBytes => _manifest.TotalBytes > 0 ? _manifest.TotalBytes : VisionFallbackDefaults.ModelBytes;
    public string? Error => _error;

    public async Task PrepareAsync(IProgress<double>? progress = null, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            if (_state == VisionFallbackState.Ready && _runtime is not null) return;
            Directory.CreateDirectory(_modelDirectory);
            _state = VisionFallbackState.Downloading;
            _error = null;
            for (var index = 0; index < _manifest.Files.Count; index++)
            {
                var file = _manifest.Files[index];
                var path = SafeModelPath(file.Name);
                await DownloadModelAsync(
                    file,
                    path,
                    value => progress?.Report((index + value) / _manifest.Files.Count * 0.8),
                    cancellationToken).ConfigureAwait(false);
            }

            _state = VisionFallbackState.Preparing;
            progress?.Report(0.82);
            var oldRuntime = _runtime;
            _runtime = null;
            oldRuntime?.Dispose();
            _runtime = new VisionNativeRuntime(
                SafePluginPath(_manifest.RuntimeLibrary),
                SafeModelPath(_manifest.TextModel),
                SafeModelPath(_manifest.Projector));
            progress?.Report(1);
            _state = VisionFallbackState.Ready;
        }
        catch (OperationCanceledException)
        {
            _state = VisionFallbackState.ModelMissing;
            throw;
        }
        catch (Exception ex)
        {
            _state = VisionFallbackState.Failed;
            _error = ex.Message;
            throw;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<string> DescribeAsync(
        IReadOnlyList<VisionImageInput> images,
        string instruction,
        CancellationToken cancellationToken = default)
    {
        if (images.Count == 0) throw new ArgumentException("At least one image is required.", nameof(images));
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            if (_state != VisionFallbackState.Ready || _runtime is null)
                throw new InvalidOperationException("Vision model is not ready.");

            var descriptions = new List<string>(images.Count);
            foreach (var image in images)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!File.Exists(image.FilePath)) throw new FileNotFoundException("Image file was not found.", image.FilePath);
                var description = _runtime.Describe(image.FilePath, instruction);
                if (!string.IsNullOrWhiteSpace(description)) descriptions.Add(description.Trim());
            }
            return string.Join("\n\n", descriptions);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task DeleteModelAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            _runtime?.Dispose();
            _runtime = null;
            if (Directory.Exists(_modelDirectory)) Directory.Delete(_modelDirectory, recursive: true);
            _state = VisionFallbackState.ModelMissing;
            _error = null;
        }
        finally
        {
            _gate.Release();
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _gate.Wait();
        try
        {
            if (_disposed) return;
            _runtime?.Dispose();
            _runtime = null;
            _state = VisionFallbackState.Unavailable;
            _disposed = true;
        }
        finally
        {
            _gate.Release();
            _gate.Dispose();
        }
    }

    private async Task DownloadModelAsync(
        VisionModelFile file,
        string destination,
        Action<double> report,
        CancellationToken cancellationToken)
    {
        if (ValidFile(destination, file))
        {
            report(1);
            return;
        }
        var url = $"https://huggingface.co/ggml-org/SmolVLM-256M-Instruct-GGUF/resolve/{_manifest.Revision}/{Uri.EscapeDataString(file.Name)}?download=true";
        var part = destination + ".part";
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.UserAgent.ParseAdd("DotsHarness");
        using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        var expected = response.Content.Headers.ContentLength > 0 ? response.Content.Headers.ContentLength.Value : file.Size;
        await using var input = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        await using var output = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None, 128 * 1024, useAsync: true);
        var buffer = new byte[128 * 1024];
        long received = 0;
        int read;
        while ((read = await input.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
        {
            await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
            received += read;
            report(expected > 0 ? Math.Min(1, (double)received / expected) : 0);
        }
        output.Close();
        File.Move(part, destination, overwrite: true);
        if (!ValidFile(destination, file))
        {
            TryDelete(destination);
            throw new InvalidDataException($"Checksum mismatch for {file.Name}.");
        }
    }

    private string SafeModelPath(string name)
    {
        var path = Path.GetFullPath(Path.Combine(_modelDirectory, name));
        var root = _modelDirectory.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Unsafe Vision model path.");
        return path;
    }

    private string SafePluginPath(string name)
    {
        var path = Path.GetFullPath(Path.Combine(_pluginDirectory, name));
        var root = _pluginDirectory.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Unsafe Vision runtime path.");
        return path;
    }

    private static bool ValidFile(string path, VisionModelFile file)
    {
        if (!File.Exists(path)) return false;
        var info = new FileInfo(path);
        if (info.Length != file.Size) return false;
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).Equals(file.Sha256, StringComparison.OrdinalIgnoreCase);
    }

    private void ThrowIfDisposed()
    {
        if (_disposed) throw new ObjectDisposedException(nameof(SmolVlmVisionService));
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }
}

internal sealed class VisionModelManifest
{
    public string Revision { get; set; } = "";
    public string RuntimeLibrary { get; set; } = "";
    public string TextModel { get; set; } = "";
    public string Projector { get; set; } = "";
    public List<VisionModelFile> Files { get; set; } = [];
    public long TotalBytes => Files.Sum(file => file.Size);

    public static VisionModelManifest Load(string path)
    {
        if (!File.Exists(path)) throw new InvalidDataException("Vision model manifest is missing.");
        var manifest = JsonSerializer.Deserialize<VisionModelManifest>(File.ReadAllText(path), new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        if (manifest is null || string.IsNullOrWhiteSpace(manifest.Revision)
            || manifest.Revision.Length != 40 || !manifest.Revision.All(Uri.IsHexDigit)
            || string.IsNullOrWhiteSpace(manifest.RuntimeLibrary)
            || string.IsNullOrWhiteSpace(manifest.TextModel)
            || string.IsNullOrWhiteSpace(manifest.Projector)
            || manifest.Files is null || manifest.Files.Count == 0
            || manifest.Files.Any(file => file is null || file.Size <= 0 || string.IsNullOrEmpty(file.Name) || string.IsNullOrEmpty(file.Sha256) || file.Sha256.Length != 64
                || file.Name.Contains('/') || file.Name.Contains('\\') || file.Name is "." or ".."
                || !file.Sha256.All(Uri.IsHexDigit))
            || manifest.Files.Select(file => file.Name).Distinct(StringComparer.Ordinal).Count() != manifest.Files.Count
            || !manifest.Files.Any(file => string.Equals(file.Name, manifest.TextModel, StringComparison.Ordinal))
            || !manifest.Files.Any(file => string.Equals(file.Name, manifest.Projector, StringComparison.Ordinal)))
        {
            throw new InvalidDataException("Vision model manifest is invalid.");
        }
        return manifest;
    }
}

internal sealed class VisionModelFile
{
    public string Name { get; set; } = "";
    public long Size { get; set; }
    public string Sha256 { get; set; } = "";
}

internal sealed class VisionNativeRuntime : IDisposable
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr CreateFn(IntPtr modelPath, IntPtr projectorPath, int threads);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int DescribeFn(IntPtr context, IntPtr imagePath, IntPtr instruction, out IntPtr output);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void FreeStringFn(IntPtr value);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void DestroyFn(IntPtr context);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr LastErrorFn();

    private IntPtr _library;
    private readonly CreateFn _create;
    private readonly DescribeFn _describe;
    private readonly FreeStringFn _freeString;
    private readonly DestroyFn _destroy;
    private readonly LastErrorFn _lastError;
    private IntPtr _context;

    public VisionNativeRuntime(string libraryPath, string modelPath, string projectorPath)
    {
        if (!NativeLibrary.TryLoad(libraryPath, out _library))
            throw new DllNotFoundException($"Could not load Vision runtime: {libraryPath}");
        try
        {
            _create = Export<CreateFn>("dots_vision_create");
            _describe = Export<DescribeFn>("dots_vision_describe");
            _freeString = Export<FreeStringFn>("dots_vision_free_string");
            _destroy = Export<DestroyFn>("dots_vision_destroy");
            _lastError = Export<LastErrorFn>("dots_vision_last_error");
            var model = Marshal.StringToCoTaskMemUTF8(modelPath);
            var projector = Marshal.StringToCoTaskMemUTF8(projectorPath);
            try { _context = _create(model, projector, Math.Max(1, Environment.ProcessorCount / 2)); }
            finally
            {
                Marshal.FreeCoTaskMem(model);
                Marshal.FreeCoTaskMem(projector);
            }
            if (_context == IntPtr.Zero) throw new InvalidOperationException(ErrorMessage("Vision runtime initialization failed."));
        }
        catch
        {
            NativeLibrary.Free(_library);
            throw;
        }
    }

    public string Describe(string imagePath, string instruction)
    {
        var image = Marshal.StringToCoTaskMemUTF8(imagePath);
        var prompt = Marshal.StringToCoTaskMemUTF8(instruction);
        try
        {
            var result = _describe(_context, image, prompt, out var output);
            if (result != 0) throw new InvalidOperationException(ErrorMessage("Vision runtime failed to describe image."));
            try { return Marshal.PtrToStringUTF8(output) ?? ""; }
            finally { if (output != IntPtr.Zero) _freeString(output); }
        }
        finally
        {
            Marshal.FreeCoTaskMem(image);
            Marshal.FreeCoTaskMem(prompt);
        }
    }

    public void Dispose()
    {
        if (_context != IntPtr.Zero)
        {
            _destroy(_context);
            _context = IntPtr.Zero;
        }
        if (_library != IntPtr.Zero)
        {
            NativeLibrary.Free(_library);
            _library = IntPtr.Zero;
        }
    }

    private T Export<T>(string name) where T : Delegate =>
        Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(_library, name));

    private string ErrorMessage(string fallback)
    {
        var pointer = _lastError();
        var message = pointer == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(pointer);
        return string.IsNullOrWhiteSpace(message) ? fallback : message;
    }
}
