// Copyright (c) 2026 DOTS
// Provider-backed video and speech generation. Mirrors macOS MediaGeneration.swift:
// images keep the adapter path in NativeProviderImage.cs, while /videogen and
// /audiogen (or /speech) use the `media` specs below.

using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace DotsHarnessCore;

/// <summary><paramref name="Format"/> names a music API's dialect: "standard" or "elevenlabs".</summary>
public sealed record NativeMediaSpec(string Model, string? Path = null, string? Format = null);

/// <summary>What a music backend needs to render one track so it lines up with the others.</summary>
public sealed record MusicStemRequest(string Instrument, int Bpm, string Key, string? Lyrics = null);

public sealed record NativeGeneratedMedia(NativeMediaKind Kind, string FilePath, string MimeType, string Provider, string Model);

public sealed class NativeMediaGenerationException : Exception
{
    public NativeMediaGenerationException(string message, bool retryable = false)
        : base(message) => Retryable = retryable;

    public bool Retryable { get; }
}

public static class NativeMediaCatalog
{
    // Same declarations as the `media` block of macOS providers.json.
    private static readonly Dictionary<string, Dictionary<NativeMediaKind, NativeMediaSpec>> Specs = new(StringComparer.OrdinalIgnoreCase)
    {
        ["openai"] = new()
        {
            [NativeMediaKind.Video] = new("sora-2"),
            [NativeMediaKind.Audio] = new("gpt-4o-mini-tts"),
        },
    };

    public static NativeMediaSpec? SpecFor(string provider, NativeMediaKind kind) =>
        Specs.TryGetValue(provider, out var byKind) && byKind.TryGetValue(kind, out var spec) ? spec : null;
}

