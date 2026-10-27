// Copyright (c) 2026 DOTS
// Runs Claude models through the user's installed, official `claude` CLI.

using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace DotsHarnessCore;

/// <summary>
/// The CLI is a complete agent: it runs its own tools in the workspace and
/// signs in with its own credentials. HerNess hands it the prompt and reads
/// the result; HerNess tools are not offered to it.
/// </summary>
public static class ClaudeCliClient
{
    /// <summary>The conversation the CLI runs for, where it works, and where its live text goes.</summary>
    public sealed record RunContext(string Workspace, string ConversationId, IProgress<string>? Text);

    private static readonly AsyncLocal<RunContext?> RunSlot = new();

    /// <summary>Flows with the async run that set it.</summary>
    public static RunContext? Run
    {
        get => RunSlot.Value;
        set => RunSlot.Value = value;
    }

    /// <summary>The CLI's own session per conversation, and how many turns it has seen.</summary>
    // ponytail: process memory, so after a restart the first turn sends the transcript once
    // and the CLI session starts over from it; persist this map if that costs too much.
    private sealed record Session(string Id, int Turns);
    private static readonly ConcurrentDictionary<string, Session> Sessions = new(StringComparer.Ordinal);

    public static async Task<NativeResponse> CompleteAsync(
        IReadOnlyList<NativeMessage> messages, string model, string effort, CancellationToken ct)
    {
        var run = Run;
        var turns = Turns(messages);
        var session = run is null ? null : Sessions.GetValueOrDefault(run.ConversationId);
        // An edited or rewound conversation no longer matches what the CLI saw.
        if (session is not null && session.Turns >= turns.Count) session = null;
        try
        {
            return await RunAsync(turns, session, run, model, effort, ct);
        }
        catch (NativeProviderException ex) when (session is not null
            && ex.Message.Contains("No conversation found", StringComparison.OrdinalIgnoreCase))
        {
            // The CLI no longer has that session (deleted, or another machine): start
            // a new one from the transcript. Other failures may follow real work, so they surface.
            Sessions.TryRemove(run!.ConversationId, out _);
            return await RunAsync(turns, null, run, model, effort, ct);
        }
    }

