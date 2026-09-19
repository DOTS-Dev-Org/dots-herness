using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using HarnessPluginKit;
using JsonNodeValue = System.Text.Json.Nodes.JsonValue;

namespace DotsHarnessCore;

public enum NativeMediaKind { Image, Video, Audio }

public sealed record MediaRequest(NativeMediaKind Kind, string Prompt)
{
    public static bool TryParse(string text, out MediaRequest request)
    {
        request = new MediaRequest(NativeMediaKind.Image, "");
        var parts = text.Trim().Split([' ', '\t', '\r', '\n'], 2, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0 || !parts[0].StartsWith('/')) return false;
        var kind = parts[0][1..].ToLowerInvariant() switch
        {
            "imagegen" or "image" or "img" => NativeMediaKind.Image,
            _ => (NativeMediaKind?)null,
        };
        if (kind is null) return false;
        request = new MediaRequest(kind.Value, parts.Length == 1 ? "" : parts[1].Trim());
        return true;
    }
}

public sealed record NativeImageGeneration(
    ProviderImageOutput Output,
    string Provider,
    string Model,
    string? FallbackFrom = null);

public sealed class NativeImageGenerationException : Exception
{
    public bool Unsupported { get; }
    public ProviderImageFailure? Failure { get; }

    private NativeImageGenerationException(string message, bool unsupported, ProviderImageFailure? failure)
        : base(message)
    {
        Unsupported = unsupported;
        Failure = failure;
    }

    public static NativeImageGenerationException UnsupportedResult(string message) => new(message, true, null);
    public static NativeImageGenerationException Failed(ProviderImageFailure failure) => new(failure.Message, false, failure);
}

public static class NativeProviderImageAdapters
{
    public static void Register(ProviderImageAdapterRegistry registry)
    {
        registry.Register(new OpenAIResponsesImageAdapter(), "host", PluginTrust.System);
        registry.Register(new GeminiNativeImageAdapter(), "host", PluginTrust.System);
        registry.Register(new DirectImageAPIAdapter(), "host", PluginTrust.System);
    }
}

internal static class ProviderImageAdapterSupport
{
    public static Uri Endpoint(string baseUrl, string path)
    {
        if (!Uri.TryCreate(baseUrl, UriKind.Absolute, out var baseUri) || baseUri.Host.Length == 0 || baseUri.Scheme is not ("http" or "https"))
            throw new InvalidOperationException("Enter a valid HTTP or HTTPS endpoint.");
        var parts = new[] { baseUri.AbsolutePath.Trim('/'), path.Trim('/') }.Where(part => part.Length > 0);
        var builder = new UriBuilder(baseUri) { Path = "/" + string.Join("/", parts), Query = "", Fragment = "" };
        return builder.Uri;
    }

    public static byte[] Decode(string encoded)
    {
        var value = encoded.Split(',', 2).Last().Where(character => !char.IsWhiteSpace(character)).ToArray();
        return Convert.FromBase64String(new string(value));
    }

    public static ProviderImageResult ClassifyFailure(byte[] data, int status)
    {
        var message = Message(data, status);
        var lower = message.ToLowerInvariant();
        if (IsSafety(lower)) return new ProviderImageResult.Failed(new ProviderImageFailure(ProviderImageFailureKind.Safety, message));
        if (status is 401 or 403) return new ProviderImageResult.Failed(new ProviderImageFailure(ProviderImageFailureKind.Auth, message));
        if (status == 429) return new ProviderImageResult.Failed(new ProviderImageFailure(ProviderImageFailureKind.RateLimit, message));
        if (status >= 500) return new ProviderImageResult.Failed(new ProviderImageFailure(ProviderImageFailureKind.Server, message));
        if (status is 404 or 405 || IsCapability(lower)) return new ProviderImageResult.Unsupported(message);
        return new ProviderImageResult.Failed(new ProviderImageFailure(ProviderImageFailureKind.Other, message));
    }

    public static ProviderImageResult InvalidOutput(string message) =>
        new ProviderImageResult.Failed(new ProviderImageFailure(ProviderImageFailureKind.InvalidOutput, message));

    public static string Message(byte[] data, int status)
    {
        try
        {
            var root = JsonNode.Parse(data);
            return String(root?["error"]?["message"])
                ?? String(root?["message"])
                ?? $"Image provider returned HTTP {status}.";
        }
        catch
        {
            return $"Image provider returned HTTP {status}.";
        }
    }

