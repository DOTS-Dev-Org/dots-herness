// Copyright (c) 2026 DOTS
// Bots: named assistants with their own instructions, model and running chat.
// Mirrors Bots.swift on macOS and reads the same one-file-per-bot JSON layout.

using System.Text.Json;
using System.Text.Json.Serialization;

using PluginRuntime;

namespace DotsHarnessCore;

public sealed class BotMessage
{
    [JsonPropertyName("id")] public string Id { get; set; } = Guid.NewGuid().ToString();
    /// <summary>"user" or "assistant".</summary>
    [JsonPropertyName("role")] public string Role { get; set; } = "user";
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("date")] public DateTimeOffset Date { get; set; } = DateTimeOffset.Now;
    /// <summary>False for a user message the bot has not been handed yet. Older chats were all answered.</summary>
    [JsonPropertyName("delivered")] public bool Delivered { get; set; } = true;

    [JsonIgnore] public bool IsUser => Role == "user";
}

public sealed class Bot
{
    [JsonPropertyName("id")] public string Id { get; set; } = Guid.NewGuid().ToString();
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("symbol")] public string Symbol { get; set; } = "sparkles";
    [JsonPropertyName("instructions")] public string Instructions { get; set; } = "";
    /// <summary>Empty follows the app's selected model.</summary>
    [JsonPropertyName("modelID")] public string ModelId { get; set; } = "";
    /// <summary>Empty leaves the level to the app.</summary>
    [JsonPropertyName("effort")] public string Effort { get; set; } = "";
    /// <summary>When set, the bot works as an agent with tools inside this folder.</summary>
    [JsonPropertyName("workspacePath")] public string WorkspacePath { get; set; } = "";
    [JsonPropertyName("messages")] public List<BotMessage> Messages { get; set; } = [];
    [JsonPropertyName("updatedAt")] public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.Now;

    public Bot Copy() => JsonSerializer.Deserialize<Bot>(JsonSerializer.Serialize(this))!;

    /// <summary>Same names as macOS, so a bot keeps its symbol across platforms; the UI maps them to glyphs.</summary>
    public static readonly string[] Symbols =
    [
        "sparkles", "magnifyingglass", "chevron.left.forwardslash.chevron.right", "pencil.line",
        "chart.bar", "globe", "book", "lightbulb", "briefcase", "heart",
    ];

    public static string Glyph(string symbol) => symbol switch
    {
        "magnifyingglass" => "⌕",
        "chevron.left.forwardslash.chevron.right" => "</>",
        "pencil.line" => "✎",
        "chart.bar" => "▥",
        "globe" => "◍",
        "book" => "▤",
        "lightbulb" => "☀",
        "briefcase" => "▣",
        "heart" => "♥",
        _ => "✦",
    };

    /// <summary>Starting points offered on the empty Bots screen.</summary>
    public static IReadOnlyList<Bot> Presets(LocalizationService copy) =>
    [
        new() { Name = copy.Get("bots.preset.assistant"), Symbol = "sparkles",
            Instructions = "You are a capable personal assistant. Be direct, ask when a request is ambiguous, and keep track of what the user told you earlier in this chat." },
        new() { Name = copy.Get("bots.preset.researcher"), Symbol = "magnifyingglass",
            Instructions = "You are a careful researcher. Separate what is established from what is uncertain, name your sources when you have them, and say plainly when you do not know." },
        new() { Name = copy.Get("bots.preset.coder"), Symbol = "chevron.left.forwardslash.chevron.right",
            Instructions = "You are a senior software engineer. Prefer the smallest change that solves the problem, explain trade-offs briefly, and show code rather than describing it." },
    ];
}

/// <summary>
/// Bots on disk plus the replies in progress. Call it from the UI thread: replies resume
/// there, and <see cref="Changed"/> fires there.
/// </summary>
public sealed class BotStore
{
    /// <summary>Turns of history sent with each message; older ones stay on screen only.</summary>
    public const int HistoryLimit = 40;

    private static readonly JsonSerializerOptions Json = new() { WriteIndented = false };

