// Copyright (c) 2026 DOTS
// Folds DSH session events into the WPF conversation surface.
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using HarnessPluginKit;

namespace DotsHarnessCore;

public enum ChatKind
{
    User,
    Assistant,
    Tool,
    System,
}

public enum PromptMode
{
    Queue,
    Steer,
}

public enum PromptPlacement
{
    Queued,
    Steering,
    Context,
}

public static class PromptModeExtensions
{
    public static string ToWireValue(this PromptMode mode) => mode switch
    {
        PromptMode.Steer => "steer",
        _ => "queue",
    };
}

public sealed class PendingPrompt : PluginRuntime.ObservableObject
{
    private string _id = Guid.NewGuid().ToString();
    private string _text = "";
    private PromptMode _mode;
    private PromptPlacement _placement;

    public string Id { get => _id; set => SetProperty(ref _id, value); }
    public string Text { get => _text; set => SetProperty(ref _text, value); }
    public PromptMode Mode { get => _mode; set => SetProperty(ref _mode, value); }
    public PromptPlacement Placement { get => _placement; set => SetProperty(ref _placement, value); }
}

public sealed class ChatMessage : PluginRuntime.ObservableObject
{
    private string _id = Guid.NewGuid().ToString();
    private ChatKind _kind;
    private string _text = "";
    private DateTimeOffset _createdAt = DateTimeOffset.Now;
    private bool _streaming;

    public string Id { get => _id; set => SetProperty(ref _id, value); }
    public ChatKind Kind { get => _kind; set => SetProperty(ref _kind, value); }
    public string Text { get => _text; set => SetProperty(ref _text, value); }
    public DateTimeOffset CreatedAt { get => _createdAt; set => SetProperty(ref _createdAt, value); }
    public bool Streaming { get => _streaming; set => SetProperty(ref _streaming, value); }
}

public sealed class Conversation : PluginRuntime.ObservableObject
{
    private string _title = "New chat";
    private bool _running;
    private bool _blank = true;

    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Title { get => _title; set => SetProperty(ref _title, value); }
    public System.Collections.ObjectModel.ObservableCollection<ChatMessage> Messages { get; set; } = new();
    public System.Collections.ObjectModel.ObservableCollection<PendingPrompt> PendingPrompts { get; set; } = new();
    public bool Running { get => _running; set => SetProperty(ref _running, value); }
    public bool Blank { get => _blank; set => SetProperty(ref _blank, value); }
    public string? Cwd { get; set; }
    public string? AgentPreset { get; set; }
}

public sealed record PendingApproval(
    string RpcId,
    string SessionId,
    string ApprovalId,
    string ToolName,
    string? Reason);

public sealed record PendingQuestion(
    string RpcId,
    string SessionId,
    string QuestionId,
    string Prompt,
    IReadOnlyList<string> Options);

public static class SessionProjector
{
    public static bool IsPlaceholderTitle(string? title) =>
        string.IsNullOrWhiteSpace(title)
        || title is "New chat" or "Untitled" or "Session";

    public static string TitleFor(string text)
    {
        var firstLine = text.Split(new[] { '\r', '\n' }, StringSplitOptions.None).FirstOrDefault() ?? text;
        var compact = firstLine.Trim();
        return compact.Length > 42 ? compact[..42] : compact;
    }

    public static void ApplyFirstUserTitle(Conversation conversation)
    {
        var firstUserMessage = conversation.Messages.FirstOrDefault(m => m.Kind == ChatKind.User);
        if (firstUserMessage is null || string.IsNullOrWhiteSpace(firstUserMessage.Text)) return;
        conversation.Title = TitleFor(firstUserMessage.Text);
        conversation.Blank = false;
    }

    public static string? Title(JsonValue? projections)
    {
        var raw = projections?["values"]?["title"]?.AsString() ?? projections?["title"]?.AsString();
        if (string.IsNullOrEmpty(raw)) return null;
        var title = raw;
        var eos = title.IndexOf("<|eos|>", StringComparison.Ordinal);
        if (eos >= 0) title = title[..eos];
        title = title.Trim();
        return string.IsNullOrEmpty(title) ? null : title;
    }

    public static Conversation Summary(IReadOnlyDictionary<string, JsonValue> item)
    {
        var id = item.TryGetValue("sessionId", out var sid) ? sid.AsString() ?? Guid.NewGuid().ToString() : Guid.NewGuid().ToString();
        var title = Title(item.TryGetValue("projections", out var proj) ? proj : JsonValue.Null) ?? "Untitled";
        var blank = item.TryGetValue("blank", out var b) && (b.AsBool() ?? false);
        return new Conversation
        {
            Id = id,
            Title = blank ? "New chat" : IsPlaceholderTitle(title) ? "Untitled" : title,
            Running = item.TryGetValue("running", out var r) && (r.AsBool() ?? false),
            Blank = blank,
            Cwd = item.TryGetValue("cwd", out var cwd) ? cwd.AsString() : null,
            AgentPreset = item.TryGetValue("agentPreset", out var preset) ? preset.AsString() : null,
        };
    }

