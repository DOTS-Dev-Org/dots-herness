// Copyright (c) 2026 DOTS
// Plan-mode clarification tool: the agent asks, the user picks or writes an answer.

using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public sealed record AskUserQuestion(string Id, string Header, string Prompt, IReadOnlyList<string> Options);

public sealed record PendingQuestion(
    string RpcId,
    string SessionId,
    string QuestionId,
    IReadOnlyList<AskUserQuestion> Questions);

public static class AskUserTool
{
    public const string Name = "ask_user";

    /// Follow-ups are allowed, but a run can never spend more than this many rounds on questions.
    public const int MaxRounds = 3;

    public const string Description =
        "Ask the user clarifying questions when their request is genuinely ambiguous - an unclear goal, an "
        + "undefined scope, or a choice the workspace cannot settle - and a wrong reading would waste the work. "
        + "Do not ask when the request is already clear, when reading the files answers it, or to confirm "
        + "something you were already told: just do the work. Send every question you already know about in a "
        + "single call - do not drip them one at a time. In plan mode ask about whatever the plan's shape depends "
        + "on: goal, scope, target platforms, existing code to reuse, data or API shape, migration and rollback, "
        + "tests, performance and security limits, release steps. Each question carries 3 or 4 concrete suggested "
        + "options; the user can always type an answer of their own instead, so read the written answers "
        + "carefully. After the answers arrive you may call this tool again only for genuinely new questions that "
        + "those answers opened up - a chosen option or a written answer that changes the shape of the work. "
        + "Never repeat a question you already asked, and never ask again once the answers are enough to "
        + "continue. A run allows at most 3 rounds of questions.";

    /// Returned once the round budget is spent, so a run can never loop on questions.
    public const string RepeatNotice =
        "The question budget for this run is spent and every answer is above. Do not call ask_user again. "
        + "Continue with the work now, stating any remaining assumption explicitly - under ## Risks when planning.";

    /// Returned when a follow-up call only repeats questions the user already answered.
    public const string DuplicateNotice =
        "Every question in that call was already asked and answered above. Do not ask it again. Either send "
        + "only genuinely new questions raised by those answers, or continue with the work now.";

    public const string UnavailableNotice =
        "Questions cannot be shown right now. Continue using your best judgement and state every assumption "
        + "you had to make - under ## Risks when planning.";

    public const string EmptyNotice =
        "No usable question was provided. Either send questions with concrete options or continue with the "
        + "work now.";

    public static NativeToolDefinition Definition { get; } = new(
        Name,
        Description,
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["questions"] = new JsonObject
                {
                    ["type"] = "array",
                    ["description"] = "Every question you need answered, ordered by importance.",
                    ["items"] = new JsonObject
                    {
                        ["type"] = "object",
                        ["properties"] = new JsonObject
                        {
                            ["header"] = new JsonObject
                            {
                                ["type"] = "string",
                                ["description"] = "Short label for the question, at most 16 characters.",
                            },
                            ["question"] = new JsonObject
                            {
                                ["type"] = "string",
                                ["description"] = "The question, written so a single answer resolves it.",
                            },
                            ["options"] = new JsonObject
                            {
                                ["type"] = "array",
                                ["description"] = "3 or 4 concrete suggested answers, each a real choice.",
                                ["items"] = new JsonObject { ["type"] = "string" },
                            },
                        },
                        ["required"] = new JsonArray("question", "options"),
                    },
                },
            },
            ["required"] = new JsonArray("questions"),
        });

    /// Tolerant parse: malformed or empty questions are dropped instead of failing the run.
    public static IReadOnlyList<AskUserQuestion> Parse(string arguments)
    {
        var questions = new List<AskUserQuestion>();
        try
        {
            var raw = JsonNode.Parse(arguments)?["questions"]?.AsArray();
            if (raw is null) return questions;
            foreach (var item in raw)
            {
                var prompt = Text(item?["question"]);
                if (prompt.Length == 0) continue;
                var options = (item?["options"] as JsonArray ?? new JsonArray())
                    .Select(Text)
                    .Where(option => option.Length > 0)
                    .Take(4)
                    .ToArray();
                var header = Text(item?["header"]);
                questions.Add(new AskUserQuestion(
                    $"q{questions.Count}",
                    header.Length == 0 ? $"Question {questions.Count + 1}" : header,
                    prompt,
                    options));
            }
        }
        catch (Exception) { return questions; }
        return questions;
    }

    private static string Text(JsonNode? node)
    {
        try { return node?.GetValue<string>()?.Trim() ?? string.Empty; }
        catch (Exception) { return string.Empty; }
    }

    /// Case- and punctuation-insensitive key used to spot a question that was already answered.
    public static string Fingerprint(string prompt) =>
        string.Join(' ', prompt
            .ToLowerInvariant()
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .Select(word => new string(word.Where(char.IsLetterOrDigit).ToArray()))
            .Where(word => word.Length > 0));

    public static string Transcript(IReadOnlyList<AskUserQuestion> questions, IReadOnlyList<string> answers) =>
        string.Join(
            "\n\n",
            questions.Select((question, index) =>
            {
                var answer = (index < answers.Count ? answers[index] : string.Empty).Trim();
                return $"Q: {question.Prompt}\nA: {(answer.Length == 0 ? "(no answer)" : answer)}";
            }));
}
