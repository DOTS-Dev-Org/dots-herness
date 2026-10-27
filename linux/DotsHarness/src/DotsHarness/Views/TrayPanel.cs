// Copyright (c) 2026 DOTS
// Tray panel: live chats with the full conversation surface (composer, model
// picker) one click away, so the app is usable without opening the main window.

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using DotsHarnessCore;

namespace DotsHarness.Views;

internal sealed class TrayPanel : Window
{
    private const int GroupLimit = 5;

    private static readonly Color Green = Color.FromRgb(0x2E, 0xCC, 0x71);
    private static readonly Color Orange = Color.FromRgb(0xF3, 0x9C, 0x12);
    private static readonly Color Red = Color.FromRgb(0xE7, 0x4C, 0x3C);
    private static readonly Color Gray = Color.FromRgb(0x8E, 0x8E, 0x93);

    private readonly AppModel _model;
    private readonly DockPanel _listPage = new();
    private readonly DockPanel _chatPage = new() { IsVisible = false };
    private readonly DockPanel _chatHeader = new() { Height = 44 };
    private readonly ContentControl _chatHost = new();
    private readonly DispatcherTimer _refresh = new() { Interval = TimeSpan.FromSeconds(2) };
    private readonly HashSet<string> _expanded = new();
    private string _signature = "";
    private bool _usageOpen;
    private DateTime _hiddenAt;

