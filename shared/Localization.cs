// Copyright (c) 2026 DOTS
// Shared application UI localization for the Windows and Linux shells.

using System.Collections.Concurrent;
using System.Globalization;
using System.Resources;
using System.Text.Json;
using PluginRuntime;

namespace DotsHarnessCore;

public enum AppLanguage
{
    System,
    Turkish,
    English,
    German,
    Spanish,
    French,
    Italian,
    Japanese,
    Korean,
    Dutch,
    Portuguese,
    Russian,
    SimplifiedChinese,
    Arabic,
    Bengali,
    Hindi,
    Indonesian,
    Vietnamese,
    Urdu,
    Marathi,
    Telugu,
    Tamil,
    Persian,
    Polish,
    Ukrainian,
    Thai,
    Malay,
    Romanian,
    Greek,
    Czech,
    Hungarian,
}

public static class AppLanguages
{
    public static IReadOnlyList<AppLanguage> All { get; } = Enum.GetValues<AppLanguage>();

    public static IReadOnlyList<AppLanguage> Supported { get; } =
        All.Where(language => language != AppLanguage.System).ToArray();

    public static string Code(this AppLanguage language) => language switch
    {
        AppLanguage.System => "system",
        AppLanguage.Turkish => "tr",
        AppLanguage.English => "en",
        AppLanguage.German => "de",
        AppLanguage.Spanish => "es",
        AppLanguage.French => "fr",
        AppLanguage.Italian => "it",
        AppLanguage.Japanese => "ja",
        AppLanguage.Korean => "ko",
        AppLanguage.Dutch => "nl",
        AppLanguage.Portuguese => "pt",
        AppLanguage.Russian => "ru",
        AppLanguage.SimplifiedChinese => "zh-Hans",
        AppLanguage.Arabic => "ar",
        AppLanguage.Bengali => "bn",
        AppLanguage.Hindi => "hi",
        AppLanguage.Indonesian => "id",
        AppLanguage.Vietnamese => "vi",
        AppLanguage.Urdu => "ur",
        AppLanguage.Marathi => "mr",
        AppLanguage.Telugu => "te",
        AppLanguage.Tamil => "ta",
        AppLanguage.Persian => "fa",
        AppLanguage.Polish => "pl",
        AppLanguage.Ukrainian => "uk",
        AppLanguage.Thai => "th",
        AppLanguage.Malay => "ms",
        AppLanguage.Romanian => "ro",
        AppLanguage.Greek => "el",
        AppLanguage.Czech => "cs",
        AppLanguage.Hungarian => "hu",
        _ => "en",
    };

    public static string CultureName(this AppLanguage language) => language switch
    {
        AppLanguage.System => EffectiveSystemLanguage().CultureName(),
        AppLanguage.Turkish => "tr-TR",
        AppLanguage.English => "en-US",
        AppLanguage.German => "de-DE",
        AppLanguage.Spanish => "es-ES",
        AppLanguage.French => "fr-FR",
        AppLanguage.Italian => "it-IT",
        AppLanguage.Japanese => "ja-JP",
        AppLanguage.Korean => "ko-KR",
        AppLanguage.Dutch => "nl-NL",
        AppLanguage.Portuguese => "pt-PT",
        AppLanguage.Russian => "ru-RU",
        AppLanguage.SimplifiedChinese => "zh-CN",
        AppLanguage.Arabic => "ar-SA",
        AppLanguage.Bengali => "bn-BD",
        AppLanguage.Hindi => "hi-IN",
        AppLanguage.Indonesian => "id-ID",
        AppLanguage.Vietnamese => "vi-VN",
        AppLanguage.Urdu => "ur-PK",
        AppLanguage.Marathi => "mr-IN",
        AppLanguage.Telugu => "te-IN",
        AppLanguage.Tamil => "ta-IN",
        AppLanguage.Persian => "fa-IR",
        AppLanguage.Polish => "pl-PL",
        AppLanguage.Ukrainian => "uk-UA",
        AppLanguage.Thai => "th-TH",
        AppLanguage.Malay => "ms-MY",
        AppLanguage.Romanian => "ro-RO",
        AppLanguage.Greek => "el-GR",
        AppLanguage.Czech => "cs-CZ",
        AppLanguage.Hungarian => "hu-HU",
        _ => "en-US",
    };