public static class NativeMediaGenerator
{
    // Same bounds as macOS: a 200 MB cap, 180 s per request, and five minutes of video polling.
    private const int MaxSavedBytes = 200 * 1024 * 1024;
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(180);
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);
    private const int PollAttempts = 150;
    private const string SpeechInstructions = "Speak naturally in the language of the input, with a warm conversational tone, natural pacing, varied intonation, and brief pauses. Avoid a robotic or announcer-like delivery.";

    /// Returns the raw bytes of the generated video or speech. Nothing is written to disk yet.
    public static async Task<byte[]> GenerateAsync(
        NativeMediaKind kind,
        string prompt,
        string baseUrl,
        string? apiKey,
        NativeMediaSpec spec,
        HttpClient http,
        CancellationToken ct,
        IReadOnlyDictionary<string, string>? extraHeaders = null)
    {
        if (kind == NativeMediaKind.Video) return await GenerateVideoAsync(prompt, baseUrl, apiKey, spec, http, ct, extraHeaders);
        if (kind == NativeMediaKind.Audio) return await GenerateSpeechAsync(prompt, baseUrl, apiKey, spec, http, ct, extraHeaders);
        if (kind == NativeMediaKind.Music) return await GenerateMusicAsync(prompt, baseUrl, apiKey, spec, null, null, http, ct, extraHeaders);
        return await GenerateImageAsync(prompt, baseUrl, apiKey, spec, http, ct, extraHeaders);
    }

    private static readonly HttpClient SharedHttp = new() { Timeout = Timeout.InfiniteTimeSpan };

    /// <summary>
    /// Generation against an OpenAI-compatible server reached by address (a local server or a
    /// music API), saved under generated-media and filed in the library. Mirrors macOS
    /// MediaGenerationClient.generate.
    /// </summary>
    public static async Task<NativeGeneratedMedia> GenerateToFileAsync(NativeMediaKind kind, string prompt, string baseUrl, string? apiKey,
        NativeMediaSpec spec, string root, string provider, int? seconds = null, MusicStemRequest? stem = null, CancellationToken ct = default)
    {
        prompt = prompt.Trim();
        if (prompt.Length == 0) throw new NativeMediaGenerationException(LocalizationService.Current.Get("media.promptMissing"));
        if (spec.Model.Length == 0) throw new NativeMediaGenerationException(LocalizationService.Current.Get("media.modelMissing"));
        var data = kind == NativeMediaKind.Music
            ? await GenerateMusicAsync(prompt, baseUrl, apiKey, spec, seconds, stem, SharedHttp, ct, null)
            : await GenerateAsync(kind, prompt, baseUrl, apiKey, spec, SharedHttp, ct);
        return Save(kind, data, root, provider, spec.Model, prompt);
    }

    private static async Task<byte[]> GenerateImageAsync(string prompt, string baseUrl, string? apiKey, NativeMediaSpec spec, HttpClient http, CancellationToken ct, IReadOnlyDictionary<string, string>? extraHeaders)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, ProviderImageAdapterSupport.Endpoint(baseUrl, spec.Path ?? "/images/generations"))
        {
            Content = new StringContent(new JsonObject
            {
                ["model"] = spec.Model,
                ["prompt"] = prompt,
                ["n"] = 1,
                ["size"] = "1024x1024",
            }.ToJsonString(), System.Text.Encoding.UTF8, "application/json"),
        };
        return await FirstOutputAsync(await SendAsync(http, request, apiKey, extraHeaders, ct), http, ct);
    }

    /// <summary>Text to music. The reply is either the audio itself or the JSON envelope image generation uses.</summary>
    private static async Task<byte[]> GenerateMusicAsync(string prompt, string baseUrl, string? apiKey, NativeMediaSpec spec, int? seconds, MusicStemRequest? stem, HttpClient http, CancellationToken ct, IReadOnlyDictionary<string, string>? extraHeaders)
    {
        var elevenLabs = spec.Format == "elevenlabs";
        var body = new JsonObject();
        if (elevenLabs)
        {
            body["prompt"] = prompt;
            body["model_id"] = spec.Model;
            if (seconds is { } length) body["music_length_ms"] = Math.Clamp(length * 1000, 3000, 600_000);
            if (stem is { Lyrics: null }) body["force_instrumental"] = true;
        }
        else
        {
            body["model"] = spec.Model;
            body["prompt"] = prompt;
            if (seconds is { } length) body["duration"] = length;
            if (stem is not null)
            {
                body["instrument"] = stem.Instrument;
                body["bpm"] = stem.Bpm;
                body["key"] = stem.Key;
                if (stem.Lyrics is { } lyrics) body["lyrics"] = lyrics;
            }
        }
        using var request = new HttpRequestMessage(HttpMethod.Post, ProviderImageAdapterSupport.Endpoint(baseUrl, spec.Path ?? (elevenLabs ? "/music" : "/audio/generations")))
        {
            Content = new StringContent(body.ToJsonString(), System.Text.Encoding.UTF8, "application/json"),
        };
        var headers = new Dictionary<string, string>(extraHeaders ?? new Dictionary<string, string>());
        if (elevenLabs && !string.IsNullOrWhiteSpace(apiKey)) headers["xi-api-key"] = apiKey;
        // A model on this machine can take several times the track's length to render it.
        var data = await SendAsync(http, request, elevenLabs ? null : apiKey, headers, ct, TimeSpan.FromSeconds(900), "audio/*");
        return data.Length > 0 && data[0] == (byte)'{' ? await FirstOutputAsync(data, http, ct) : data;
    }

    /// <summary><c>data[0]</c> of an OpenAI-style generation reply: inline base64, or a link to fetch.</summary>
    private static async Task<byte[]> FirstOutputAsync(byte[] body, HttpClient http, CancellationToken ct)
    {
        var item = (Parse(body)?["data"] as JsonArray)?.FirstOrDefault();
        if (StringOf(item?["b64_json"]) is { } encoded)
        {
            try { return Convert.FromBase64String(encoded.Split(',')[^1]); }
            catch (FormatException) { throw new NativeMediaGenerationException(LocalizationService.Current.Get("media.invalidOutput")); }
        }
        if (StringOf(item?["url"]) is { } link && Uri.TryCreate(link, UriKind.Absolute, out var url) && url.Scheme is "http" or "https")
        {
            using var download = new HttpRequestMessage(HttpMethod.Get, url);
            return await SendAsync(http, download, null, null, ct);
        }
        throw new NativeMediaGenerationException(LocalizationService.Current.Get("media.noOutput"));
    }

    private static async Task<byte[]> GenerateVideoAsync(string prompt, string baseUrl, string? apiKey, NativeMediaSpec spec, HttpClient http, CancellationToken ct, IReadOnlyDictionary<string, string>? extraHeaders)
    {
        var path = spec.Path ?? "/videos";
        using var form = new MultipartFormDataContent();
        form.Add(new StringContent(spec.Model), "model");
        form.Add(new StringContent(prompt), "prompt");
        using var create = new HttpRequestMessage(HttpMethod.Post, ProviderImageAdapterSupport.Endpoint(baseUrl, path)) { Content = form };
        var createdBody = await SendAsync(http, create, apiKey, extraHeaders, ct);
        var videoId = StringOf(Parse(createdBody)?["id"]);
        if (string.IsNullOrEmpty(videoId)) throw new NativeMediaGenerationException("The provider returned no media.");

        // Uri.EscapeDataString keeps only unreserved characters, the same set macOS allows in the job id.
        var jobPath = $"{path}/{Uri.EscapeDataString(videoId)}";
        for (var attempt = 0; attempt < PollAttempts; attempt++)
        {
            ct.ThrowIfCancellationRequested();
            using var status = new HttpRequestMessage(HttpMethod.Get, ProviderImageAdapterSupport.Endpoint(baseUrl, jobPath));
            var statusBody = await SendAsync(http, status, apiKey, extraHeaders, ct);
            var statusValue = Parse(statusBody);
            var state = (StringOf(statusValue?["status"]) ?? "").ToLowerInvariant();
            if (state is "completed" or "succeeded" or "ready") break;
            if (state is "failed" or "cancelled" or "canceled")
            {
                throw new NativeMediaGenerationException(ErrorMessage(statusValue) ?? "Media generation failed.");
            }
            if (attempt == PollAttempts - 1)
            {
                throw new NativeMediaGenerationException("Video generation took too long. Try again later.", retryable: true);
            }
            await Task.Delay(PollInterval, ct);
        }

        using var content = new HttpRequestMessage(HttpMethod.Get, ProviderImageAdapterSupport.Endpoint(baseUrl, $"{jobPath}/content"));
        return await SendAsync(http, content, apiKey, extraHeaders, ct);
    }

    private static async Task<byte[]> GenerateSpeechAsync(string prompt, string baseUrl, string? apiKey, NativeMediaSpec spec, HttpClient http, CancellationToken ct, IReadOnlyDictionary<string, string>? extraHeaders)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, ProviderImageAdapterSupport.Endpoint(baseUrl, spec.Path ?? "/audio/speech"))
        {
            Content = new StringContent(new JsonObject
            {
                ["model"] = spec.Model,
                ["input"] = prompt,
                ["voice"] = "marin",
                ["instructions"] = SpeechInstructions,
                ["response_format"] = "mp3",
            }.ToJsonString(), System.Text.Encoding.UTF8, "application/json"),
        };
        return await SendAsync(http, request, apiKey, extraHeaders, ct);
    }

    /// Saves generated bytes under `generated-media`, named by their SHA-256 so identical output dedupes.
    /// Every saved file is filed in the library; <paramref name="prompt"/> becomes its title there.
    public static NativeGeneratedMedia Save(NativeMediaKind kind, byte[] data, string root, string provider, string model, string? prompt = null)
    {
        if (data.Length == 0 || data.Length > MaxSavedBytes) throw new NativeMediaGenerationException("The provider returned an unusable file.");
        var (extension, mime) = kind switch
        {
            NativeMediaKind.Video => ("mp4", "video/mp4"),
            NativeMediaKind.Audio => ("mp3", "audio/mpeg"),
            NativeMediaKind.Music => SniffAudio(data) ?? ("mp3", "audio/mpeg"),
            _ => SniffImage(data) ?? throw new NativeMediaGenerationException(LocalizationService.Current.Get("media.invalidOutput")),
        };
        var directory = Path.Combine(root, "generated-media");
        Directory.CreateDirectory(directory);
        var name = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
        var path = Path.Combine(directory, $"{name}.{extension}");
        if (!File.Exists(path))
        {
            var temporary = path + ".tmp";
            File.WriteAllBytes(temporary, data);
            File.Move(temporary, path, overwrite: true);
        }
        MediaLibrary.Record(path, MediaLibrary.KindOf(kind), prompt, root);
        return new NativeGeneratedMedia(kind, path, mime, provider, model);
    }

    /// <summary>Music servers answer in whatever container they render to; the default stays mp3.</summary>
    private static (string, string)? SniffAudio(byte[] d) => d.Length < 4 ? null : (d[0], d[1], d[2], d[3]) switch
    {
        (0x52, 0x49, 0x46, 0x46) => ("wav", "audio/wav"),
        (0x66, 0x4C, 0x61, 0x43) => ("flac", "audio/flac"),
        (0x4F, 0x67, 0x67, 0x53) => ("ogg", "audio/ogg"),
        _ => null,
    };

    private static (string, string)? SniffImage(byte[] d)
    {
        if (d.Length >= 4 && d[0] == 0x89 && d[1] == 0x50 && d[2] == 0x4E && d[3] == 0x47) return ("png", "image/png");
        if (d.Length >= 3 && d[0] == 0xFF && d[1] == 0xD8 && d[2] == 0xFF) return ("jpg", "image/jpeg");
        if (d.Length >= 4 && d[0] == 0x47 && d[1] == 0x49 && d[2] == 0x46 && d[3] == 0x38) return ("gif", "image/gif");
        if (d.Length >= 12 && d[0] == 0x52 && d[1] == 0x49 && d[8] == 0x57 && d[9] == 0x45 && d[10] == 0x42 && d[11] == 0x50) return ("webp", "image/webp");
        return null;
    }

    private static async Task<byte[]> SendAsync(HttpClient http, HttpRequestMessage request, string? apiKey, IReadOnlyDictionary<string, string>? extraHeaders, CancellationToken ct, TimeSpan? timeout = null, string? accept = null)
    {
        if (accept is not null) request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue(accept));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (!string.IsNullOrWhiteSpace(apiKey)) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        foreach (var header in extraHeaders ?? new Dictionary<string, string>()) request.Headers.TryAddWithoutValidation(header.Key, header.Value);

        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(timeout ?? RequestTimeout);
        using var response = await http.SendAsync(request, deadline.Token);
        var body = await response.Content.ReadAsByteArrayAsync(deadline.Token);
        var status = (int)response.StatusCode;
        if (status is >= 200 and < 300) return body;
        var value = Parse(body);
        throw new NativeMediaGenerationException(
            ErrorMessage(value) ?? $"The provider request failed with status {status}.",
            retryable: status is 408 or 429 or >= 500);
    }

    private static JsonNode? Parse(byte[] body)
    {
        try
        {
            return JsonNode.Parse(System.Text.Encoding.UTF8.GetString(body));
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }

    private static string? StringOf(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private static string? ErrorMessage(JsonNode? value) =>
        StringOf(value?["error"]?["message"]) ?? StringOf(value?["message"])
        ?? StringOf(value?["detail"]?["message"]) ?? StringOf(value?["detail"]);
}
