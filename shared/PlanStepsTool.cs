// Copyright (c) 2026 DOTS
// Progress ledger: the agent keeps a short, visible step list for multi-step work.

using System.Text.Json;
using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public sealed record PlanStep(string Title, string Status);

public static class PlanStepsTool
{
    public const string Name = "update_plan";

    private static readonly (string Status, string Marker)[] Markers =
        [("pending", "☐"), ("in_progress", "▸"), ("done", "☑")];

    public static NativeToolDefinition Definition { get; } = new(
        Name,
        "Record or update the step list for the work in progress, so the user can follow it and you "
        + "never re-derive what is already settled. Use it only for complex work that "
        + "needs a plan; never for simple work, and never write a single-step plan. Send the complete list on every call: "
        + "exactly one step may be in_progress, and steps already finished stay in the list as done. "
        + "Call it again right after finishing a step, not in a separate turn of its own.",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["steps"] = new JsonObject
                {
                    ["type"] = "array",
                    ["description"] = "The full ordered step list, not just the changed entries.",
                    ["items"] = new JsonObject
                    {
                        ["type"] = "object",
                        ["properties"] = new JsonObject
                        {
                            ["title"] = new JsonObject { ["type"] = "string", ["description"] = "Short imperative description of the step." },
                            ["status"] = new JsonObject { ["type"] = "string", ["enum"] = new JsonArray("pending", "in_progress", "done") },
                        },
                        ["required"] = new JsonArray("title", "status"),
                    },
                },
            },
            ["required"] = new JsonArray("steps"),
        });

    public static string Execute(string arguments)
    {
        const string invalid = "The plan must be a list of steps, each with a title and a status of pending, in_progress, or done.";
        try
        {
            if (JsonNode.Parse(arguments)?["steps"] is not JsonArray raw || raw.Count == 0) return invalid;
            var lines = new List<string>();
            var done = 0;
            foreach (var step in raw)
            {
                var title = step?["title"]?.GetValue<string>()?.Trim();
                var status = step?["status"]?.GetValue<string>();
                var marker = Markers.FirstOrDefault(m => m.Status == status).Marker;
                if (string.IsNullOrEmpty(title) || marker is null) return invalid;
                if (status == "done") done++;
                lines.Add($"{marker} {title}");
            }
            return $"Plan updated: {lines.Count} steps, {done} done.\n" + string.Join("\n", lines);
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException)
        {
            return invalid;
        }
    }

    /// <summary>
    /// The plan the agent last recorded since the user's latest message, read back from
    /// the transcript so the live card needs no state of its own. Empty when there is none.
    /// </summary>
    public static IReadOnlyList<PlanStep> CurrentSteps(IEnumerable<ChatMessage> messages)
    {
        foreach (var message in messages.Reverse())
        {
            if (message.Kind == ChatKind.User) return [];
            if (message.Kind != ChatKind.Tool || !message.Text.StartsWith("✓ " + Name, StringComparison.Ordinal)
                || message.RawToolOutput is not { } output) continue;
            var steps = output.Split('\n')
                .SelectMany(line => Markers.Where(m => line.StartsWith(m.Marker + " ", StringComparison.Ordinal))
                    .Select(m => new PlanStep(line[2..], m.Status)))
                .ToList();
            if (steps.Count > 0) return steps;
        }
        return [];
    }
}
