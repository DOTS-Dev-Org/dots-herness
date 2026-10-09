// Copyright (c) 2026 DOTS
// Finds local OpenAI-compatible servers the user already runs, and reads the
// context window they actually serve.

using System.Text.Json.Nodes;
using System.Text;
using System.Text.Json;

namespace DotsHarnessCore;

public sealed record LocalServer(string Name, string BaseUrl, int ModelCount);

public static class LocalServerDiscovery
{
    /// <summary>
    /// Default ports of the common local runtimes. Port 8080 is shared by
    /// llama.cpp's <c>llama-server</c> and engines built on it (Strata, …).
    /// </summary>
    public static readonly IReadOnlyList<(string Name, int Port)> Candidates =
    [
        ("Ollama", 11434),
        ("LM Studio", 1234),
        ("llama.cpp", 8080),
        ("Jan", 1337),
        ("KoboldCpp", 5001),
        ("vLLM", 8000),
    ];

    public static async Task<IReadOnlyList<LocalServer>> ScanAsync(CancellationToken ct = default)
    {
        var found = await Task.WhenAll(Candidates.Select(async candidate =>
        {
            var baseUrl = $"http://127.0.0.1:{candidate.Port}/v1";
            // Only an OpenAI-shaped /models answer counts; any other service on
            // the port (a dev server on 8080, say) is ignored.
            return (await LocalServerProbe.JsonAsync(baseUrl + "/models", ct))?["data"] is JsonArray data
                ? new LocalServer(candidate.Name, baseUrl, data.Count)
                : null;
        }));
        return found.OfType<LocalServer>().ToList();
    }
}

public static class LocalServerProbe
{
    /// <summary>Key for a context that applies to every model of a single-model server.</summary>
    public const string AnyModel = "*";

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMilliseconds(1500) };

    /// <summary>
    /// Context windows by model id, as the server is serving them right now.
    /// Empty when the server exposes none of the known introspection endpoints.
    /// </summary>
    public static Task<Dictionary<string, int>> ContextWindowsAsync(string baseUrl, CancellationToken ct = default) =>
        ContextWindowsAsync(baseUrl, [], ct);

    public static async Task<Dictionary<string, int>> ContextWindowsAsync(
        string baseUrl,
        IEnumerable<string> modelIds,
        CancellationToken ct = default)
    {
        var root = baseUrl.TrimEnd('/');
        if (root.EndsWith("/v1", StringComparison.Ordinal)) root = root[..^3];

        // llama.cpp llama-server (and forks): one model, one real n_ctx.
        if ((await JsonAsync(root + "/props", ct))?["default_generation_settings"]?["n_ctx"] is { } served
            && Int(served) is > 0 and var context)
        {
            return new(StringComparer.Ordinal) { [AnyModel] = context };
        }
        // LM Studio: loaded context when a model is in memory, else its maximum.
        if ((await JsonAsync(root + "/api/v0/models", ct))?["data"] is JsonArray studio)
        {
            var known = Contexts(studio, "id", "loaded_context_length", "max_context_length");
            if (known.Count > 0) return known;
        }
        // Ollama: only loaded models report the context they run with. Its
        // OpenAI endpoint cannot change it, so an unloaded model stays unknown.
        var result = (await JsonAsync(root + "/api/ps", ct))?["models"] is JsonArray ollama
            ? Contexts(ollama, "name", "context_length")
            : new Dictionary<string, int>(StringComparer.Ordinal);

        // Ollama's model catalog omits this metadata. `/api/show` returns the
        // model's architecture context; keep `/api/ps` values above when the
        // runtime has a smaller active context.
        if ((await JsonAsync(root + "/api/tags", ct))?["models"] is not JsonArray) return result;
        var alreadyRunning = new HashSet<string>(result.Keys, StringComparer.Ordinal);
        foreach (var id in modelIds.Where(value => !string.IsNullOrWhiteSpace(value)).Distinct(StringComparer.Ordinal))
        {
            if (alreadyRunning.Contains(id)) continue;
            try
            {
                using var content = new StringContent(JsonSerializer.Serialize(new { model = id }), Encoding.UTF8, "application/json");
                using var response = await Http.PostAsync(root + "/api/show", content, ct);
                if (!response.IsSuccessStatusCode) continue;
                var text = await response.Content.ReadAsStringAsync(ct);
                var shown = JsonNode.Parse(text);
                var shownContext = ContextWindowMetadata.Read(shown?["model_info"]);
                if (shownContext > 0) result[id] = shownContext;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch { }
        }
        return result;
    }

    public static Dictionary<string, int> Contexts(JsonArray rows, string idKey, params string[] contextKeys)
    {
        var result = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            if (row is not JsonObject item || item[idKey] is not JsonValue idValue || !idValue.TryGetValue<string>(out var id)) continue;
            var context = contextKeys.Select(key => Int(item[key])).FirstOrDefault(value => value > 0);
            if (context > 0) result[id] = context;
        }
        return result;
    }

    private static int Int(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<long>(out var number) && number is > 0 and <= int.MaxValue ? (int)number : 0;

    internal static async Task<JsonNode?> JsonAsync(string url, CancellationToken ct)
    {
        try
        {
            using var response = await Http.GetAsync(url, ct);
            return response.IsSuccessStatusCode ? JsonNode.Parse(await response.Content.ReadAsStringAsync(ct)) : null;
        }
        catch
        {
            return null;
        }
    }
}