    public TrayPanel(AppModel model)
    {
        _model = model;
        Activated += (_, _) => { _ = model.Router.RefreshClaudeUsageAfterActivationAsync(); };
        Width = 420;
        Height = 620;
        SystemDecorations = SystemDecorations.None;
        CanResize = false;
        ShowInTaskbar = false;
        Topmost = true;
        WindowStartupLocation = WindowStartupLocation.Manual;
        this.Bind(BackgroundProperty, this.GetResourceObservable("PanelBackground"));

        DockPanel.SetDock(_chatHeader, Dock.Top);
        _chatPage.Children.Add(_chatHeader);
        _chatPage.Children.Add(_chatHost);
        var frame = new Border { BorderThickness = new Thickness(1), Child = new Grid { Children = { _listPage, _chatPage } } };
        frame.Bind(Border.BorderBrushProperty, frame.GetResourceObservable("BorderSubtle"));
        Content = frame;

        _refresh.Tick += (_, _) => Refresh();
        // Pin and sort changes come from here or from the sidebar; show them at once.
        _model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppModel.Projects) && IsVisible) Dispatcher.UIThread.Post(() => { _signature = ""; Refresh(); });
        };
        // ponytail: closes on any outside click; dialogs the chat opens are owned
        // windows and keep it open. Pin button if users want it to stay.
        Deactivated += (_, _) =>
        {
            if (OwnedWindows.Count == 0) HidePanel();
        };
        Closing += (_, e) =>
        {
            if (((App)Application.Current!).IsExiting) return;
            e.Cancel = true;
            HidePanel();
        };
    }

    public void Toggle()
    {
        // The tray click that should close the panel deactivates it first.
        if (IsVisible || (DateTime.UtcNow - _hiddenAt).TotalMilliseconds < 300)
        {
            HidePanel();
            return;
        }
        _signature = "";
        Refresh();
        // ponytail: top-right, where GNOME keeps its tray; Wayland compositors
        // place the window themselves. Anchor to the icon if a toolkit API appears.
        if (Screens.Primary is { } screen)
        {
            var area = screen.WorkingArea;
            Position = new PixelPoint(area.Right - (int)((Width + 12) * screen.Scaling), area.Y + (int)(12 * screen.Scaling));
        }
        Show();
        Activate();
        _refresh.Start();
    }

    private void HidePanel()
    {
        if (!IsVisible) return;
        _refresh.Stop();
        _hiddenAt = DateTime.UtcNow;
        Hide();
    }

    private void ShowChat(bool visible)
    {
        // Created on first use: a second conversation surface is not free.
        // ponytail: shares the window's selection, so the window follows the panel.
        if (visible) _chatHost.Content ??= new ConversationView { DataContext = _model };
        _chatPage.IsVisible = visible;
        _listPage.IsVisible = !visible;
        _signature = "";
        Refresh();
    }

    // Content

    private void Refresh()
    {
        var known = _model.Bridge.Conversations
            .Concat(_model.Bridge.RecentConversations(_model.ConnectedProjectPaths))
            .Where(item => !item.Blank && !item.Archived)
            .DistinctBy(item => item.Id)
            .OrderByDescending(SessionProjector.LastActivity)
            .ToList();
        var signature = string.Join("|", known.Select(item =>
                $"{item.Id}:{item.Title}:{item.Running}:{item.Continuation?.Reason}:{item.PendingPlanMessageId}"))
            + $"|{_model.Language}|{_model.Selected?.Id}|{_model.Selected?.Title}|{_usageOpen}|"
            + string.Join(",", _model.OrderedProjects.Select(path => $"{path}:{_model.SortOrder(path)}:{_model.IsProjectPinned(path)}"))
            + "|" + string.Join(",", _model.Router.Connections.Where(item => item.Active).Select(item =>
            {
                var usage = _model.Router.AccountUsage.GetValueOrDefault(item.Id);
                var windows = usage is null ? "" : string.Join(";", usage.Windows.Select(window => $"{window.Weekly}:{window.UsedFraction}:{window.ResetsAt}"));
                return $"{item.Id}:{usage?.UsedFraction}:{usage?.ResetsAt}:{usage?.ResetsAvailable}:{windows}";
            }));
        if (signature == _signature) return;
        _signature = signature;
        FlowDirection = _model.IsRightToLeft ? FlowDirection.RightToLeft : FlowDirection.LeftToRight;
        BuildList(known);
        BuildChatHeader();
    }

    private void BuildList(List<Conversation> known)
    {
        _listPage.Children.Clear();

        var newChat = Flat(_model.L("sidebar.newChat"), () =>
        {
            _model.NewConversation();
            ShowChat(true);
        });
        var header = new DockPanel { Height = 44, Margin = new Thickness(14, 0, 8, 0) };
        DockPanel.SetDock(newChat, Dock.Right);
        header.Children.Add(newChat);
        header.Children.Add(Text(_model.L("app.title"), 14, "TextPrimary", FontWeight.SemiBold));
        DockPanel.SetDock(header, Dock.Top);
        _listPage.Children.Add(header);

        var app = (App)Application.Current!;
        var quit = Flat(_model.L("tray.quit"), () => { HidePanel(); app.RequestExit(); });
        var footer = new DockPanel { Height = 38, Margin = new Thickness(8, 0, 8, 0) };
        DockPanel.SetDock(quit, Dock.Right);
        footer.Children.Add(quit);
        var show = Flat(_model.L("tray.show"), () => { HidePanel(); app.ShowMainWindow(); }, HorizontalAlignment.Left);
        DockPanel.SetDock(show, Dock.Left);
        footer.Children.Add(show);
        footer.Children.Add(Flat(_model.L("usage.planLimits"), () =>
        {
            _usageOpen = !_usageOpen;
            _signature = "";
            Refresh();
        }, HorizontalAlignment.Left));
        DockPanel.SetDock(footer, Dock.Bottom);
        _listPage.Children.Add(footer);
        if (_usageOpen)
        {
            var usage = UsageBlock();
            DockPanel.SetDock(usage, Dock.Bottom);
            _listPage.Children.Add(usage);
        }

        var rows = new StackPanel { Margin = new Thickness(8) };
        // The sidebar's picture: pinned projects first, each project's chats in its
        // own sort order, then the chats that belong to no connected project.
        var groups = _model.OrderedProjects
            .Select(path => (Id: path, Title: (_model.IsProjectPinned(path) ? "★ " : "") + _model.ProjectTitle(path),
                Rows: _model.Ordered(known.Where(item => SidebarView.SamePath(item.Cwd, path)), path).ToList()))
            .ToList();
        var grouped = groups.SelectMany(group => group.Rows).Select(item => item.Id).ToHashSet();
        groups.Add((Id: "", Title: _model.L("sidebar.chats"), Rows: known.Where(item => !grouped.Contains(item.Id)).ToList()));
        foreach (var group in groups.Where(group => group.Rows.Count > 0))
        {
            var heading = new DockPanel { Margin = new Thickness(8, 8, 0, 2) };
            if (group.Id.Length > 0)
            {
                // The project's own settings: the same change shows in the sidebar.
                var project = group.Id;
                Button? menu = null;
                menu = Flat("⋯", () => OpenProjectMenu(_model, project, menu!));
                menu.Padding = new Thickness(6, 0, 6, 0);
                DockPanel.SetDock(menu, Dock.Right);
                heading.Children.Add(menu);
            }
            heading.Children.Add(Text(group.Title, 11, "TextSecondary", FontWeight.Medium));
            rows.Children.Add(heading);
            var showAll = _expanded.Contains(group.Id);
            foreach (var conversation in showAll ? group.Rows : group.Rows.Take(GroupLimit)) rows.Children.Add(Row(conversation));
            if (group.Rows.Count <= GroupLimit) continue;
            var id = group.Id;
            var more = Flat(showAll ? "−" : "+ " + (group.Rows.Count - GroupLimit), () =>
            {
                if (!_expanded.Remove(id)) _expanded.Add(id);
                _signature = "";
                Refresh();
            }, HorizontalAlignment.Left);
            more.FontSize = 11;
            rows.Children.Add(more);
        }
        if (known.Count == 0)
        {
            var empty = Text(_model.L("tray.noChats"), 12, "TextSecondary");
            empty.HorizontalAlignment = HorizontalAlignment.Center;
            empty.Margin = new Thickness(0, 24, 0, 24);
            rows.Children.Add(empty);
        }
        _listPage.Children.Add(new ScrollViewer
        {
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled,
            Content = rows,
        });
    }

    private void BuildChatHeader()
    {
        _chatHeader.Children.Clear();
        _chatHeader.Margin = new Thickness(8, 0, 8, 0);
        var back = Flat("‹  " + _model.L("sidebar.chats"), () => ShowChat(false));
        var show = Flat(_model.L("tray.show"), () => { HidePanel(); ((App)Application.Current!).ShowMainWindow(); });
        DockPanel.SetDock(back, Dock.Left);
        DockPanel.SetDock(show, Dock.Right);
        _chatHeader.Children.Add(back);
        _chatHeader.Children.Add(show);
        var selected = _model.Selected;
        var title = Text(
            selected?.Title ?? _model.L("sidebar.newChat"),
            13, "TextPrimary", FontWeight.SemiBold);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        _chatHeader.Children.Add(title);
    }

    private Control Row(Conversation conversation)
    {
        var status = Status(conversation);
        var dot = new Avalonia.Controls.Shapes.Ellipse
        {
            Width = 6,
            Height = 6,
            Margin = new Thickness(4, 0, 8, 0),
            VerticalAlignment = VerticalAlignment.Center,
            Fill = new SolidColorBrush(status.Tint, status.Text.Length > 0 ? 1 : 0.35),
        };
        var state = Text(status.Text, 11, "TextSecondary");
        state.Foreground = new SolidColorBrush(status.Tint);
        state.Margin = new Thickness(8, 0, 0, 0);
        var body = new DockPanel();
        DockPanel.SetDock(dot, Dock.Left);
        DockPanel.SetDock(state, Dock.Right);
        body.Children.Add(dot);
        body.Children.Add(state);
        body.Children.Add(Text(conversation.Title, 13, "TextPrimary"));

        var open = Flat(body, async () =>
        {
            await Select(conversation);
            ShowChat(true);
        }, HorizontalAlignment.Stretch);
        open.HorizontalContentAlignment = HorizontalAlignment.Stretch;

        var row = new DockPanel();
        // One intervention per chat: whatever the run needs right now.
        if (conversation.Running || conversation.CanContinue)
        {
            var running = conversation.Running;
            var control = Flat(running ? "■" : "▶", async () =>
            {
                await Select(conversation);
                if (running) _model.Cancel(); else _model.Continue();
            });
            ToolTip.SetTip(control, _model.L(running ? "conversation.stop" : "conversation.continue"));
            control.FontSize = 10;
            DockPanel.SetDock(control, Dock.Right);
            row.Children.Add(control);
        }
        row.Children.Add(open);
        return row;
    }

    private async Task Select(Conversation conversation)
    {
        await _model.Bridge.OpenRecentConversationAsync(conversation.Id);
        _model.SelectedConversationId = conversation.Id;
    }

    private (string Text, Color Tint) Status(Conversation conversation)
    {
        if (conversation.Running) return (_model.L("settings.running"), Green);
        // A provider limit reads the same as a pause, in red.
        if (conversation.Continuation is { } paused)
            return (_model.L("settings.stopped"), paused.Reason == ContinuationPauseReason.ProviderLimit ? Red : Orange);
        if (conversation.PendingPlanMessageId is not null) return (_model.L("queue.waitingForPlan"), Orange);
        return ("", Gray);
    }

    /// Renders the model's pin and sort rows; the sidebar opens the same menu.
    internal static void OpenProjectMenu(AppModel model, string project, Control target)
    {
        var menu = new ContextMenu();
        foreach (var (title, run) in model.ProjectMenu(project))
        {
            var item = new MenuItem { Header = title };
            item.Click += (_, _) => run();
            menu.Items.Add(item);
        }
        menu.Open(target);
    }

    /// Limits per connected account, kept current by the router's app-wide poll.
    private Control UsageBlock()
    {
        var block = new StackPanel { Margin = new Thickness(16, 8, 16, 8) };
        foreach (var connection in _model.Router.Connections.Where(item => item.Active))
        {
            var usage = _model.Router.AccountUsage.GetValueOrDefault(connection.Id);
            var value = Text(
                usage?.CurrentWindowUsedFraction is { } used ? $"{Math.Round(used * 100)}%" : _model.L("usage.noLimitInfo"), 11, "TextSecondary");
            var line = new DockPanel { Margin = new Thickness(0, 6, 0, 2) };
            DockPanel.SetDock(value, Dock.Right);
            line.Children.Add(value);
            line.Children.Add(Text(connection.Name, 12, "TextPrimary"));
            block.Children.Add(line);
            if (usage is not null)
            {
                if (usage.CurrentWindowUsedFraction is { } fraction)
                    block.Children.Add(new ProgressBar { Minimum = 0, Maximum = 1, Value = fraction, Height = 4 });
                var detail = usage.Windows
                    .Select(window => $"{_model.L(window.Weekly ? "usage.windowWeek" : "usage.window5h")} {(window.UsedFraction is { } windowUsed ? $"{Math.Round(windowUsed * 100)}%" : _model.L("usage.noLimitInfo"))}")
                    .Append(ResetText(usage.ResetsAt))
                    .Where(part => part.Length > 0);
                block.Children.Add(Text(string.Join(" · ", detail), 10, "TextSecondary"));
            }
            if (connection.Provider == "claude" && connection.AuthType == "claudeOAuth")
            {
                var resetRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 3, 0, 8) };
                if (usage?.ResetsAvailable is { } count)
                    resetRow.Children.Add(Text(_model.L("usage.resetsAvailable", count), 10, "TextSecondary"));
                var action = Flat(_model.L(usage?.ResetsAvailable is not null ? "usage.useReset" : "usage.manageResets"),
                    () => OpenClaudeResetAsync(connection));
                action.IsEnabled = usage?.ResetsAvailable is not 0;
                resetRow.Children.Add(action);
                block.Children.Add(resetRow);
            }
        }
        if (block.Children.Count == 0) block.Children.Add(Text(_model.L("usage.noLimitInfo"), 11, "TextSecondary"));
        return block;
    }

    private string ResetText(DateTimeOffset? at)
    {
        if (at is not { } date) return "";
        var left = date - DateTimeOffset.Now;
        if (left >= TimeSpan.FromHours(24))
            return _model.L("usage.resetsOn", date.ToLocalTime().ToString("ddd", _model.Localization.Culture));
        return _model.L("usage.resetsIn", left.TotalMinutes < 60
            ? $"{Math.Max(1, (int)left.TotalMinutes)}m"
            : $"{(int)left.TotalHours}h {left.Minutes}m");
    }

    private async Task OpenClaudeResetAsync(RouterConnection connection)
    {
        var confirmation = await new ClaudeResetDialog(
            _model.L("usage.resetTitle"),
            _model.L("usage.resetConfirmation", connection.Email ?? connection.Name),
            _model.L("settings.cancel"),
            _model.L("usage.openClaude")).ShowDialog<bool>(this);
        if (!confirmation) return;
        if (!_model.Router.OpenClaudeResetPage(connection.Id))
        {
            await new ClaudeResetDialog(
                _model.L("usage.resetOpenFailed"), _model.L("usage.resetOpenFailed"),
                _model.L("settings.cancel"), confirmText: null).ShowDialog<bool>(this);
        }
    }

    // Pieces

    private static TextBlock Text(string text, double size, string brush, FontWeight? weight = null)
    {
        var block = new TextBlock
        {
            Text = text,
            FontSize = size,
            FontWeight = weight ?? FontWeight.Normal,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        block.Bind(TextBlock.ForegroundProperty, block.GetResourceObservable(brush));
        return block;
    }

    private static Button Flat(object content, Action action, HorizontalAlignment alignment = HorizontalAlignment.Right)
    {
        var button = new Button
        {
            Content = content,
            Padding = new Thickness(8, 6, 8, 6),
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            HorizontalAlignment = alignment,
            VerticalAlignment = VerticalAlignment.Center,
            Cursor = new Cursor(StandardCursorType.Hand),
        };
        button.Bind(ForegroundProperty, button.GetResourceObservable("TextPrimary"));
        button.Click += (_, _) => action();
        return button;
    }

    private static Button Flat(object content, Func<Task> action, HorizontalAlignment alignment = HorizontalAlignment.Right) =>
        Flat(content, () => { _ = action(); }, alignment);
}

internal sealed class ClaudeResetDialog : Window
{
    public ClaudeResetDialog(string title, string message, string cancelText, string? confirmText)
    {
        Title = title;
        Width = 460;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var cancel = new Button { Content = cancelText, Padding = new Thickness(12, 6) };
        cancel.Click += (_, _) => Close(false);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 8 };
        buttons.Children.Add(cancel);
        if (confirmText is not null)
        {
            var confirm = new Button { Content = confirmText, Padding = new Thickness(12, 6) };
            confirm.Click += (_, _) => Close(true);
            buttons.Children.Add(confirm);
        }
        Content = new StackPanel
        {
            Spacing = 14,
            Margin = new Thickness(20),
            Children =
            {
                new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
                buttons,
            },
        };
    }
}