    public static string? String(JsonNode? node)
    {
        try { return node?.GetValue<string>(); } catch { return null; }
    }

    public static string? OpenAIImageResult(byte[] data)
    {
        var text = Encoding.UTF8.GetString(data);
        var trimmed = text.TrimStart();
        if (trimmed.StartsWith('{') || trimmed.StartsWith('[')) return FindOpenAI(JsonNode.Parse(text));
        string? result = null;
        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.Trim();
            if (!line.StartsWith("data:", StringComparison.OrdinalIgnoreCase)) continue;
            var payload = line[5..].Trim();
            if (payload.Length == 0 || payload == "[DONE]") continue;
            try { result = FindOpenAI(JsonNode.Parse(payload)) ?? result; } catch (JsonException) { }
        }
        return result;
    }

    private static string? FindOpenAI(JsonNode? node)
    {
        if (node is JsonArray array)
        {
            foreach (var item in array)
                if (FindOpenAI(item) is { } result) return result;
            return null;
        }
        if (node is not JsonObject obj) return null;
        var type = String(obj["type"]);
        if (type?.Contains("image_generation_call", StringComparison.OrdinalIgnoreCase) == true
            && String(obj["result"]) is { } direct) return direct;
        foreach (var key in new[] { "response", "item", "image_generation_call", "output", "data" })
            if (FindOpenAI(obj[key]) is { } nested) return nested;
        return null;
    }

    public static ProviderImageOutput? GeminiImage(byte[] data)
    {
        try { return FindGemini(JsonNode.Parse(data)); } catch (JsonException) { return null; }
    }

    private static ProviderImageOutput? FindGemini(JsonNode? node)
    {
        if (node is JsonArray array)
        {
            foreach (var item in array)
                if (FindGemini(item) is { } result) return result;
            return null;
        }
        if (node is not JsonObject obj) return null;
        var inline = obj["inlineData"] as JsonObject ?? obj["inline_data"] as JsonObject;
        if (inline is not null && String(inline["data"]) is { } encoded)
        {
            try { return new ProviderImageOutput(Decode(encoded), String(inline["mimeType"]) ?? String(inline["mime_type"]) ?? "image/png"); }
            catch (FormatException) { return null; }
        }
        foreach (var item in obj.Select(pair => pair.Value))
            if (FindGemini(item) is { } nested) return nested;
        return null;
    }

    private static bool IsSafety(string value) =>
        new[] { "safety", "policy", "content policy", "blocked", "prohibited", "responsible" }.Any(value.Contains);

    private static bool IsCapability(string value) =>
        new[] { "image_generation", "image generation", "responsemodalities", "response modalities", "inline data", "unsupported", "not supported", "does not support", "unknown tool", "invalid tool", "not available" }.Any(value.Contains);
}

public sealed class OpenAIResponsesImageAdapter : IProviderImageAdapter
{
    public string Id => "openai.responses.image";

    public bool Matches(ProviderImageRoute route) =>
        route.Api == nameof(NativeProviderProtocol.ChatGpt)
        || route.ProviderId.Equals("openai", StringComparison.OrdinalIgnoreCase);

    public ProviderImageRequest PrepareImageRequest(string prompt, string model, ProviderImageRoute route)
    {
        var body = new JsonObject
        {
            ["model"] = model,
            ["instructions"] = route.Api == nameof(NativeProviderProtocol.ChatGpt)
                ? "You are Codex, based on GPT-5. You are running as a coding agent in the Codex CLI on a user's computer."
                : "You are a helpful assistant.",
            ["input"] = new JsonArray(new JsonObject
            {
                ["role"] = "user",
                ["content"] = new JsonArray(new JsonObject { ["type"] = "input_text", ["text"] = prompt }),
            }),
            ["tools"] = new JsonArray(new JsonObject { ["type"] = "image_generation" }),
            ["store"] = false,
            ["stream"] = true,
        };
        return new ProviderImageRequest(
            ProviderImageAdapterSupport.Endpoint(route.BaseUrl, "responses"),
            Encoding.UTF8.GetBytes(body.ToJsonString()),
            new Dictionary<string, string> { ["Content-Type"] = "application/json", ["Accept"] = "text/event-stream" });
    }

