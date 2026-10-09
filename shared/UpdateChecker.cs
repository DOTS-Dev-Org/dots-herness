// Copyright (c) 2026 DOTS
// Multiplatform version checking, release discovery and update management for Windows and Linux.

using System;
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
    public const string DefaultCheckEndpoint = "https://dots.net.tr/harness/check-update";
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
