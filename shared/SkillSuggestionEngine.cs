// Copyright (c) 2026 DOTS
// Turns a lesson learned again and again into a skill suggestion. A lesson the
// project keeps relearning is a procedure worth writing down; a repeated shell
// command or a similar prompt is not, so those are no longer mined. Detection only
// ever produces a suggestion; nothing is written until the user accepts it.

using System.Security.Cryptography;
using System.Text;

namespace DotsHarnessCore;

public enum SkillSuggestionSignal
{
    /// <summary>A lesson learned from at least <see cref="SkillSuggestionEngine.LessonHitThreshold"/> separate events.</summary>
    Lesson,
    /// <summary>The agent itself proposed it via the skill.suggest tool.</summary>
    AgentProposed,
}

public sealed record SkillSuggestion(
    string Id,
    SkillSuggestionSignal Signal,
    string DraftName,
    string DraftDescription,
    string Body)
{
    /// <summary>DraftName and DraftDescription stay as written: they become the saved skill's name and description.</summary>
    public string CardTitle => LocalizationService.Current.Get("skill.suggestion.title", DraftName);

    public string CardDescription => DraftDescription;
}

public static class SkillSuggestionEngine
{
    /// <summary>Distinct events behind a lesson before it is worth a skill: once is a hint, twice a rule, three times a procedure.</summary>
    public const int LessonHitThreshold = 3;

    public static IReadOnlyList<SkillSuggestion> FromLessons(IEnumerable<Lesson> lessons) => lessons
        .Where(lesson => lesson.Hits >= LessonHitThreshold && lesson.Rule.Trim().Length > 0)
        .OrderByDescending(lesson => lesson.Hits)
        .ThenByDescending(lesson => lesson.LastSeen)
        .Select(FromLesson)
        .ToList();

    private static SkillSuggestion FromLesson(Lesson lesson)
    {
        var rule = lesson.Rule.Trim();
        var body = new StringBuilder();
        if (lesson.When.Trim().Length > 0) body.Append("## When\n\n").Append(lesson.When.Trim()).Append("\n\n");
        body.Append("## Rule\n\n").Append(rule).Append("\n\n");
        if (lesson.Why.Trim().Length > 0) body.Append("## Why\n\n").Append(lesson.Why.Trim()).Append("\n\n");
        if (lesson.Paths.Count > 0) body.Append("## Applies to\n\n").Append(string.Join('\n', lesson.Paths.Select(path => $"- `{path}`"))).Append('\n');
        return new SkillSuggestion(
            ShortHash("lesson:" + lesson.Id),
            SkillSuggestionSignal.Lesson,
            Truncate(rule, 60),
            Truncate(lesson.Line, 200),
            body.ToString());
    }

    private static string Truncate(string text, int max) => text.Length <= max ? text : text[..max].TrimEnd() + "…";

    public static string ShortHash(string key) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key)))[..12].ToLowerInvariant();
}
