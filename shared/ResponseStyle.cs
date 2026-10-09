using System.Globalization;
using System.Text;

namespace DotsHarnessCore;

/// <summary>
/// The resolved response style for one request. It changes response prose and,
/// only when explicitly requested, supplies a provider output ceiling. It does
/// not guarantee completion or a particular billed token count, and it never
/// rewrites the user's prompt or changes the tool/coding contract.
/// </summary>
public enum AgentResponseStyle
{
    Standard,
    Concise,
    Ultra,
    Detailed,
    Strict,
}

/// Persistent response preference shown in Settings. Strict is intentionally
/// not a preference: it represents an explicit numeric per-turn limit.
public enum AgentResponseStylePreference
{
    Balanced,
    Concise,
    Ultra,
    Detailed,
}

public static class ResponseStylePreferenceExtensions
{
    public static ResponseStyleDecision Decision(this AgentResponseStylePreference preference) => preference switch
    {
        AgentResponseStylePreference.Concise => new(AgentResponseStyle.Concise),
        AgentResponseStylePreference.Ultra => new(AgentResponseStyle.Ultra),
        AgentResponseStylePreference.Detailed => new(AgentResponseStyle.Detailed),
        _ => new(AgentResponseStyle.Standard),
    };
}

public readonly record struct ResponseStyleDecision(
    AgentResponseStyle Style,
    int? MaxOutputTokens = null,
    int? MaxWords = null)
{
    public bool IsShort => Style is AgentResponseStyle.Concise or AgentResponseStyle.Ultra or AgentResponseStyle.Strict;
    public bool IsHardLimit => Style == AgentResponseStyle.Strict;
    /// Word limits are converted conservatively for providers that expose only
    /// a token ceiling; the prompt still carries the exact word constraint.
    /// This is an upper bound, not a completion guarantee.
    public int? ProviderOutputTokenCap => MaxOutputTokens ?? (MaxWords is { } words
        ? words > int.MaxValue / 2 ? int.MaxValue : words * 2
        : null);

    /// Aviation "dark cockpit": a quiet panel means everything is normal, so
    /// only the abnormal and the actionable earn output tokens.
    private const string DarkCockpit = " Dark cockpit rule: silence means normal. Report only results, deviations, failures, and decisions the user must make; never narrate steps or restate what went as expected.";

    public string Guidance => Style switch
    {
        AgentResponseStyle.Concise =>
            "Concise: short, direct prose for this turn. No preamble, optional explanation, or alternatives." + DarkCockpit,
        AgentResponseStyle.Ultra =>
            "Ultra: terse prose for this turn. Only the answer and the evidence it needs." + DarkCockpit,
        AgentResponseStyle.Detailed =>
            "For this turn, explain the answer clearly and thoroughly. Include the relevant context, reasoning, trade-offs, and verification details, but avoid repetition and unrelated alternatives.",
        AgentResponseStyle.Strict => StrictGuidance(),
        _ => string.Empty,
    };

    private string StrictGuidance()
    {
        var limit = MaxOutputTokens is { } tokens
            ? $"Do not exceed {tokens} output tokens."
            : MaxWords is { } words
                ? $"Do not exceed {words} words."
                : "Stay within the requested output limit.";
        return $"{limit} Give the shortest useful answer. If the limit is too low to finish, say what is missing; do not claim the limit is enforced by the provider.";
    }

}

public static class ResponseStyleResolver
{
    /// Settings controls ordinary response style. Only an explicit numeric
    /// token/word ceiling can temporarily override it; phrases such as
    /// "kısaca" are not inspected by the runtime path.
    public static ResponseStyleDecision Resolve(AgentResponseStylePreference preference, string? prompt) =>
        ResponseStyleDetector.DetectLimit(prompt) ?? preference.Decision();
}

public static class ResponseStyleDetector
{
    private static readonly string[] DetailPhrases =
    [
        "detaylı anlat", "detayli anlat", "ayrıntılı anlat", "ayrintili anlat",
        "uzun anlat", "detay ver", "detayları ver", "detaylari ver",
        "detaylı açıkla", "detayli acikla", "ayrıntılı açıkla", "ayrintili acikla",
        "kısa cevap verme", "kisa cevap verme", "kısa verme", "kisa verme",
        "do not be brief", "do not be concise", "explain in detail", "be detailed",
        "long answer", "full explanation",
    ];

    private static readonly string[] UltraPhrases =
    [
        "çok kısa", "cok kisa", "tek cümle", "tek cumle", "tek satır", "tek satir",
        "caveman", "ultra short", "one sentence", "one line", "telegraphic",
    ];

    private static readonly string[] ConcisePhrases =
    [
        "kısaca", "kisaca", "kısa cevap", "kisa cevap", "özetle", "ozetle",
        "özet olarak", "ozet olarak", "az token", "daha az token", "token kullanma",
        "gereksiz açıklama yapma", "gereksiz aciklama yapma", "kısa anlat", "kisa anlat",
        "briefly", "be concise", "concise answer", "summarize", "short answer",
        "use fewer tokens", "use less tokens", "no unnecessary explanation",
    ];

    public static ResponseStyleDecision Detect(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return new(AgentResponseStyle.Standard);
        var normalized = Normalize(text);
        if (normalized.Length == 0) return new(AgentResponseStyle.Standard);
        var padded = $" {normalized} ";

        var limit = DetectLimitNormalized(normalized);
        if (limit is not null) return limit.Value;

        if (DetailPhrases.Any(phrase => padded.Contains($" {Normalize(phrase)} ", StringComparison.Ordinal)))
            return new(AgentResponseStyle.Standard);

        if (UltraPhrases.Any(phrase => padded.Contains($" {Normalize(phrase)} ", StringComparison.Ordinal)))
            return new(AgentResponseStyle.Ultra);
        if (ConcisePhrases.Any(phrase => padded.Contains($" {Normalize(phrase)} ", StringComparison.Ordinal)))
            return new(AgentResponseStyle.Concise);
        return new(AgentResponseStyle.Standard);
    }

    public static ResponseStyleDecision? DetectLimit(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        return DetectLimitNormalized(Normalize(text));
    }

    /// Not an overload of `DetectLimit`: `string?` and `string` erase to the same
    /// signature, so sharing the name made the whole core fail to compile.
    private static ResponseStyleDecision? DetectLimitNormalized(string normalized)
    {
        var limit = ParseLimit(normalized);
        return limit.tokens is not null || limit.words is not null
            ? new ResponseStyleDecision(AgentResponseStyle.Strict, limit.tokens, limit.words)
            : null;
    }

    private static (int? tokens, int? words) ParseLimit(string normalized)
    {
        var words = normalized.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        for (var index = 0; index < words.Length - 1; index++)
        {
            if (!int.TryParse(words[index], NumberStyles.None, CultureInfo.InvariantCulture, out var value)
                || value <= 0)
                continue;
            var unit = words[index + 1].TrimEnd('.', ',', ';', ':');
            if (unit is "token" or "tokens") return (value, null);
            if (unit is "kelime" or "kelimelik" or "kelimeyi" or "word" or "words") return (null, value);
        }
        return (null, null);
    }

    private static string Normalize(string value)
    {
        var lowered = value.ToLowerInvariant().Replace('ı', 'i');
        var decomposed = lowered.Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder(decomposed.Length);
        foreach (var character in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(character) == UnicodeCategory.NonSpacingMark) continue;
            builder.Append(char.IsLetterOrDigit(character) ? character : ' ');
        }
        return string.Join(' ', builder.ToString().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
    }
}