    private static async Task<NativeResponse> RunAsync(
        IReadOnlyList<NativeMessage> turns, Session? session, RunContext? run, string model, string effort, CancellationToken ct)
    {
        var executable = ExecutablePath()
            ?? throw new NativeProviderException("Claude Code CLI not found. Install it from claude.com/code, then run `claude update`.");
        var start = new ProcessStartInfo(executable)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var argument in new[] { "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                     "--permission-mode", "acceptEdits", "--model", model })
            start.ArgumentList.Add(argument);
        if (!string.IsNullOrWhiteSpace(effort) && effort != "none") { start.ArgumentList.Add("--effort"); start.ArgumentList.Add(effort); }
        if (session is not null) { start.ArgumentList.Add("--resume"); start.ArgumentList.Add(session.Id); }
        if (run?.Workspace is { Length: > 0 } workspace && Directory.Exists(workspace)) start.WorkingDirectory = workspace;

        using var process = Process.Start(start) ?? throw new NativeProviderException("Claude Code CLI could not start.");
        using var kill = ct.Register(() => { try { process.Kill(entireProcessTree: true); } catch { } });
        var stderr = process.StandardError.ReadToEndAsync(CancellationToken.None);
        await process.StandardInput.WriteAsync(Prompt(turns, session?.Turns ?? 0));
        process.StandardInput.Close();

        var texts = new List<string>();
        string? finalText = null, failure = null, sessionId = null;
        NativeUsage? usage = null;
        while (await process.StandardOutput.ReadLineAsync(CancellationToken.None) is { } line)
        {
            JsonNode? node;
            try { node = JsonNode.Parse(line); } catch { continue; }
            if (node?["session_id"]?.GetValue<string>() is { Length: > 0 } id) sessionId = id;
            switch (node?["type"]?.GetValue<string>())
            {
                case "stream_event":
                    if (node["event"]?["delta"] is JsonObject delta && delta["type"]?.GetValue<string>() == "text_delta"
                        && delta["text"]?.GetValue<string>() is { } chunk)
                        run?.Text?.Report(chunk);
                    break;
                case "assistant":
                    foreach (var block in node["message"]?["content"]?.AsArray() ?? [])
                        if (block?["type"]?.GetValue<string>() == "text" && block["text"]?.GetValue<string>() is { } text)
                        {
                            texts.Add(text);
                            // Separates this step's prose from the next one in the live view.
                            run?.Text?.Report("\n\n");
                        }
                    break;
                case "result":
                    if (node["is_error"]?.GetValue<bool>() == true)
                        failure = node["result"]?.GetValue<string>() ?? node["subtype"]?.GetValue<string>() ?? "error";
                    else finalText = node["result"]?.GetValue<string>();
                    if (node["usage"] is JsonObject u)
                        usage = new NativeUsage(
                            u["input_tokens"]?.GetValue<int>() ?? 0,
                            u["output_tokens"]?.GetValue<int>() ?? 0,
                            u["cache_read_input_tokens"]?.GetValue<int>(),
                            u["cache_creation_input_tokens"]?.GetValue<int>());
                    break;
            }
        }
        await process.WaitForExitAsync(CancellationToken.None);
        ct.ThrowIfCancellationRequested();
        if (failure is not null) throw new NativeProviderException(failure);
        if (process.ExitCode != 0)
        {
            var error = (await stderr).Trim();
            throw new NativeProviderException(error.Length == 0 ? $"claude exited with {process.ExitCode}" : error[..Math.Min(error.Length, 4_000)]);
        }
        var content = texts.Count == 0 ? finalText ?? "" : string.Join("\n\n", texts);
        // The CLI now holds every turn so far plus this reply.
        if (run is not null && sessionId is not null) Sessions[run.ConversationId] = new Session(sessionId, turns.Count + 1);
        return new NativeResponse(new NativeMessage("assistant", content), usage);
    }

    /// <summary>The user's own install first; `claude update` keeps whichever one this finds current.</summary>
    public static string? ExecutablePath()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var names = OperatingSystem.IsWindows() ? new[] { "claude.exe", "claude.cmd" } : new[] { "claude" };
        var directories = new[] { Path.Combine(home, ".local", "bin"), Path.Combine(home, ".claude", "local") }
            .Concat(OperatingSystem.IsWindows()
                ? new[] { Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm") }
                : new[] { "/usr/local/bin", "/usr/bin" })
            .Concat((Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries));
        return directories.SelectMany(directory => names.Select(name => Path.Combine(directory, name))).FirstOrDefault(File.Exists);
    }

    /// <summary>
    /// The CLI keeps its own system prompt and tools, so HerNess's system prompt,
    /// notices and other providers' tool traffic stay out.
    /// </summary>
    internal static List<NativeMessage> Turns(IReadOnlyList<NativeMessage> messages) =>
        messages.Where(message => message.Role is "user" or "assistant" && message.SystemKind is null
            && !string.IsNullOrWhiteSpace(message.Content)).ToList();

    /// <summary>
    /// A resumed session already holds the first <paramref name="seen"/> turns, so only
    /// what came after travels (turns another provider answered in between, then the
    /// new request). A new session gets the whole transcript once.
    /// </summary>
    internal static string Prompt(IReadOnlyList<NativeMessage> turns, int seen)
    {
        if (turns.Count == 0) return "";
        var last = turns[^1].Content;
        var history = turns.Skip(seen).Take(turns.Count - 1 - seen)
            .Select(message => (message.Role == "user" ? "User: " : "Assistant: ") + message.Content).ToList();
        if (history.Count == 0) return last;
        var heading = seen == 0 ? "Earlier in this conversation:" : "Since your last reply in this conversation:";
        return heading + "\n\n" + string.Join("\n\n", history) + "\n\n---\n\n" + last;
    }
}
