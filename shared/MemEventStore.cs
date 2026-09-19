// Copyright (c) 2026 DOTS
// Read-only view over the workspace's .mem/events/*.json log, for pattern mining only.
// This never writes to .mem — that log is a separate signed Merkle/DAG store this app does not produce.

using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public sealed record MemEvent(string EventId, long Lamport, DateTimeOffset CreatedAt, string Type, string? CommandSummary, string? RunId);

public static class MemEventStore
{
    private const int MaximumEventFiles = 5_000;

    public static IReadOnlyList<MemEvent> ReadToolExecutedEvents(string workspace)
    {
        var directory = Path.Combine(workspace, ".mem", "events");
        if (!Directory.Exists(directory)) return Array.Empty<MemEvent>();

        var results = new List<MemEvent>();
        IEnumerable<string> files;
        try { files = Directory.EnumerateFiles(directory, "*.json").Take(MaximumEventFiles); }
        catch { return Array.Empty<MemEvent>(); }

        foreach (var file in files)
        {
            try
            {
                var node = JsonNode.Parse(File.ReadAllText(file))?.AsObject();
                if (node is null) continue;
                if (node["type"]?.GetValue<string>() != "tool.executed") continue;
                var payload = node["payload"]?.AsObject();
                var eventId = node["eventId"]?.GetValue<string>() ?? Path.GetFileNameWithoutExtension(file);
                var lamport = node["lamport"]?.GetValue<long>() ?? 0;
                var createdAt = DateTimeOffset.TryParse(node["createdAt"]?.GetValue<string>(), out var parsed) ? parsed : DateTimeOffset.MinValue;
                var commandSummary = payload?["commandSummary"]?.GetValue<string>();
                var runId = payload?["runId"]?.GetValue<string>();
                results.Add(new MemEvent(eventId, lamport, createdAt, "tool.executed", commandSummary, runId));
            }
            catch { }
        }

        return results.OrderBy(e => e.Lamport).ThenBy(e => e.CreatedAt).ToList();
    }
}
