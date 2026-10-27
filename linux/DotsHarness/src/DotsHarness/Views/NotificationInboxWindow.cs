using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using DotsHarnessCore;

namespace DotsHarness.Views;

internal sealed class NotificationInboxWindow : Window
{
    private readonly NotificationInboxStore _inbox;
    private readonly Func<string, string> _text;
    private readonly Action<InboxNotification> _select;
    private readonly StackPanel _items = new() { Margin = new Thickness(8), Spacing = 6 };

    public NotificationInboxWindow(NotificationInboxStore inbox, Func<string, string> text, Action<InboxNotification> select)
    {
        _inbox = inbox;
        _text = text;
        _select = select;
        Title = text("notifications.title");
        Width = 380;
        Height = 470;
        MinWidth = 340;
        MinHeight = 320;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 6 };
        var markRead = new Button { Content = text("notifications.markAllRead"), Padding = new Thickness(7, 4) };
        markRead.Click += (_, _) => inbox.MarkAllRead();
        var clear = new Button { Content = text("notifications.clearAll"), Padding = new Thickness(7, 4) };
        clear.Click += (_, _) => inbox.Clear();
        actions.Children.Add(markRead);
        actions.Children.Add(clear);

        var header = new DockPanel { Margin = new Thickness(12, 10, 12, 8), LastChildFill = true };
        DockPanel.SetDock(actions, Dock.Right);
        header.Children.Add(actions);
        header.Children.Add(new TextBlock { Text = text("notifications.title"), FontSize = 15, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center });

        var root = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);
        root.Children.Add(new ScrollViewer { Content = _items, VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto });
        Content = root;
        _inbox.Changed += OnInboxChanged;
        Closed += (_, _) => _inbox.Changed -= OnInboxChanged;
        Render();
    }

    private void OnInboxChanged(object? sender, EventArgs e) => Dispatcher.UIThread.Post(Render);

    private void Render()
    {
        _items.Children.Clear();
        if (_inbox.Items.Count == 0)
        {
            _items.Children.Add(new TextBlock
            {
                Text = _text("notifications.emptyTitle") + "\n" + _text("notifications.emptyBody"),
                TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center,
                Margin = new Thickness(20, 40, 20, 40),
                Foreground = Brushes.Gray,
            });
            return;
        }

        foreach (var item in _inbox.Items)
        {
            var content = new StackPanel { Margin = new Thickness(8, 5), Spacing = 3 };
            content.Children.Add(new TextBlock { Text = item.Title, FontWeight = item.IsRead ? FontWeight.Medium : FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
            if (!string.IsNullOrWhiteSpace(item.Subtitle))
                content.Children.Add(new TextBlock { Text = item.Subtitle, FontSize = 11, Foreground = Brushes.Gray, TextTrimming = TextTrimming.CharacterEllipsis });
            if (!string.IsNullOrWhiteSpace(item.Detail))
                content.Children.Add(new TextBlock { Text = item.Detail, FontSize = 11, TextWrapping = TextWrapping.Wrap, MaxHeight = 42, Foreground = Brushes.Gray });
            content.Children.Add(new TextBlock { Text = item.CreatedAt.ToLocalTime().ToString("g"), FontSize = 9, Foreground = Brushes.Gray, HorizontalAlignment = HorizontalAlignment.Right });
            var button = new Button { Content = content, HorizontalContentAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(2), Margin = new Thickness(0, 0, 0, 2) };
            button.Click += (_, _) => _select(item);
            _items.Children.Add(button);
        }
    }
}
