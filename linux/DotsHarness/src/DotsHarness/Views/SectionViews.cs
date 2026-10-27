// Copyright (c) 2026 DOTS
// Rail sections that reuse a settings page: Tasks (with suggestions), Marketplace and
// Memory (with its chat). Mirrors TasksView, MarketplaceSectionView and MemoryVaultView on macOS.

using System.IO;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using DotsHarnessCore;

namespace DotsHarness.Views;

/// <summary>A rail section; told when it comes on screen so it can refresh.</summary>
internal interface ISectionView
{
    void Activate();
}

internal static class SectionChrome
{
    public static DockPanel Frame(string title, Control body, Control? trailing = null)
    {
        var header = new DockPanel { Margin = new Thickness(24, 14, 24, 8) };
        if (trailing is not null)
        {
            DockPanel.SetDock(trailing, Dock.Right);
            header.Children.Add(trailing);
        }
        header.Children.Add(Ui.Text(title, 20, bold: true));
        var root = new DockPanel { Background = Ui.Brush("WindowBackground") };
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);
        root.Children.Add(body);
        return root;
    }

    public static EmbeddedSettings Embedded(string tab) => new(tab);

    /// <summary>The project starters, which macOS shows as their own Marketplace tab.</summary>
    public static EmbeddedSettings EmbeddedStarters() => new(starters: true);

}

/// <summary>A settings page lifted out of a never-shown SettingsWindow, without its tab list.</summary>
internal sealed class EmbeddedSettings : ContentControl
{
    private readonly SettingsWindow _page;

    public EmbeddedSettings(string tab)
    {
        _page = new SettingsWindow { DataContext = ((App)Application.Current!).Model };
        Content = _page.Embed(tab);
    }

    public EmbeddedSettings(bool starters)
    {
        _page = new SettingsWindow { DataContext = ((App)Application.Current!).Model };
        Content = starters ? _page.EmbedStarters() : _page.Embed("plugins");
    }

    public void SelectTab(string tab) => _page.SelectTab(tab);
}

internal sealed class TasksSectionView : UserControl, ISectionView
{
    private readonly AppModel _model;
    private readonly WrapPanel _cards = new() { Margin = new Thickness(24, 0, 12, 8) };
    private readonly TextBlock _status = Ui.Text("", 11, secondary: true);
    private readonly EmbeddedSettings _list = SectionChrome.Embedded("tasks");
    private CancellationTokenSource? _loading;

    public TasksSectionView(AppModel model)
    {
        _model = model;
        var top = new StackPanel();
        var heading = new DockPanel { Margin = new Thickness(24, 0, 24, 6) };
        var refresh = Ui.Button("↻", () => _ = LoadAsync(force: true), model.L("tasks.suggestions.refresh"));
        DockPanel.SetDock(refresh, Dock.Right);
        heading.Children.Add(refresh);
        var titles = new StackPanel();
        titles.Children.Add(Ui.Text(model.L("tasks.suggestions"), 14, bold: true));
        titles.Children.Add(_status);
        heading.Children.Add(titles);
        top.Children.Add(heading);
        top.Children.Add(new ScrollViewer { Content = _cards, MaxHeight = 250, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        var body = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        body.Children.Add(top);
        body.Children.Add(_list);
        Content = SectionChrome.Frame(model.L("rail.tasks"), body);
    }

    public void Activate() => _ = LoadAsync(force: false);

    private string Workspace => string.IsNullOrWhiteSpace(_model.WorkspacePath)
        ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) : _model.WorkspacePath;

    /// <summary>Cards on disk show at once; the personalized set replaces them when it arrives.</summary>
    private async Task LoadAsync(bool force)
    {
        _loading?.Cancel();
        var loading = _loading = new CancellationTokenSource();
        var locale = _model.Localization.Culture.Name;
        var memory = _model.MemoryEnabled ? ScheduledTaskSuggestions.Memory(_model.WorkspacePath, _model.Paths.Root) : [];
        Show(ScheduledTaskSuggestions.Stored(memory, _model.Paths.Root, locale, Workspace) ?? ScheduledTaskSuggestion.Defaults);
        if (memory.Count == 0) { _status.Text = ""; return; }
        _status.Text = _model.L("tasks.suggestions.personalizing");
        try
        {
            var cards = await ScheduledTaskSuggestions.PersonalizedAsync(memory, _model.Paths.Root, locale, Workspace, _model.Router, force, loading.Token);
            if (loading.IsCancellationRequested) return;
            Show(cards);
            _status.Text = cards.Any(c => c.MemorySourceIds.Count > 0) ? _model.L("tasks.suggestions.memory") : _model.L("tasks.suggestions.unavailable");
        }
        catch (Exception) when (!loading.IsCancellationRequested)
        {
            _status.Text = _model.L("tasks.suggestions.unavailable");
        }
    }

    private void Show(IEnumerable<ScheduledTaskSuggestion> suggestions)
    {
        _cards.Children.Clear();
        foreach (var suggestion in suggestions)
        {
            var stack = new StackPanel { Width = 210 };
            stack.Children.Add(Ui.Text(suggestion.Title, bold: true));
            stack.Children.Add(Ui.Text(suggestion.Detail, 12, secondary: true, wrap: true));
            stack.Children.Add(Ui.Text("◷ " + suggestion.Schedule, 11, secondary: true));
            var card = Ui.Card(stack);
            card.Cursor = new Cursor(StandardCursorType.Hand);
            ToolTip.SetTip(card, _model.L("tasks.new"));
            card.PointerReleased += (_, _) => Create(suggestion);
            _cards.Children.Add(card);
        }
    }

    private void Create(ScheduledTaskSuggestion suggestion)
    {
        _model.Scheduler.Upsert(suggestion.Task(Workspace));
        _list.SelectTab("tasks");
    }
}

internal sealed class MarketplaceSectionView : UserControl, ISectionView
{
    private readonly AppModel _model;