    public ProviderImageResult ParseImageResponse(byte[] data, int status, IReadOnlyDictionary<string, string> headers)
    {
        if (status is < 200 or >= 300) return ProviderImageAdapterSupport.ClassifyFailure(data, status);
        try
        {
            var encoded = ProviderImageAdapterSupport.OpenAIImageResult(data);
            return encoded is null
                ? ProviderImageAdapterSupport.InvalidOutput("Image provider returned no image output.")
                : new ProviderImageResult.Generated(new ProviderImageOutput(ProviderImageAdapterSupport.Decode(encoded)));
        }
        catch (FormatException) { return ProviderImageAdapterSupport.InvalidOutput("Image provider returned invalid image data."); }
        catch (JsonException) { return ProviderImageAdapterSupport.InvalidOutput("Image provider returned invalid image data."); }
    }
}

public sealed class GeminiNativeImageAdapter : IProviderImageAdapter
{
    public string Id => "gemini.native.image";

    public bool Matches(ProviderImageRoute route) => route.ProviderId.Equals("gemini", StringComparison.OrdinalIgnoreCase);

    public ProviderImageRequest PrepareImageRequest(string prompt, string model, ProviderImageRoute route)
    {
        if (!Uri.TryCreate(route.BaseUrl, UriKind.Absolute, out var baseUri) || baseUri.Host.Length == 0 || baseUri.Scheme is not ("http" or "https"))
            throw new InvalidOperationException("Enter a valid HTTP or HTTPS endpoint.");
        var basePath = baseUri.AbsolutePath.Trim('/');
        if (basePath.EndsWith("/openai", StringComparison.OrdinalIgnoreCase)) basePath = basePath[..^6].TrimEnd('/');
        var builder = new UriBuilder(baseUri)
        {
            Path = "/" + string.Join('/', new[] { basePath, $"models/{Uri.EscapeDataString(model)}:generateContent" }.Where(part => part.Length > 0)),
            Query = "",
            Fragment = "",
        };
        var body = new JsonObject
        {
            ["contents"] = new JsonArray(new JsonObject { ["role"] = "user", ["parts"] = new JsonArray(new JsonObject { ["text"] = prompt }) }),
            ["generationConfig"] = new JsonObject { ["responseModalities"] = new JsonArray(JsonNodeValue.Create("TEXT"), JsonNodeValue.Create("IMAGE")) },
        };
        return new ProviderImageRequest(
            builder.Uri,
            Encoding.UTF8.GetBytes(body.ToJsonString()),
            new Dictionary<string, string> { ["Content-Type"] = "application/json", ["Accept"] = "application/json" },
            ProviderImageAuthentication.RawHeader,
            "x-goog-api-key");
    }

    public ProviderImageResult ParseImageResponse(byte[] data, int status, IReadOnlyDictionary<string, string> headers)
    {
        if (status is < 200 or >= 300) return ProviderImageAdapterSupport.ClassifyFailure(data, status);
        return ProviderImageAdapterSupport.GeminiImage(data) is { } output
            ? new ProviderImageResult.Generated(output)
            : ProviderImageAdapterSupport.InvalidOutput("Image provider returned no image output.");
    }
}

public sealed class DirectImageAPIAdapter : IProviderImageAdapter
{
    public string Id => "openai.images.fallback";
    public bool IsFallbackOnly => true;
    public bool Matches(ProviderImageRoute route) => route.ProviderId.Equals("openai", StringComparison.OrdinalIgnoreCase);

    public ProviderImageRequest PrepareImageRequest(string prompt, string model, ProviderImageRoute route)
    {
        var body = new JsonObject
        {
            ["model"] = "gpt-image-1.5",
            ["prompt"] = prompt,
            ["n"] = 1,
            ["size"] = "1024x1024",
        };
        return new ProviderImageRequest(
            ProviderImageAdapterSupport.Endpoint(route.BaseUrl, "images/generations"),
            Encoding.UTF8.GetBytes(body.ToJsonString()),
            new Dictionary<string, string> { ["Content-Type"] = "application/json", ["Accept"] = "application/json" });
    }