    public static string NativeName(this AppLanguage language) => language switch
    {
        AppLanguage.System => "System language",
        AppLanguage.Turkish => "Türkçe",
        AppLanguage.English => "English",
        AppLanguage.German => "Deutsch",
        AppLanguage.Spanish => "Español",
        AppLanguage.French => "Français",
        AppLanguage.Italian => "Italiano",
        AppLanguage.Japanese => "日本語",
        AppLanguage.Korean => "한국어",
        AppLanguage.Dutch => "Nederlands",
        AppLanguage.Portuguese => "Português",
        AppLanguage.Russian => "Русский",
        AppLanguage.SimplifiedChinese => "简体中文",
        AppLanguage.Arabic => "العربية",
        AppLanguage.Bengali => "বাংলা",
        AppLanguage.Hindi => "हिन्दी",
        AppLanguage.Indonesian => "Bahasa Indonesia",
        AppLanguage.Vietnamese => "Tiếng Việt",
        AppLanguage.Urdu => "اردو",
        AppLanguage.Marathi => "मराठी",
        AppLanguage.Telugu => "తెలుగు",
        AppLanguage.Tamil => "தமிழ்",
        AppLanguage.Persian => "فارسی",
        AppLanguage.Polish => "Polski",
        AppLanguage.Ukrainian => "Українська",
        AppLanguage.Thai => "ไทย",
        AppLanguage.Malay => "Bahasa Melayu",
        AppLanguage.Romanian => "Română",
        AppLanguage.Greek => "Ελληνικά",
        AppLanguage.Czech => "Čeština",
        AppLanguage.Hungarian => "Magyar",
        _ => "English",
    };

    public static bool IsRightToLeft(this AppLanguage language) =>
        language is AppLanguage.Arabic or AppLanguage.Urdu or AppLanguage.Persian
        || language == AppLanguage.System && EffectiveSystemLanguage().IsRightToLeft();

    public static bool TryParse(string? code, out AppLanguage language)
    {
        if (string.Equals(code, "system", StringComparison.OrdinalIgnoreCase))
        {
            language = AppLanguage.System;
            return true;
        }

        language = Supported.FirstOrDefault(item =>
            string.Equals(item.Code(), code, StringComparison.OrdinalIgnoreCase));
        return language != AppLanguage.System;
    }

    public static AppLanguage EffectiveSystemLanguage()
    {
        var code = CultureInfo.CurrentUICulture.Name.Replace('_', '-').ToLowerInvariant();
        if (code.StartsWith("zh-", StringComparison.Ordinal)) return AppLanguage.SimplifiedChinese;
        var match = Supported.FirstOrDefault(language =>
            code == language.Code() || code.StartsWith(language.Code() + "-", StringComparison.Ordinal));
        return match == AppLanguage.System ? AppLanguage.English : match;
    }
}

/// <summary>
/// A release ships only English and Turkish. tools/build_language_packs.py moves the
/// other languages out of the package and writes `language-packs.json` (code → sha256)
/// beside the app; each one downloads the first time it is needed. A development build
/// has every language as a satellite assembly and no manifest, so nothing downloads.
///
/// Mirrors LanguagePacks in AppLocalization.swift on macOS. A pack here is a JSON object
/// of key → text, not code.
/// </summary>
public static class LanguagePacks
{
    public const string BaseUrl = "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev/assets/downloads/languages/";

    /// <summary>Where downloaded packs are kept; the app's support folder unless a test says otherwise.</summary>
    public static string Root { get; set; } = Path.Combine(SupportPaths.Default().Root, "languages");

    private static readonly ConcurrentDictionary<string, IReadOnlyDictionary<string, string>?> Loaded = new(StringComparer.Ordinal);
    private static IReadOnlyDictionary<string, string> _pinned = ReadManifest(Path.Combine(AppContext.BaseDirectory, "language-packs.json"));