    private readonly string _root;
    private readonly RouterController _router;
    private readonly SupportPaths _paths;
    private readonly LocalizationService _copy;
    private readonly Func<string> _systemPrompt;
    private readonly Dictionary<string, CancellationTokenSource> _runs = [];
    private readonly Dictionary<string, AgentBridge> _hosts = [];
    private readonly Dictionary<string, HashSet<string>> _relayed = [];
    private bool _loaded;

    public BotStore(string root, RouterController router, SupportPaths paths, LocalizationService copy, Func<string> systemPrompt)
    {
        _root = root;
        _router = router;
        _paths = paths;
        _copy = copy;
        _systemPrompt = systemPrompt;
    }

    public List<Bot> Bots { get; private set; } = [];
    public string? SelectedBotId { get; set; }
    public Dictionary<string, string> Errors { get; } = [];
    public event Action? Changed;

    public bool IsBusy(string id) => _runs.ContainsKey(id);

    public void LoadIfNeeded()
    {
        if (_loaded) return;
        _loaded = true;
        if (Directory.Exists(_root))
        {
            Bots = Directory.GetFiles(_root, "*.json")
                .Select(file => { try { return JsonSerializer.Deserialize<Bot>(File.ReadAllText(file), Json); } catch { return null; } })
                .OfType<Bot>()
                .OrderByDescending(bot => bot.UpdatedAt)
                .ToList();
        }
        SelectedBotId ??= Bots.FirstOrDefault()?.Id;
    }

    public Bot? Find(string? id) => id is null ? null : Bots.FirstOrDefault(bot => bot.Id == id);

    /// <summary>Adds or replaces a bot. List order is creation order, so editing never reshuffles it.</summary>
    public void Upsert(Bot bot)
    {
        bot.UpdatedAt = DateTimeOffset.Now;
        var index = Bots.FindIndex(existing => existing.Id == bot.Id);
        if (index >= 0) Bots[index] = bot;
        else Bots.Insert(0, bot);
        Write(bot);
        Changed?.Invoke();
    }

    public void Delete(string id)
    {
        Stop(id);
        try { File.Delete(FilePath(id)); } catch (IOException) { }
        Bots.RemoveAll(bot => bot.Id == id);
        if (SelectedBotId == id) SelectedBotId = Bots.FirstOrDefault()?.Id;
        Changed?.Invoke();
    }

    public void ClearHistory(string id)
    {
        if (Find(id) is not { } bot) return;
        Stop(id);
        bot.Messages.Clear();
        Upsert(bot);
    }

    public void Stop(string id)
    {
        if (_runs.TryGetValue(id, out var run)) run.Cancel();
        if (_hosts.TryGetValue(id, out var host)) host.Stop();
    }

    /// <summary>
    /// Sends a message. While the bot is busy the message joins the work in progress: an
    /// agent is steered with it, otherwise it waits and is answered with the others that waited.
    /// </summary>
    public void Send(string text, string id)
    {
        text = text.Trim();
        if (text.Length == 0 || Find(id) is not { } bot) return;
        bot.Messages.Add(new BotMessage { Role = "user", Text = text, Delivered = false });
        Upsert(bot);
        Errors.Remove(id);
        if (!IsBusy(id)) { _ = StartAsync(id); return; }
        // Steering restarts the agent's current step with this message folded in.
        if (_hosts.TryGetValue(id, out var host)) _ = host.SendAsync(text, PromptMode.Steer);
    }

    private void MarkDelivered(string id, Func<BotMessage, bool>? matches = null)
    {
        if (Find(id) is not { } bot) return;
        var pending = bot.Messages.Where(m => !m.Delivered && (matches?.Invoke(m) ?? true)).ToList();
        if (pending.Count == 0) return;
        foreach (var message in pending) message.Delivered = true;
        Upsert(bot);
    }

