// Copyright (c) 2026 DOTS
// Plan-mode clarification tool: the agent asks, the user picks or writes an answer.

using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public sealed record AskUserQuestion(string Id, string Header, string Prompt, IReadOnlyList<string> Options);

public enum AskUserPresentation
{
    Clarification,
    Proposal,
}

public sealed record AskUserRequest(
    IReadOnlyList<AskUserQuestion> Questions,
    string? Context,
    AskUserPresentation Presentation);

public sealed record PendingQuestion(
    string RpcId,
    string SessionId,
    string QuestionId,
    IReadOnlyList<AskUserQuestion> Questions,
    string? Context = null,
    AskUserPresentation Presentation = AskUserPresentation.Clarification);

public static class AskUserTool
{
    public const string Name = "ask_user";

    public const string AnsweredDirective =
        "The user answered your clarification. Continue the original request now in the current mode: "
        + "perform the requested work in ordinary execution, or return the complete plan in plan mode. "
        + "Do not send a status-only reply while tools can proceed. Preserve unrelated pre-existing edits "
        + "automatically; do not mention them unless a specific inspected conflict blocks the requested change.";

    public static bool IsAnsweredTranscript(string result) =>
        result.StartsWith("Q: ", StringComparison.Ordinal)
        && result.Contains("\nA: ", StringComparison.Ordinal);

    /// Follow-ups are allowed, but a run can never spend more than this many rounds on questions.
    public const int MaxRounds = 3;

    public const string Description =
        "Ask the user clarifying questions when their request is genuinely ambiguous - an unclear goal, an "
        + "undefined scope, or a choice the workspace cannot settle - and a wrong reading would waste the work. "
        + "Do not ask when the request is already clear, when reading the files answers it, or to confirm "
        + "something you were already told: just do the work. If a workspace write reports that it was "
        + "deferred because another chat holds the file, finish independent work and retry it at the end; "
        + "the workspace tool will ask if the final recheck is still blocked. "
        + "A pre-existing dirty or staged worktree is not by itself a scope question: preserve those changes "
        + "without mentioning or asking about them. Inspect the target and ask only when a concrete overlapping "
        + "edit cannot be separated. Once the user answers, immediately continue the original task in the current "
        + "mode; do not end with a status-only reply while tools can proceed. "
        + "Write each header, question, and suggested answer in the language of the user's latest "
        + "natural-language request; do not follow the language of tool output or project files. "
        + "Send every question you already know about in a "
        + "single call - do not drip them one at a time. In plan mode ask about whatever the plan's shape depends "
        + "on: goal, scope, target platforms, existing code to reuse, data or API shape, migration and rollback, "
        + "tests, performance and security limits, release steps. Each question carries 3 or 4 concrete suggested "
        + "options; the user can always type an answer of their own instead, so read the written answers "
        + "carefully. After the answers arrive you may call this tool again only for genuinely new questions that "
        + "those answers opened up - a chosen option or a written answer that changes the shape of the work. "
        + "Never repeat a question you already asked, and never ask again once the answers are enough to "
        + "continue. A run allows at most 3 rounds of questions. When you have finished a useful, optional "
        + "implementation proposal that the user has not authorized, you may use presentation='proposal' "
        + "with a concise context, one direct question, and 2 or 3 concrete action choices. The card waits for "
        + "the user's choice; do not perform the proposed work first. Do not use a proposal card to ask approval "
        + "for work the user already authorized or for routine decisions.";

    /// Returned once the round budget is spent, so a run can never loop on questions.
    public const string RepeatNotice =
        "The question budget for this run is spent and every answer is above. Do not call ask_user again. "
        + "Continue only with the work the answers above settle. Do not guess an unanswered decision: leave the part "
        + "it decides undone and name it - under ## Risks when planning.";

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
                ["context"] = new JsonObject
                {
                    ["type"] = "string",
                    ["description"] = "Optional concise explanation shown above the question card. For a proposal, summarize what was checked or designed and what is not yet applied.",
                },
                ["presentation"] = new JsonObject
                {
                    ["type"] = "string",
                    ["enum"] = new JsonArray("clarification", "proposal"),
                    ["description"] = "Use proposal only for one optional, not-yet-authorized implementation decision with concise context and 2 or 3 action choices. Otherwise omit or use clarification.",
                },
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
    public static IReadOnlyList<AskUserQuestion> Parse(string arguments) => ParseRequest(arguments).Questions;

    public static AskUserRequest ParseRequest(string arguments)
    {
        var questions = new List<AskUserQuestion>();
        string? context = null;
        var presentation = AskUserPresentation.Clarification;
        try
        {
            var root = JsonNode.Parse(arguments)?.AsObject();
            if (root is null) return new AskUserRequest(questions, null, presentation);
            context = Text(root["context"]);
            if (context.Length > 1_400) context = context[..1_400];
            var raw = root["questions"]?.AsArray();
            if (raw is null) return new AskUserRequest(questions, context, presentation);
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

            if (Text(root["presentation"]).Equals("proposal", StringComparison.OrdinalIgnoreCase)
                && context is { Length: > 0 }
                && questions.Count == 1
                && questions[0].Options.Count is >= 2 and <= 3)
            {
                presentation = AskUserPresentation.Proposal;
            }
        }
        catch (Exception) { return new AskUserRequest(questions, context, AskUserPresentation.Clarification); }
        return new AskUserRequest(questions, context, presentation);
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