    public static IReadOnlyDictionary<string, string> ReadManifest(string path)
    {
        try { return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path)) ?? []; }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { return new Dictionary<string, string>(); }
    }

    /// <summary>Replaces the manifest; for tests.</summary>
    public static void Pin(IReadOnlyDictionary<string, string> packs)
    {
        _pinned = packs;
        Loaded.Clear();
    }

    /// <summary>Keyed by content hash, so an app update with new copy fetches its own file.</summary>
    private static string? PackPath(AppLanguage language) =>
        _pinned.TryGetValue(language.Code(), out var sha) ? Path.Combine(Root, sha, language.Code() + ".json") : null;

    /// <summary>True when the language needs no download: it is bundled, or its pack is already here.</summary>
    public static bool IsAvailable(AppLanguage language) => PackPath(language) is not { } path || File.Exists(path);

    /// <summary>The text of a key in a downloaded language, or null when the language is bundled or not yet here.</summary>
    public static string? Get(string key, AppLanguage language)
    {
        if (PackPath(language) is not { } path) return null;
        var pack = Loaded.GetOrAdd(path, static file =>
        {
            try { return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(file)); }
            catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { return null; }
        });
        // A pack that is not here yet is asked for again once it arrives.
        if (pack is null) Loaded.TryRemove(path, out _);
        return pack is not null && pack.TryGetValue(key, out var value) ? value : null;
    }

    /// <summary>Downloads the language's pack when it is pinned and missing; the hash is checked before it is kept.</summary>
    public static async Task EnsureAsync(AppLanguage language, CancellationToken ct = default)
    {
        if (PackPath(language) is not { } path || File.Exists(path)) return;
        var sha = _pinned[language.Code()];
        await FileDownloader.DownloadAsync(new Uri(BaseUrl + sha + ".json"), path, ct: ct, sha256: sha);
        Loaded.TryRemove(path, out _);
    }
}

public sealed class LocalizationService : ObservableObject
{
    private static readonly ResourceManager Resources =
        new("DotsHarnessCore.Localization", typeof(LocalizationService).Assembly);
    private static LocalizationService? _current;
    private AppLanguage _language = AppLanguage.System;

    public static LocalizationService Current => _current ??= new LocalizationService();

    public LocalizationService()
    {
        _current = this;
    }

    public IReadOnlyList<AppLanguage> Languages => AppLanguages.All;

    public AppLanguage Language
    {
        get => _language;
        private set => SetProperty(ref _language, value);
    }

    public AppLanguage EffectiveLanguage =>
        Language == AppLanguage.System ? AppLanguages.EffectiveSystemLanguage() : Language;

    public CultureInfo Culture => CultureInfo.GetCultureInfo(EffectiveLanguage.CultureName());

    public bool IsRightToLeft => EffectiveLanguage.IsRightToLeft();

    /// <summary>
    /// Fetches the selected language when the release left it out, then tells the
    /// interface to read its text again. Until it arrives the interface is in English.
    /// </summary>
    public async Task LoadLanguagePackAsync()
    {
        var language = EffectiveLanguage;
        if (LanguagePacks.IsAvailable(language)) return;
        try { await LanguagePacks.EnsureAsync(language); }
        catch (Exception error) when (error is RouterException or HttpRequestException or IOException or UnauthorizedAccessException or TaskCanceledException) { return; }
        OnPropertyChanged(nameof(Language));
    }

    public void SetLanguage(AppLanguage language)
    {
        if (!SetProperty(ref _language, language)) return;
        OnPropertyChanged(nameof(EffectiveLanguage));
        OnPropertyChanged(nameof(Culture));
        OnPropertyChanged(nameof(IsRightToLeft));
    }

    public string Get(string key, params object?[] arguments)
    {
        var value = LanguagePacks.Get(key, EffectiveLanguage)
            ?? GetString(key, Culture) ?? GetString(key, CultureInfo.GetCultureInfo("en-US")) ?? key;
        return arguments.Length == 0 ? value : string.Format(Culture, value, arguments);
    }

    private static string? GetString(string key, CultureInfo culture)
    {
        try
        {
            return Resources.GetString(key, culture);
        }
        catch (MissingManifestResourceException)
        {
            return null;
        }
    }
}