    public MarketplaceSectionView(AppModel model)
    {
        _model = model;
        var tabs = new TabControl { Margin = new Thickness(16, 0, 16, 0), BorderThickness = new Thickness(0) };
        tabs.Items.Add(new TabItem { Header = model.L("settings.plugins"), Content = SectionChrome.Embedded("plugins") });
        tabs.Items.Add(new TabItem { Header = model.L("conversation.skills"), Content = SectionChrome.Embedded("skills") });
        tabs.Items.Add(new TabItem { Header = model.L("market.tab.starters"), Content = SectionChrome.EmbeddedStarters() });
        Content = SectionChrome.Frame(model.L("marketplace.title"), tabs);
    }

    /// <summary>The starters come from the server; the tab refreshes when it opens.</summary>
    public void Activate()
    {
        _ = _model.Marketplace.RefreshStartersAsync();
    }
}

internal sealed class MemorySectionView : UserControl, ISectionView
{
    private readonly AppModel _model;
    private readonly EmbeddedSettings _vault = SectionChrome.Embedded("memory");
    private readonly StackPanel _turns = new() { Margin = new Thickness(12) };
    private readonly ScrollViewer _scroll;
    private readonly TextBox _draft = new() { Text = "", AcceptsReturn = false, TextWrapping = TextWrapping.Wrap, MaxHeight = 110, Padding = new Thickness(6, 4, 6, 4) };
    private List<MemoryChatTurn> _chat = [];
    private string? _workspace;
    private bool _busy;

