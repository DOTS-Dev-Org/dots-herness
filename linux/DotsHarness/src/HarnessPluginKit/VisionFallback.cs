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

public static class VisionProviderCapability
{
    private static readonly int[] UnsupportedStatusCodes = [400, 404, 405, 415, 422];
    private static readonly string[] PositiveTerms =
    [
        "does not support",
        "doesn't support",
        "not supported",
        "unsupported",
        "multimodal",
        "image_url",
        "image input",
        "image inputs",
        "image modality",
        "vision",
    ];
    private static readonly string[] InvalidImageTerms =
    [
        "invalid image",
        "malformed image",
        "decode image",
        "image decode",
        "corrupt image",
        "unsafe image",
    ];

    public static bool IsImageInputUnsupported(string message, int? statusCode)
    {
        if (statusCode is not { } status || !UnsupportedStatusCodes.Contains(status)) return false;
        var text = message.Trim().ToLowerInvariant();
        return PositiveTerms.Any(text.Contains) && !InvalidImageTerms.Any(text.Contains);
    }
}
