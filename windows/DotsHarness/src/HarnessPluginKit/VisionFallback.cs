// Copyright (c) 2026 DOTS
// In-process vision fallback contract shared by the Windows and Linux hosts.

namespace HarnessPluginKit;

public enum VisionFallbackState
{
    Unavailable,
    ModelMissing,
    Downloading,
    Preparing,
    Ready,
    Failed,
}

public sealed record VisionImageInput(string FilePath, string Name, string MimeType);

public sealed record PluginSupportPaths(string Root, string Plugins, string Models, string Runtime);

public static class VisionFallbackDefaults
{
    public const string PluginId = "dots.vision-fallback";
    public const string ServiceName = "vision.fallback";
    public const string InstallerServiceName = "vision.installer";
    public const long ModelBytes = 279_000_000;
}

public interface IVisionFallbackService : IDisposable
{
    VisionFallbackState State { get; }
    long ModelBytes { get; }
    string? Error { get; }

    Task PrepareAsync(IProgress<double>? progress = null, CancellationToken cancellationToken = default);
    Task<string> DescribeAsync(
        IReadOnlyList<VisionImageInput> images,
        string instruction,
        CancellationToken cancellationToken = default);
    Task DeleteModelAsync(CancellationToken cancellationToken = default);
}

public interface IVisionFallbackInstaller
{
    Task<IVisionFallbackService?> InstallAsync(CancellationToken cancellationToken = default);
}

public static class VisionProviderCapability
{
    private static readonly int[] UnsupportedStatusCodes = [400, 404, 405, 415, 422];
    private static readonly string[] PositiveTerms =
    [
        "image",
        "multimodal",
        "image_url",
        "image input",
        "image inputs",
        "image modality",
        "vision",
    ];
    private static readonly string[] UnsupportedTerms =
    [
        "does not support",
        "doesn't support",
        "not supported",
        "unsupported",
        "not available",
        "unavailable",
        "not implemented",
        "cannot process",
        "can't process",
        "disabled",
    ];
    private static readonly string[] InvalidImageTerms =
    [
        "invalid image",
        "malformed image",
        "decode image",
        "image decode",
        "image decoding failed",
        "failed to decode image",
        "corrupt image",
        "unsafe image",
        "unsupported image format",
    ];

    public static bool IsImageInputUnsupported(string message, int? statusCode)
    {
        if (statusCode is not { } status || !UnsupportedStatusCodes.Contains(status)) return false;
        var text = message.Trim().ToLowerInvariant();
        var capability = PositiveTerms.Any(text.Contains);
        var unsupported = UnsupportedTerms.Any(text.Contains)
            || text.Contains("no image support")
            || text.Contains("not multimodal")
            || text.Contains("no vision support")
            || text.Contains("image support unavailable");
        var missingModel = text.Contains("model")
            && (text.Contains("not found") || text.Contains("not available")
                || text.Contains("unavailable") || text.Contains("does not exist"));
        return capability && unsupported && !missingModel && !InvalidImageTerms.Any(text.Contains);
    }
}