    public MemorySectionView(AppModel model)
    {
        _model = model;
        _scroll = new ScrollViewer { Content = _turns, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var send = Ui.Button("↑", Send, Tr("Gönder", "Send"), primary: true);
        send.Margin = new Thickness(6, 0, 0, 0);
        var input = new DockPanel { Margin = new Thickness(10) };
        DockPanel.SetDock(send, Dock.Right);
        input.Children.Add(send);
        input.Children.Add(_draft);
        ToolTip.SetTip(_draft, Tr("Hafızaya sor veya değiştir", "Ask or change memory"));
        _draft.KeyDown += (_, e) => { if (e.Key == Key.Enter) { Send(); e.Handled = true; } };
        var chat = new DockPanel { Background = Ui.Brush("ChromeBackground") };
        DockPanel.SetDock(input, Dock.Bottom);
        chat.Children.Add(input);
        chat.Children.Add(_scroll);

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 300 });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(5) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(340), MinWidth = 240 });
        grid.Children.Add(_vault);
        var splitter = new GridSplitter { Width = 5, HorizontalAlignment = HorizontalAlignment.Stretch, Background = Ui.Brush("BorderSubtle") };
        Grid.SetColumn(splitter, 1);
        grid.Children.Add(splitter);
        Grid.SetColumn(chat, 2);
        grid.Children.Add(chat);
        Content = SectionChrome.Frame(model.L("rail.memory"), grid);
    }

    private string Tr(string tr, string en) => _model.Localization.Culture.TwoLetterISOLanguageName == "tr" ? tr : en;

    public void Activate()
    {
        _vault.SelectTab("memory");
        if (_workspace == _model.WorkspacePath && _chat.Count > 0) return;
        _workspace = _model.WorkspacePath;
        _chat = _model.Bridge.MemoryChatHistory(_workspace);
        Render();
    }

    private void Render()
    {
        _turns.Children.Clear();
        if (_chat.Count == 0)
        {
            _turns.Children.Add(Ui.Text(Tr(
                "Bu projenin hafızasına sorun veya değiştirmesini isteyin. Örneğin: “Testleri nasıl çalıştırıyorum?”, “Şunu kural olarak ekle…”",
                "Ask this project's memory, or ask it to change. For example: “How do I run the tests?”, “Add this as a rule…”"), 12, secondary: true, wrap: true));
        }
        else
        {
            var clear = Ui.Button(Tr("Sohbeti temizle", "Clear chat"), () =>
            {
                _chat = [];
                _model.Bridge.SaveMemoryChat(_workspace, _chat);
                Render();
            });
            clear.HorizontalAlignment = HorizontalAlignment.Left;
            clear.IsEnabled = !_busy;
            clear.Margin = new Thickness(0, 0, 0, 10);
            _turns.Children.Add(clear);
        }
        foreach (var turn in _chat)
        {
            if (turn.Role == "user")
            {
                _turns.Children.Add(new Border
                {
                    Child = new TextBox { Text = turn.Text, IsReadOnly = true, BorderThickness = new Thickness(0), Background = null, TextWrapping = TextWrapping.Wrap, Foreground = Ui.Brush("TextPrimary") },
                    Background = Ui.Brush("BubbleUser"), CornerRadius = new CornerRadius(10), Padding = new Thickness(8, 4, 8, 4),
                    Margin = new Thickness(30, 0, 0, 10), HorizontalAlignment = HorizontalAlignment.Right,
                });
                continue;
            }
            var stack = new StackPanel { Margin = new Thickness(0, 0, 0, 12) };
            stack.Children.Add(new TextBox { Text = turn.Text, IsReadOnly = true, BorderThickness = new Thickness(0), Background = null, TextWrapping = TextWrapping.Wrap, Foreground = Ui.Brush("TextPrimary") });
            foreach (var line in turn.Applied) stack.Children.Add(Ui.Text("✓ " + line, 11, secondary: true, wrap: true));
            foreach (var deletion in turn.Deletions.ToList())
            {
                var delete = Ui.Button(Tr("Sil", "Delete") + ": " + deletion.Title, () =>
                {
                    WorkspaceMemoryVault.Edit(_workspace, _model.Paths.Root, deletion.Edit);
                    turn.Deletions.Remove(deletion);
                    _vault.SelectTab("memory");
                    Render();
                });
                delete.HorizontalAlignment = HorizontalAlignment.Left;
                delete.Margin = new Thickness(0, 4, 0, 0);
                stack.Children.Add(delete);
            }
            _turns.Children.Add(stack);
        }
        if (_busy) _turns.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 4, Width = 80, HorizontalAlignment = HorizontalAlignment.Left });
        _scroll.ScrollToEnd();
    }

    private async void Send()
    {
        var text = _draft.Text.Trim();
        if (_busy || text.Length == 0) return;
        var workspace = _workspace;
        _chat.Add(new MemoryChatTurn { Role = "user", Text = text });
        _draft.Text = "";
        _busy = true;
        Render();
        var answer = await _model.Bridge.MemoryChatAsync(workspace, _chat.ToList());
        _busy = false;
        // The project may have been switched while the model was answering.
        if (workspace != _workspace) return;
        _chat.Add(answer);
        _model.Bridge.SaveMemoryChat(workspace, _chat);
        _vault.SelectTab("memory");
        Render();
    }
}