    public static void Apply(IReadOnlyDictionary<string, JsonValue> ev, Conversation conversation)
    {
        var type = ev.TryGetValue("type", out var t) ? t.AsString() ?? "" : "";
        var millis = ev.TryGetValue("time", out var time) ? time.AsDouble() ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() : DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var stamp = DateTimeOffset.FromUnixTimeMilliseconds((long)millis);
        var data = ev.TryGetValue("data", out var d) ? d : JsonValue.Null;
        switch (type)
        {
            case "user/message":
            {
                var id = data["id"]?.AsString() ?? $"user-{(ev.TryGetValue("seq", out var seq) ? seq.AsInt() ?? 0 : 0)}";
                var text = data.TextBlocks();
                if (string.IsNullOrEmpty(text)) return;
                var hadUserMessage = conversation.Messages.Any(m => m.Kind == ChatKind.User);
                Upsert(conversation, new ChatMessage { Id = id, Kind = ChatKind.User, Text = text, CreatedAt = stamp });
                if (!hadUserMessage || IsPlaceholderTitle(conversation.Title))
                {
                    conversation.Title = TitleFor(text);
                }
                conversation.Blank = false;
                break;
            }
            case "assistant/chunk":
            {
                if (data["chunk"]?["type"]?.AsString() == "text-delta" && data["chunk"]?["text"]?.AsString() is { } delta)
                {
                    AppendStream(conversation, delta, stamp);
                }
                break;
            }
            case "assistant/message":
            {
                var id = data["message"]?["id"]?.AsString() ?? $"assistant-{(ev.TryGetValue("seq", out var seq) ? seq.AsInt() ?? 0 : 0)}";
                var text = (data["message"] ?? data).TextBlocks();
                FinalizeStream(conversation, id, text, stamp);
                break;
            }
            case "tool/call":
            {
                var name = data["name"]?.AsString() ?? "tool";
                var id = data["callId"]?.AsString() ?? $"tool-{(ev.TryGetValue("seq", out var seq) ? seq.AsInt() ?? 0 : 0)}";
                Upsert(conversation, new ChatMessage { Id = id, Kind = ChatKind.Tool, Text = $"→ {name}", CreatedAt = stamp });
                break;
            }
            case "tool/result":
            {
                var id = data["message"]?["source"]?["callId"]?.AsString() is { } callId
                    ? $"{callId}-result"
                    : $"tool-result-{(ev.TryGetValue("seq", out var seq) ? seq.AsInt() ?? 0 : 0)}";
                var text = data["message"]?.TextBlocks();
                if (!string.IsNullOrEmpty(text))
                {
                    Upsert(conversation, new ChatMessage { Id = id, Kind = ChatKind.Tool, Text = text, CreatedAt = stamp });
                }
                break;
            }
            case "turn/end":
            {
                var last = conversation.Messages.LastOrDefault(m => m.Streaming);
                if (last is not null) last.Streaming = false;
                conversation.Running = false;
                break;
            }
            case "turn/start":
                conversation.Running = true;
                conversation.Blank = false;
                break;
        }
    }

    public static System.Collections.ObjectModel.ObservableCollection<ChatMessage> Fold(IEnumerable<IReadOnlyDictionary<string, JsonValue>> events)
    {
        var conversation = new Conversation { Id = "fold" };
        foreach (var ev in events) Apply(ev, conversation);
        return conversation.Messages;
    }

    private static void Upsert(Conversation conversation, ChatMessage message)
    {
        var index = -1;
        for (var i = 0; i < conversation.Messages.Count; i++)
        {
            if (conversation.Messages[i].Id == message.Id)
            {
                index = i;
                break;
            }
        }
        if (index >= 0) conversation.Messages[index] = message;
        else conversation.Messages.Add(message);
    }

    private static void AppendStream(Conversation conversation, string delta, DateTimeOffset time)
    {
        var last = conversation.Messages.LastOrDefault(m => m.Kind == ChatKind.Assistant && m.Streaming);
        if (last is not null) last.Text += delta;
        else
        {
            conversation.Messages.Add(new ChatMessage
            {
                Id = $"stream-{Guid.NewGuid()}",
                Kind = ChatKind.Assistant,
                Text = delta,
                CreatedAt = time,
                Streaming = true,
            });
        }
    }

    private static void FinalizeStream(Conversation conversation, string id, string text, DateTimeOffset time)
    {
        var last = conversation.Messages.LastOrDefault(m => m.Kind == ChatKind.Assistant && m.Streaming);
        if (last is not null)
        {
            last.Id = id;
            last.Text = string.IsNullOrEmpty(text) ? last.Text : text;
            last.CreatedAt = time;
            last.Streaming = false;
        }
        else if (!string.IsNullOrEmpty(text))
        {
            Upsert(conversation, new ChatMessage { Id = id, Kind = ChatKind.Assistant, Text = text, CreatedAt = time });
        }
    }
}