    private async Task StartAsync(string id)
    {
        // ponytail: replies arrive whole; the C# router has no delta callback for plain completions yet.
        using var run = new CancellationTokenSource();
        _runs[id] = run;
        Changed?.Invoke();
        try
        {
            do
            {
                MarkDelivered(id);
                if (Find(id) is not { } bot) break;
                await ReplyAsync(bot, run.Token);
                // Messages that waited are answered together, as one turn.
            } while (!run.IsCancellationRequested && Find(id)?.Messages.Any(m => !m.Delivered) == true);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { Errors[id] = ex.Message; }
        finally
        {
            _runs.Remove(id);
            Changed?.Invoke();
        }
    }

    /// <summary>Adds a reply to the chat, as one message per part the bot separated.</summary>
    private void Post(string text, string id)
    {
        var parts = SplitMessages(text).Select(part => part.Trim()).Where(part => part.Length > 0).ToList();
        if (parts.Count == 0 || Find(id) is not { } bot) return;
        bot.Messages.AddRange(parts.Select(part => new BotMessage { Role = "assistant", Text = part }));
        Upsert(bot);
    }

    /// <summary>Cuts a reply at lines holding only <c>---</c>, outside code fences.</summary>
    public static List<string> SplitMessages(string text)
    {
        var parts = new List<string> { "" };
        var inFence = false;
        foreach (var line in text.Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith("```", StringComparison.Ordinal)) inFence = !inFence;
            if (!inFence && trimmed == "---") parts.Add("");
            else parts[^1] += line + "\n";
        }
        return parts;
    }

    /// <summary>Consecutive messages from one side as a single turn, joined the way the bot is told to separate them.</summary>
    public static List<BotMessage> Turns(IEnumerable<BotMessage> messages)
    {
        var turns = new List<BotMessage>();
        foreach (var message in messages)
        {
            if (turns.Count > 0 && turns[^1].Role == message.Role) turns[^1].Text += "\n---\n" + message.Text;
            else turns.Add(new BotMessage { Role = message.Role, Text = message.Text });
        }
        return turns;
    }

    public string UsableModel(string id) => !string.IsNullOrWhiteSpace(id) && _router.Models.Contains(id) ? id : "";

    private async Task ReplyAsync(Bot bot, CancellationToken ct)
    {
        var model = UsableModel(bot.ModelId);
        if (ScheduledTaskRunner.NormalizeWorkspace(bot.WorkspacePath) is { } workspace)
        {
            await AgentReplyAsync(bot, workspace, ct);
            return;
        }
        var messages = new List<NativeMessage> { new("system", Persona(bot)) };
        messages.AddRange(Turns(bot.Messages.TakeLast(HistoryLimit))
            .Select(turn => new NativeMessage(turn.IsUser ? "user" : "assistant", turn.Text)));
        var response = await _router.CompleteAsync(messages, [], model.Length == 0 ? null : model, ct,
            effortOverride: bot.Effort.Length == 0 ? null : bot.Effort);
        ct.ThrowIfCancellationRequested();
        Post(response.Message.Content, bot.Id);
    }

