// Copyright (c) 2026 DOTS
// Remote model catalog: efforts, context windows, model ids, and the Claude client
// user-agent published by the backend. Mirrors macOS ProviderRegistry.refreshRemote.
// Bundled tables stay the fallback; any failure keeps the cached or built-in values.

using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace DotsHarnessCore;

public static class RemoteModelCatalog
{
    public const string Url = "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev/assets/catalog/models.json";
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private static readonly HttpClient Http = new() { Timeout = Timeout };
    private static readonly ConcurrentDictionary<string, List<string>> ModelIds = new(StringComparer.OrdinalIgnoreCase);

    public sealed record ModelEntry(string Id, string? Name, List<string>? Efforts, string? Tier, int? ContextWindow, bool? Fast);

    /// A catalog entry carries model lists and the client user-agent only. Endpoints,
    /// OAuth and credential headers stay bundled, so a tampered catalog cannot redirect a token.
    public sealed record ProviderEntry(string Id, List<ModelEntry>? Models, string? UserAgent);

    public static List<ProviderEntry>? Parse(ReadOnlySpan<byte> json)
    {
        try
        {
            return JsonSerializer.Deserialize<List<ProviderEntry>>(json, JsonOptions);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// Applies a catalog over the built-in tables. A model without published efforts keeps
    /// its built-in levels, and an empty model list leaves the provider's ids untouched.
    public static void Apply(IEnumerable<ProviderEntry> entries)
    {
        foreach (var entry in entries)
        {
            var published = (entry.Models ?? []).Where(model => !string.IsNullOrWhiteSpace(model.Id)).ToList();
            if (published.Count > 0)
            {
                ModelIds[entry.Id] = published.Select(model => model.Id).ToList();
            }
            foreach (var model in published)
            {
                if (model.Efforts is { Count: > 0 } efforts) NativeEffortCatalog.SetOverlay(model.Id, efforts);
                if (model.ContextWindow is > 0 and var window) RouterCatalog.SetContextWindowOverlay(entry.Id, model.Id, window);
            }
            if (entry.Id == "claude" && !string.IsNullOrWhiteSpace(entry.UserAgent))
            {
                ClaudeOAuthHeaders.UserAgent = entry.UserAgent;
            }
        }
    }

    /// Model ids the catalog publishes for a provider, used when live discovery has none yet.
    public static IReadOnlyList<string> ModelIdsFor(string? provider) =>
        string.IsNullOrWhiteSpace(provider) || !ModelIds.TryGetValue(provider, out var ids) ? [] : ids;

    /// Loads the last successfully fetched catalog so offline starts keep published models.
    public static void LoadCache(string cachePath)
    {
        try
        {
            if (!File.Exists(cachePath)) return;
            var entries = Parse(File.ReadAllBytes(cachePath));
            if (entries is not null) Apply(entries);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    /// Fetches the catalog, caches the raw bytes atomically, and applies them. Returns false and
    /// changes nothing on any failure, so a refresh never replaces working data with partial data.
    public static async Task<bool> RefreshAsync(string cachePath, CancellationToken ct = default)
    {
        byte[] data;
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, Url);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
            deadline.CancelAfter(Timeout);
            using var response = await Http.SendAsync(request, deadline.Token);
            if (response.StatusCode != HttpStatusCode.OK) return false;
            data = await response.Content.ReadAsByteArrayAsync(deadline.Token);
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or OperationCanceledException)
        {
            return false;
        }

        var entries = Parse(data);
        if (entries is null) return false;
        try
        {
            var directory = Path.GetDirectoryName(cachePath);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
            var temporary = cachePath + ".tmp";
            File.WriteAllBytes(temporary, data);
            File.Move(temporary, cachePath, overwrite: true);
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }

        Apply(entries);
        return true;
    }
}
