// Copyright (c) 2026 DOTS
// Agent-facing tool for a long-lived interactive shell that outlives run_command's
// bounded one-shot budget. Mirrors the macOS TerminalSessionTool; the session itself is
// the platform terminal (ConPTY on Windows, forkpty on Linux).

using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public sealed class TerminalSessionTool
{
    public const string Name = "terminal_session";

    /// <summary>One agent shell, as the Tasks dock tab shows it.</summary>
    public sealed record SessionInfo(string Id, string Title, bool IsRunning, string Output, DateTime StartedAt, int? ExitCode);

    private sealed class AgentTerminal
    {
        public required string Id { get; init; }
        public required TerminalSession Session { get; init; }
        public required string WorkspacePath { get; init; }
        public string Title { get; set; } = "";
    }

    private readonly object _gate = new();
    private readonly Dictionary<string, List<AgentTerminal>> _sessions = new(StringComparer.Ordinal);

    public static NativeToolDefinition Definition { get; } = new(
        Name,
        "Manage a long-lived interactive shell for processes that need to remain available beyond one run_command call "
        + "(a dev server, a backend, a file watcher). Start one, read its output, send input, and stop it when done. "
        + "Prefer run_command for one-off checks (default 120 seconds, maximum 600); this session has no command timeout. "
        + "Pass command to run it in the session; the shell stays alive afterwards, so read the output and stop the session "
        + "when you are done. Leave a process running only if the user asked for it; otherwise stop it before finishing "
        + "and report anything still running.",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["action"] = new JsonObject
                {
                    ["type"] = "string",
                    ["enum"] = new JsonArray("list", "start", "read", "send", "stop"),
                    ["description"] = "Operation to perform.",
                },
                ["session_id"] = new JsonObject
                {
                    ["type"] = "string",
                    ["description"] = "Target session, required for read/send/stop.",
                },
                ["command"] = new JsonObject
                {
                    ["type"] = "string",
                    ["description"] = "Shell command to run in the session (start action).",
                },
                ["description"] = new JsonObject
                {
                    ["type"] = "string",
                    ["description"] = "Short label for the session, shown to the user (start action).",
                },
                ["input"] = new JsonObject
                {
                    ["type"] = "string",
                    ["description"] = "Text to send (send action). A newline is appended if missing.",
                },
                ["max_chars"] = new JsonObject
                {
                    ["type"] = "integer",
                    ["description"] = "Trailing output to return for read (default 4000).",
                },
            },
            ["required"] = new JsonArray("action"),
        });

    /// <summary>Starting a shell and typing into it both change the machine, so both ask.</summary>
    public static bool ActionRequiresApproval(string? action) => action is "start" or "send";

    /// <summary>Every session this conversation owns.</summary>
    private List<AgentTerminal> Sessions(string conversationId)
    {
        lock (_gate)
        {
            if (!_sessions.TryGetValue(conversationId, out var sessions))
            {
                sessions = [];
                _sessions[conversationId] = sessions;
            }
            return sessions;
        }
    }

    public string Execute(
        NativeToolCall call,
        string conversationId,
        string workspacePath,
        SshTarget? remoteTarget,
        bool sandboxed = false,
        IReadOnlyList<string>? sandboxWritableRoots = null,
        bool sandboxNetworkAccess = false)
    {
        var input = JsonNode.Parse(call.Arguments)?.AsObject() ?? new JsonObject();
        var action = input["action"]?.GetValue<string>()?.Trim().ToLowerInvariant() ?? "";
        var sessionId = input["session_id"]?.GetValue<string>()?.Trim() ?? "";
        var command = input["command"]?.GetValue<string>() ?? "";
        var description = input["description"]?.GetValue<string>() ?? "";
        var sent = input["input"]?.GetValue<string>() ?? "";
        var limit = Math.Max(200, input["max_chars"]?.GetValue<int>() ?? 4000);

        switch (action)
        {
            case "list":
            {
                var sessions = Sessions(conversationId);
                lock (_gate)
                {
                    if (sessions.Count == 0) return "No agent terminal sessions.";
                    return string.Join('\n', sessions.Select(session =>
                        $"{session.Id} [{(session.Session.IsRunning ? "running" : "exited")}] {session.Title}"));
                }
            }

            case "start":
            {
                if (string.IsNullOrWhiteSpace(workspacePath) && remoteTarget is null)
                    return "Tool error: select a project workspace before starting a terminal session.";
                var session = TerminalSession.Create(
                    workspacePath,
                    remoteTarget,
                    sandboxed,
                    sandboxWritableRoots,
                    sandboxNetworkAccess);
                session.Start();
                if (!session.IsRunning)
                {
                    var failure = session.Output.Trim();
                    session.Dispose();
                    return "Tool error: " + (failure.Length == 0 ? "the terminal could not start." : failure);
                }

                var agent = new AgentTerminal
                {
                    Id = Guid.NewGuid().ToString("N"),
                    Session = session,
                    WorkspacePath = workspacePath,
                    Title = description.Length > 0 ? description : command.Length > 0 ? command : "shell",
                };
                var sessions = Sessions(conversationId);
                lock (_gate) sessions.Add(agent);

                if (command.Length == 0)
                    return $"Started session {agent.Id}. Use read to see output.";
                session.SendInput(command);
                return $"Started session {agent.Id} and ran the command in it. "
                    + "Use read to see the output, then stop the session when you are done.";
            }

            case "read":
            {
                var agent = Find(conversationId, sessionId);
                if (agent is null) return "Tool error: unknown session_id.";
                var output = agent.Session.Output ?? "";
                var tail = output.Length <= limit ? output : output[^limit..];
                var state = agent.Session.IsRunning ? "running" : "exited";
                return $"session {agent.Id} [{state}]\n{tail}";
            }

            case "send":
            {
                var agent = Find(conversationId, sessionId);
                if (agent is null) return "Tool error: unknown session_id.";
                if (!agent.Session.IsRunning) return "Tool error: session has exited.";
                var payload = sent.EndsWith('\n') ? sent : sent + "\n";
                agent.Session.SendInput(payload);
                return "Sent. Call read to see the result.";
            }

            case "stop":
            {
                var agent = Find(conversationId, sessionId);
                if (agent is null) return "Tool error: unknown session_id.";
                agent.Session.Stop();
                var sessions = Sessions(conversationId);
                lock (_gate) sessions.RemoveAll(item => item.Id == agent.Id);
                return $"Stopped session {agent.Id}.";
            }

            default:
                return $"Tool error: unknown action '{action}'.";
        }
    }

    private AgentTerminal? Find(string conversationId, string sessionId)
    {
        if (string.IsNullOrWhiteSpace(sessionId)) return null;
        var sessions = Sessions(conversationId);
        lock (_gate)
        {
            return sessions.FirstOrDefault(session => string.Equals(session.Id, sessionId, StringComparison.Ordinal));
        }
    }

    /// <summary>Stops every session this tool owns. Called when the workspace changes.</summary>
    public void StopAll()
    {
        List<AgentTerminal> sessions;
        lock (_gate)
        {
            sessions = _sessions.Values.SelectMany(list => list).ToList();
            _sessions.Clear();
        }
        foreach (var session in sessions) session.Session.Dispose();
    }

    /// <summary>The agent shells of one conversation, newest last.</summary>
    public IReadOnlyList<SessionInfo> ListSessions(string conversationId)
    {
        var sessions = Sessions(conversationId);
        lock (_gate)
        {
            return sessions.Select(session => new SessionInfo(
                session.Id,
                session.Title,
                session.Session.IsRunning,
                session.Session.Output ?? "",
                session.Session.StartedAt,
                session.Session.ExitCode)).ToList();
        }
    }

    /// <summary>Stops one agent shell by id.</summary>
    public bool Stop(string conversationId, string sessionId)
    {
        var agent = Find(conversationId, sessionId);
        if (agent is null) return false;
        agent.Session.Stop();
        var sessions = Sessions(conversationId);
        lock (_gate) sessions.RemoveAll(item => item.Id == agent.Id);
        return true;
    }
}