    /// <summary>
    /// One agent run in a transient host, the way scheduled tasks run: the run's own chat
    /// is removed afterwards because the bot keeps the transcript.
    /// </summary>
    private async Task AgentReplyAsync(Bot bot, string workspace, CancellationToken ct)
    {
        // ponytail: the agent follows the app's model; a per-bot model needs a model override on AgentBridge.
        var host = new AgentBridge(_router, _paths) { NonInteractive = true };
        host.UpdateSystemPrompt(_systemPrompt() + "\n\n" + Persona(bot) + "\n\n" + AgentChatStyle);
        await host.StartAsync(workspace);
        host.SetSandboxExecution([workspace], networkAccess: false);
        if (!_router.HasActiveRoute) throw new InvalidOperationException(host.Status);
        await host.NewConversationAsync(workspace);
        if (host.SelectedId is not { } conversationId) throw new InvalidOperationException(_copy.Get("bots.error.noReply"));

        // The user's latest messages are one turn; everything before it is context.
        var turns = Turns(bot.Messages.TakeLast(HistoryLimit));
        var latest = turns.Count > 0 ? turns[^1].Text : "";
        var earlier = turns.Take(Math.Max(turns.Count - 1, 0)).Select(t => $"{(t.IsUser ? "User" : "You")}: {t.Text}").ToList();
        var prompt = earlier.Count == 0 ? latest
            : $"Earlier in this chat:\n{string.Join("\n\n", earlier)}\n\nNew message from the user:\n{latest}";

        _relayed[bot.Id] = [];
        _hosts[bot.Id] = host;
        // ponytail: polls the run's chat every 0.3 s, like macOS.
        using var relay = new PeriodicTimer(TimeSpan.FromMilliseconds(300));
        var send = host.SendAsync(prompt);
        try
        {
            while (!send.IsCompleted && !ct.IsCancellationRequested)
            {
                Relay(host, conversationId, bot.Id);
                await relay.WaitForNextTickAsync(CancellationToken.None);
            }
            if (ct.IsCancellationRequested) host.Stop();
            await send;
            // A steered run continues after the first send returns.
            while (host.Conversations.FirstOrDefault(c => c.Id == conversationId)?.Running == true && !ct.IsCancellationRequested)
            {
                Relay(host, conversationId, bot.Id);
                await relay.WaitForNextTickAsync(CancellationToken.None);
            }
            Relay(host, conversationId, bot.Id);
            ct.ThrowIfCancellationRequested();
            var last = host.Conversations.FirstOrDefault(c => c.Id == conversationId)?.Messages.LastOrDefault();
            var output = last?.Text.Trim() ?? "";
            if (last?.Kind != ChatKind.Assistant || output.Length == 0)
                throw new InvalidOperationException(output.Length == 0 ? _copy.Get("bots.error.noReply") : output);
        }
        finally
        {
            _hosts.Remove(bot.Id);
            host.DeleteConversation(conversationId);
        }
    }

    /// <summary>Posts what the agent has said so far in its run, each message once.</summary>
    private void Relay(AgentBridge host, string conversationId, string id)
    {
        var messages = host.Conversations.FirstOrDefault(c => c.Id == conversationId)?.Messages.ToList() ?? [];
        foreach (var message in messages.Where(m => m.Kind == ChatKind.Assistant && !m.Streaming))
            if (_relayed[id].Add(message.Id)) Post(message.Text, id);
        // The first user message is the run's prompt; later ones are steers the agent accepted.
        var steers = messages.Where(m => m.Kind == ChatKind.User).Skip(1).Select(m => m.Text).ToHashSet();
        if (steers.Count > 0) MarkDelivered(id, m => steers.Contains(m.Text));
    }

    public const string ChatStyle =
        "You talk with the user in a messaging app. Write the way a person texts: short, natural messages, " +
        "no headings and no preamble. When several messages read better than one (a quick acknowledgement, " +
        "then the answer, then a follow-up question), put a line holding only --- between them; each part " +
        "is delivered as its own message. Send a single message when one is enough.\n\n" +
        "The user may also send several messages in a row; they reach you joined by --- lines. A later " +
        "one usually adds to or corrects the earlier request, so treat them as one request with the " +
        "addition folded in. Answer them separately only when they are clearly unrelated.";

    public const string AgentChatStyle =
        "Anything you write before using a tool is delivered to the user right away as its own message. " +
        "When asked to do something, first say briefly what you are about to do, send a short update when " +
        "a long task reaches a milestone, and finish with the result.\n\n" +
        "A message that arrives while you are working usually adds to or corrects the task in progress: " +
        "keep the work you have done, fold the addition in and carry on. Treat it as a new task only when " +
        "it is clearly unrelated, and then finish the current task first unless the user tells you to stop.";

    public static string Persona(Bot bot)
    {
        var instructions = bot.Instructions.Trim();
        return $"You are \"{bot.Name}\", a bot the user set up in HerNess."
            + (instructions.Length == 0 ? "" : "\n\n" + instructions)
            + "\n\n" + ChatStyle;
    }

    private string FilePath(string id) => Path.Combine(_root, id + ".json");

    private void Write(Bot bot)
    {
        Directory.CreateDirectory(_root);
        var path = FilePath(bot.Id);
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(bot, Json));
        File.Move(path + ".tmp", path, overwrite: true);
    }
}
