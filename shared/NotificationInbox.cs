// Copyright (c) 2026 DOTS
// Small local inbox for attention and run-completion events.

using System.ComponentModel;
using System.Text.Json;

namespace DotsHarnessCore;

public sealed record InboxNotification(
    string Id,
    string Kind,
    string Title,
    string Subtitle,
    string Detail,
    string? ConversationId,
    string? ConversationPath,
    DateTimeOffset CreatedAt,
    bool IsRead);

/// <summary>Persisted, bounded inbox shared by the Windows and Linux hosts.</summary>
public sealed class NotificationInboxStore : INotifyPropertyChanged
{
    private const int MaximumItemCount = 100;
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private readonly object _gate = new();
    private readonly string _file;
    private List<InboxNotification> _items;

    public event PropertyChangedEventHandler? PropertyChanged;
    public event EventHandler? Changed;

    public IReadOnlyList<InboxNotification> Items
    {
        get { lock (_gate) return _items.ToArray(); }
    }

    public int UnreadCount
    {
        get { lock (_gate) return _items.Count(item => !item.IsRead); }
    }

    public NotificationInboxStore(string file)
    {
        _file = file;
        try
        {
            _items = File.Exists(file)
                ? (JsonSerializer.Deserialize<List<InboxNotification>>(File.ReadAllText(file), Json) ?? [])
                    .OrderByDescending(item => item.CreatedAt).Take(MaximumItemCount).ToList()
                : [];
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            _items = [];
        }
    }

    public InboxNotification Append(string kind, string title, string subtitle = "", string detail = "",
        string? conversationId = null, string? conversationPath = null, bool isRead = false)
    {
        InboxNotification notification;
        lock (_gate)
        {
            notification = new InboxNotification(
                Guid.NewGuid().ToString(), kind, title, subtitle, Preview(detail),
                conversationId, conversationPath, DateTimeOffset.UtcNow, isRead);
            _items.Insert(0, notification);
            if (_items.Count > MaximumItemCount) _items.RemoveRange(MaximumItemCount, _items.Count - MaximumItemCount);
            PersistLocked();
        }
        NotifyChanged();
        return notification;
    }

    public void MarkRead(string id)
    {
        lock (_gate)
        {
            var index = _items.FindIndex(item => item.Id == id);
            if (index < 0 || _items[index].IsRead) return;
            _items[index] = _items[index] with { IsRead = true };
            PersistLocked();
        }
        NotifyChanged();
    }

    public void MarkAllRead()
    {
        lock (_gate)
        {
            if (_items.All(item => item.IsRead)) return;
            _items = _items.Select(item => item with { IsRead = true }).ToList();
            PersistLocked();
        }
        NotifyChanged();
    }

    public void Clear()
    {
        lock (_gate)
        {
            if (_items.Count == 0) return;
            _items.Clear();
            PersistLocked();
        }
        NotifyChanged();
    }

    private void PersistLocked()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
            File.WriteAllText(_file, JsonSerializer.Serialize(_items, Json));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    private void NotifyChanged()
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Items)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(UnreadCount)));
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private static string Preview(string value)
    {
        var compact = string.Join(" ", value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return compact.Length > 240 ? compact[..240] + "…" : compact;
    }
}