    public ProviderImageResult ParseImageResponse(byte[] data, int status, IReadOnlyDictionary<string, string> headers)
    {
        if (status is < 200 or >= 300) return ProviderImageAdapterSupport.ClassifyFailure(data, status);
        try
        {
            var root = JsonNode.Parse(data)?.AsObject();
            var encoded = ProviderImageAdapterSupport.String(root?["data"]?[0]?["b64_json"]);
            return encoded is null
                ? ProviderImageAdapterSupport.InvalidOutput("Image provider returned no image output.")
                : new ProviderImageResult.Generated(new ProviderImageOutput(ProviderImageAdapterSupport.Decode(encoded)));
        }
        catch (Exception) { return ProviderImageAdapterSupport.InvalidOutput("Image provider returned invalid image data."); }
    }
}

public sealed class NativeProviderImageRouter
{
    private readonly NativeProviderStore _store;
    private readonly ProviderImageAdapterRegistry _adapters;
    private readonly HttpClient _http;

    public NativeProviderImageRouter(NativeProviderStore store, ProviderImageAdapterRegistry adapters, HttpClient? http = null)
    {
        _store = store;
        _adapters = adapters;
        _http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(180) };
    }

    public bool HasFallback => _store.State.Accounts.Any(account => account.Active && account.ImageFallbackEnabled);

    public bool CommandVisible(string? selectedModel)
    {
        var primary = Primary(selectedModel);
        if (primary is null) return false;
        // Keep the command discoverable for providers whose image capability is
        // not known yet. A missing adapter is an extension point, not a deny
        // decision: a later catalog entry or trusted plugin may add support.
        return true;
    }

    public async Task<NativeImageGeneration> GenerateAsync(string prompt, string? selectedModel, CancellationToken ct = default)
    {
        prompt = prompt.Trim();
        if (prompt.Length == 0) throw NativeImageGenerationException.UnsupportedResult("Write an image description after /imagegen.");
        var primary = Primary(selectedModel);
        if (primary is null) throw NativeImageGenerationException.UnsupportedResult("Connect a provider before generating an image.");
        var primaryModel = Model(primary, selectedModel);
        var primaryRoute = Route(primary, primaryModel);
        var primaryAdapter = _adapters.Find(primaryRoute);
        var primaryID = primaryAdapter?.Id ?? "none";
        if (_adapters.Capability(primaryRoute, primaryID) != ProviderImageCapability.Unsupported && primaryAdapter is not null)
        {
            switch (await AttemptAsync(primary, primaryRoute, primaryAdapter, prompt, ct))
            {
                case ProviderImageResult.Generated generated:
                    _adapters.Record(ProviderImageCapability.Supported, primaryRoute, primaryID);
                    return new NativeImageGeneration(generated.Output, primary.ProviderName, primaryModel);
                case ProviderImageResult.Failed failed:
                    throw NativeImageGenerationException.Failed(failed.Failure);
                case ProviderImageResult.Unsupported:
                    _adapters.Record(ProviderImageCapability.Unsupported, primaryRoute, primaryID);
                    break;
            }
        }

        var source = $"{primary.ProviderName}/{primaryModel}";
        var fallbacks = _store.State.Accounts
            .Where(account => account.Active && account.ImageFallbackEnabled)
            .OrderBy(account => account.Priority);
        foreach (var account in fallbacks)
        {
            var model = Model(account, null);
            var route = Route(account, model);
            var adapter = _adapters.Find(route, includeFallbackOnly: true);
            var id = adapter?.Id ?? "none";
            if (_adapters.Capability(route, id) == ProviderImageCapability.Unsupported) continue;
            if (adapter is null)
            {
                continue;
            }
            switch (await AttemptAsync(account, route, adapter, prompt, ct))
            {
                case ProviderImageResult.Generated generated:
                    _adapters.Record(ProviderImageCapability.Supported, route, id);
                    return new NativeImageGeneration(generated.Output, account.ProviderName, id == "openai.images.fallback" ? "gpt-image-1.5" : model, source);
                case ProviderImageResult.Unsupported:
                    _adapters.Record(ProviderImageCapability.Unsupported, route, id);
                    break;
                case ProviderImageResult.Failed failed:
                    throw NativeImageGenerationException.Failed(failed.Failure);
            }
        }
        throw NativeImageGenerationException.UnsupportedResult($"{source} does not support image generation. Enable an image fallback connection in Settings.");
    }

    private async Task<ProviderImageResult> AttemptAsync(NativeProviderAccount account, ProviderImageRoute route, IProviderImageAdapter adapter, string prompt, CancellationToken ct)
    {
        try
        {
            var prepared = adapter.PrepareImageRequest(prompt, route.Model, route);
            using var request = new HttpRequestMessage(HttpMethod.Post, prepared.Url) { Content = new ByteArrayContent(prepared.Body) };
            foreach (var header in prepared.Headers ?? new Dictionary<string, string>())
            {
                if (header.Key.Equals("Content-Type", StringComparison.OrdinalIgnoreCase))
                    request.Content.Headers.TryAddWithoutValidation(header.Key, header.Value);
                else
                    request.Headers.TryAddWithoutValidation(header.Key, header.Value);
            }
            var credential = _store.Secrets.Read(account.CredentialId);
            switch (prepared.Authentication)
            {
                case ProviderImageAuthentication.Bearer when !string.IsNullOrWhiteSpace(credential):
                    request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", credential);
                    break;
                case ProviderImageAuthentication.RawHeader when !string.IsNullOrWhiteSpace(credential) && !string.IsNullOrWhiteSpace(prepared.AuthenticationHeader):
                    request.Headers.TryAddWithoutValidation(prepared.AuthenticationHeader, credential);
                    break;
            }
            if (account.Protocol == NativeProviderProtocol.ChatGpt)
            {
                if (string.IsNullOrWhiteSpace(account.SessionAccountId)) return new ProviderImageResult.Failed(new ProviderImageFailure(ProviderImageFailureKind.Auth, "The GPT session account is unavailable."));
                request.Headers.TryAddWithoutValidation("ChatGPT-Account-ID", account.SessionAccountId);
                request.Headers.TryAddWithoutValidation("OAI-Product-Sku", "codex");
                request.Headers.TryAddWithoutValidation("OpenAI-Beta", "responses=v1");
                request.Headers.TryAddWithoutValidation("originator", "dots_harness");
                request.Headers.TryAddWithoutValidation("session_id", Guid.NewGuid().ToString());
            }
            using var response = await _http.SendAsync(request, ct);
            var data = await response.Content.ReadAsByteArrayAsync(ct);
            var headers = response.Headers.Concat(response.Content.Headers).ToDictionary(pair => pair.Key, pair => string.Join(",", pair.Value), StringComparer.OrdinalIgnoreCase);
            return adapter.ParseImageResponse(data, (int)response.StatusCode, headers);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (HttpRequestException ex) { return new ProviderImageResult.Failed(new ProviderImageFailure(ProviderImageFailureKind.Network, ex.Message)); }
        catch (TaskCanceledException ex) { return new ProviderImageResult.Failed(new ProviderImageFailure(ProviderImageFailureKind.Network, ex.Message)); }
        catch (Exception ex) { return new ProviderImageResult.Failed(new ProviderImageFailure(ProviderImageFailureKind.Other, ex.Message)); }
    }

    private NativeProviderAccount? Primary(string? selectedModel)
    {
        var active = _store.State.Accounts.Where(account => account.Active).OrderBy(account => account.Priority).ToList();
        return active.FirstOrDefault(account => CanServe(account, selectedModel)) ?? active.FirstOrDefault();
    }

    private static bool CanServe(NativeProviderAccount account, string? model) =>
        string.IsNullOrWhiteSpace(model) || string.Equals(account.Model, model, StringComparison.Ordinal) || (account.Models ?? []).Contains(model, StringComparer.Ordinal);

    private static string Model(NativeProviderAccount account, string? selectedModel) =>
        !string.IsNullOrWhiteSpace(selectedModel) ? selectedModel! : account.Model;

    private static ProviderImageRoute Route(NativeProviderAccount account, string model) =>
        new(account.Id, account.Provider, account.BaseUrl, account.Protocol.ToString(), model, account.AuthType, account.SessionAccountId);
}

public static class NativeImageFileStore
{
    public static string Save(ProviderImageOutput output, string root)
    {
        var directory = Path.Combine(root, "generated-media");
        Directory.CreateDirectory(directory);
        var extension = output.MimeType.ToLowerInvariant() switch
        {
            "image/jpeg" or "image/jpg" => "jpg",
            "image/webp" => "webp",
            "image/gif" => "gif",
            _ => "png",
        };
        var path = Path.Combine(directory, $"{DateTimeOffset.UtcNow:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}.{extension}");
        File.WriteAllBytes(path, output.Data);
        return path;
    }
}
