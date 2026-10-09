using System.Globalization;
using System.Text;

namespace DotsHarnessCore;

/// Detects a user's request to enter the read-only planning surface.
///
/// A small intent gate at the composer boundary. Explicit request shapes are
/// decided locally; text that merely mentions a "plan" word (plan.md, planet,
/// planını çıkar, ...) is <see cref="PlanVerdict.Ambiguous"/> and is put to the
/// model through <see cref="ResolveAsync"/>. The native mobile implementations
/// mirror the same phrase set because they do not compile this shared assembly.
public enum PlanVerdict { Yes, No, Ambiguous }

public static class PlanningIntent
{
    private static readonly string[] PlanningPhrases =
    [
        "make a plan", "create a plan", "write a plan", "draft a plan",
        "prepare a plan", "give me a plan", "show me a plan", "build a plan",
        "plan this", "plan the", "plan how", "plan out", "implementation plan",
        "action plan", "project plan", "roadmap", "step by step plan",
        "just plan", "plan only", "plan in chat", "plan in a file",
        "write the plan", "save the plan", "write the plan to", "save the plan to",
        "plan changes", "plan changes to", "plan changes in", "plan this file",
        "plan the file", "before coding", "before implementing", "first make a plan",
        "need a plan", "want a plan", "i need a plan",
        "turn on plan mode", "enable plan mode",
        "open plan mode", "plan mode", "switch to plan mode", "go into plan mode",
        "enter plan mode", "open the plan tab", "show plan tab",
        "plan yap", "plan olustur", "plan hazirla",
        "plan yaz", "plan cikar", "plan cikart", "uygulama plani", "eylem plani",
        "yol haritasi", "adim adim plan", "sadece plan", "sohbette plan",
        "chatte plan", "chatte planlama", "sohbette planlama", "plan seklinde",
        "plan formatinda", "dosyaya plan", "dosyaya planlama", "dosyada plan",
        "dosyada planlama", "dosya icin plan", "dosya icin planlama",
        "plani dosyaya", "plan dosyasi",
        "dosyayi planla", "once plan", "once bir plan", "once planla",
        "plan moduna gec", "plan moduna gir", "plan modunu ac", "plan modunu kullan",
        "plan sekmesine gec", "plan sekmesine gir", "plan sekmesini ac", "plan bolumu",
        "plani guncelle", "planı güncelle",
        "plani gozden gecir", "planı gözden geçir", "plani incele", "planı incele",
    ];

    private static readonly string[] ExecutionPhrases =
    [
        "apply the plan", "approve plan", "approve the plan", "execute the plan",
        "implement the plan", "run the plan", "use the plan", "proceed with the plan",
        "planı uygula", "plani uygula", "planı onayla", "plani onayla",
        "planı hayata geçir", "plani hayata gecir", "planı uygulamaya geçir",
        "plani uygulamaya gecir", "planı devam ettir", "plani devam ettir",
        "what is plan mode", "what does plan mode", "explain plan mode",
        "explain what plan mode",
        "plan mode nedir", "plan modu nedir", "plan sekmesi nedir",
    ];

    private static readonly string[] NormalizedPlanning = PlanningPhrases.Select(Normalize).ToArray();
    private static readonly string[] NormalizedExecution = ExecutionPhrases.Select(Normalize).ToArray();

    /// True only for an explicit request to enter plan mode; ambiguous wording
    /// needs <see cref="ResolveAsync"/>.
    public static bool IsPlanRequest(string? text) => Classify(text) == PlanVerdict.Yes;

    public static PlanVerdict Classify(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return PlanVerdict.No;

        var raw = text.Trim();
        if (raw.StartsWith("/plan", StringComparison.OrdinalIgnoreCase)
            && (raw.Length == 5 || char.IsWhiteSpace(raw[5]))) return PlanVerdict.Yes;

        var normalized = Normalize(raw);
        if (normalized.Length == 0) return PlanVerdict.No;

        // Whole-word matching: "make a plan" must not match "make a planet".
        var padded = $" {normalized} ";
        bool Has(string phrase) => padded.Contains($" {phrase} ", StringComparison.Ordinal);
        if (NormalizedExecution.Any(Has)) return PlanVerdict.No;

        if (normalized == "plan" || NormalizedPlanning.Any(Has)) return PlanVerdict.Yes;
        return normalized.Split(' ').Any(word => word.StartsWith("plan", StringComparison.Ordinal))
            ? PlanVerdict.Ambiguous
            : PlanVerdict.No;
    }

    /// `ask` is only called for ambiguous text and must fail closed (false).
    public static async Task<bool> ResolveAsync(string? text, Func<string, Task<bool>> ask) =>
        Classify(text) switch
        {
            PlanVerdict.Yes => true,
            PlanVerdict.Ambiguous => await ask(text!),
            _ => false,
        };

    private static string Normalize(string text)
    {
        var value = text.ToLowerInvariant()
            .Replace('ı', 'i')
            .Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder(value.Length);
        foreach (var character in value)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(character) == UnicodeCategory.NonSpacingMark)
                continue;
            builder.Append(char.IsLetterOrDigit(character) ? character : ' ');
        }

        return string.Join(' ', builder.ToString()
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
    }
}
