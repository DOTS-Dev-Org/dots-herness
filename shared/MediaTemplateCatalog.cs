// Copyright (c) 2026 DOTS

using System.Globalization;
using System.Net.Http;
using System.Text.Json;

namespace DotsHarnessCore;

public sealed class MediaTemplateCatalogManifest
{
    public int Version { get; set; }
    public List<MediaTemplateCatalogItem> Templates { get; set; } = [];
}

public sealed class MediaTemplateCatalogItem
{
    public string Id { get; set; } = "";
    public string Category { get; set; } = "social";
    public string PresetId { get; set; } = "square";
    public Dictionary<string, string> Titles { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public MediaCanvas Canvas { get; set; } = new();
}

/// <summary>Fetches the public media template catalog and keeps its last good copy for offline use.</summary>
public static class MediaTemplateCatalogClient
{
    public const string ManifestUrl = MarketplaceSession.DefaultApiBase + "assets/media-templates/manifest.json";
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromSeconds(8) };

    public static async Task<IReadOnlyList<MediaTemplate>> LoadAsync(string cachePath, string language, CancellationToken cancellationToken = default)
    {
        MediaTemplateCatalogManifest? manifest = null;
        try
        {
            var json = await Client.GetStringAsync(ManifestUrl, cancellationToken).ConfigureAwait(false);
            manifest = JsonSerializer.Deserialize<MediaTemplateCatalogManifest>(json, MediaStudioJson.Options);
            if (IsUsable(manifest))
            {
                var directory = Path.GetDirectoryName(cachePath);
                if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
                await File.WriteAllTextAsync(cachePath, json, cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            // A cached catalog keeps Templates available when the user is offline.
        }

        if (!IsUsable(manifest))
        {
            try
            {
                var json = await File.ReadAllTextAsync(cachePath, cancellationToken).ConfigureAwait(false);
                manifest = JsonSerializer.Deserialize<MediaTemplateCatalogManifest>(json, MediaStudioJson.Options);
            }
            catch (Exception) when (!cancellationToken.IsCancellationRequested)
            {
                return [];
            }
        }

        if (!IsUsable(manifest)) return [];
        var culture = string.IsNullOrWhiteSpace(language) ? CultureInfo.CurrentUICulture.TwoLetterISOLanguageName : language;
        return manifest!.Templates.Select(item =>
        {
            var title = item.Titles.GetValueOrDefault(culture)
                ?? item.Titles.GetValueOrDefault(culture.Split('-', '_')[0])
                ?? item.Titles.GetValueOrDefault("en")
                ?? item.Id;
            var templateCanvas = item.Canvas.Clone();
            return new MediaTemplate(item.Id, item.Category, () => templateCanvas.Clone(), title);
        }).ToList();
    }

    private static bool IsUsable(MediaTemplateCatalogManifest? manifest) =>
        manifest is { Version: 1, Templates.Count: > 0 } && manifest.Templates.All(item =>
            !string.IsNullOrWhiteSpace(item.Id) && item.Canvas.Width > 0 && item.Canvas.Height > 0);
}
