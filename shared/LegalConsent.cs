// Copyright (c) 2026 DOTS
// Legal document fetch + acceptance/consent state, shared by the Linux and
// Windows harness cores. The macOS/iOS/Android clients carry their own ports.
//
// The privacy policy and user agreement live in the DOTS web database
// (apps table, slug 'dots-herness') and are fetched live so an updated text
// reaches users without an app release. See docs/legal/README.md.

using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace DotsHarnessCore;

/// Persistence seam: each AppModel adapts this to its own settings store.
public interface ILegalStore
{
    string? Get(string key);
    void Set(string key, string value);
}

/// The two documents plus a content hash that changes whenever either does.
public sealed record LegalDocuments(string TermsMarkdown, string PrivacyMarkdown, string Hash)
{
    public bool IsEmpty => TermsMarkdown.Length == 0 && PrivacyMarkdown.Length == 0;
    public bool IsComplete => TermsMarkdown.Length > 0 && PrivacyMarkdown.Length > 0;
}

public sealed class LegalService
{
    public const string RestUrl =
        "https://dots-web-api.pettakip.workers.dev/rest/v1/apps?select=privacy_policy_tr,privacy_policy_en,terms_of_service_tr,terms_of_service_en"
        + "&slug.eq=dots-herness&single=true";

    private const string AcceptedHashKey = "legal.acceptedHash";
    private const string AcceptedAtKey = "legal.acceptedAt";

    /// Consent items. The first is required for AI features to run.
    public static readonly IReadOnlyList<string> ConsentKeys =
        new[] { "aiTransfer", "github", "voice", "marketing" };

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };

    private readonly ILegalStore _store;
    private readonly string? _cachePath;

    public LegalService(ILegalStore store, string? cacheDirectory = null)
    {
        _store = store;
        _cachePath = cacheDirectory is null
            ? null
            : Path.Combine(cacheDirectory, "legal-cache-v2.json");
    }

    public static string WebUrl(string lang, bool terms) => lang == "tr"
        ? (terms
            ? "https://dots.net.tr/uygulama/dots-herness/kullanim-sozlesmesi"
            : "https://dots.net.tr/uygulama/dots-herness/gizlilik")
        : (terms
            ? "https://dots.net.tr/apps/dots-herness/terms-of-service"
            : "https://dots.net.tr/apps/dots-herness/privacy");

    /// Fetch from the web; on failure fall back to the on-disk cache. A cache
    /// with incomplete content is not accepted as a legal document.
    public async Task<LegalDocuments?> FetchAsync(string lang, CancellationToken cancellationToken = default)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, RestUrl);
            request.Headers.UserAgent.ParseAdd("DotsHarness");
            using var response = await Http.SendAsync(request, cancellationToken).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            var docs = Parse(body, lang);
            if (docs is { IsComplete: true })
            {
                WriteCache(body);
                return docs;
            }
        }
        catch (Exception) when (cancellationToken.IsCancellationRequested == false)
        {
            // fall through to cache
        }

        var cached = ReadCache();
        var cachedDocs = cached is null ? null : Parse(cached, lang);
        return cachedDocs is { IsComplete: true } ? cachedDocs : null;
    }

    private static LegalDocuments? Parse(string json, string lang)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        JsonElement row;
        if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("data", out var data))
        {
            row = data.ValueKind == JsonValueKind.Array
                ? (data.GetArrayLength() > 0 ? data[0] : default)
                : data;
        }
        else if (root.ValueKind == JsonValueKind.Array)
        {
            row = root.GetArrayLength() > 0 ? root[0] : default;
        }
        else
        {
            row = root;
        }
        if (row.ValueKind != JsonValueKind.Object) return null;

        string Pick(string field)
        {
            var requested = lang.Split('-', '_')[0].ToLowerInvariant();
            var suffixes = requested == "tr" ? new[] { "tr", "en" } : new[] { requested, "en" };
            foreach (var suffix in suffixes.Distinct(StringComparer.Ordinal))
            {
                var value = Str(row, $"{field}_{suffix}");
                if (value.Length > 0) return value;
            }
            return "";
        }

        var terms = Pick("terms_of_service");
        var privacy = Pick("privacy_policy");
        return new LegalDocuments(terms, privacy, HashOf(terms, privacy));
    }

    private static string Str(JsonElement row, string name) =>
        row.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? ""
            : "";

    private static string HashOf(string terms, string privacy)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(terms + "\0" + privacy));
        return Convert.ToHexString(bytes)[..12].ToLowerInvariant();
    }

    // --- acceptance ---------------------------------------------------------

    public bool HasAnyAcceptance => !string.IsNullOrEmpty(_store.Get(AcceptedHashKey));

    public bool NeedsAcceptance(LegalDocuments docs) =>
        _store.Get(AcceptedHashKey) != docs.Hash;

    public void Accept(LegalDocuments docs)
    {
        _store.Set(AcceptedHashKey, docs.Hash);
        _store.Set(AcceptedAtKey, DateTimeOffset.UtcNow.ToString("O"));
    }

    // --- consent ----------------------------------------------------------

    /// These are not opt-in toggles: using the app means these are already
    /// in effect, so consent is always granted and cannot be revoked here.
    public bool GetConsent(string name) => true;

    /// AI features are always allowed; see <see cref="GetConsent"/>.
    public bool AiTransferAllowed => true;

    // --- cache ----------------------------------------------------------

    private void WriteCache(string body)
    {
        if (_cachePath is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_cachePath)!);
            File.WriteAllText(_cachePath, body);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private string? ReadCache()
    {
        if (_cachePath is null || !File.Exists(_cachePath)) return null;
        try { return File.ReadAllText(_cachePath); }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }
}
