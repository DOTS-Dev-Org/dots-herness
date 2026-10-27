// Copyright (c) 2026 DOTS
// Bots section: named assistants on the left, the selected bot's running chat on the right.
// Mirrors BotsView.swift on macOS.

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

internal sealed class BotsView : UserControl, ISectionView
{
    private readonly AppModel _model;
    private readonly BotStore _store;
    private readonly StackPanel _list = new() { Margin = new Thickness(8) };
    private readonly ContentControl _detail = new();
    private readonly TextBox _draft = new() { Text = "", TextWrapping = TextWrapping.Wrap, AcceptsReturn = false, MaxHeight = 140, Padding = new Thickness(8, 6, 8, 6), VerticalContentAlignment = VerticalAlignment.Center };
    private ScrollViewer? _messagesScroll;

    public BotsView(AppModel model)
    {
        _model = model;
        _store = model.Bots;
        _store.Changed += () => Dispatcher.UIThread.Post(Render);
        _draft.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter || e.KeyModifiers.HasFlag(KeyModifiers.Shift)) return;
            e.Handled = true;
            Send();
        };
        var newButton = Ui.Button("+ " + model.L("bots.new"), () => Edit(null));
        newButton.Margin = new Thickness(8, 8, 8, 0);
        var left = new DockPanel { Width = 250, Background = Ui.Brush("ChromeBackground") };
        var title = Ui.Text(model.L("rail.bots"), 18, bold: true);
        title.Margin = new Thickness(14, 14, 14, 0);
        DockPanel.SetDock(title, Dock.Top);
        DockPanel.SetDock(newButton, Dock.Top);
        left.Children.Add(title);
        left.Children.Add(newButton);
        left.Children.Add(new ScrollViewer { Content = _list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        var root = new DockPanel { Background = Ui.Brush("WindowBackground") };
        DockPanel.SetDock(left, Dock.Left);
        root.Children.Add(left);
        root.Children.Add(new Border { BorderBrush = Ui.Brush("BorderSubtle"), BorderThickness = new Thickness(1, 0, 0, 0), Child = _detail });
        Content = root;
    }

    public void Activate()
    {
        _store.LoadIfNeeded();
        Render();
    }

    private void Render()
    {
        _list.Children.Clear();
        foreach (var bot in _store.Bots)
        {
            var row = new DockPanel();
            var glyph = Ui.Text(Bot.Glyph(bot.Symbol), 16);
            glyph.Width = 30;
            DockPanel.SetDock(glyph, Dock.Left);
            row.Children.Add(glyph);
            var texts = new StackPanel();
            texts.Children.Add(Ui.Text(bot.Name, bold: true));
            var last = bot.Messages.LastOrDefault()?.Text.Replace('\n', ' ') ?? "";
            texts.Children.Add(Ui.Text(_store.IsBusy(bot.Id) ? "…" : last, 11, secondary: true));
            row.Children.Add(texts);
            var item = new Button
            {
                Content = row, HorizontalContentAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(8, 6, 8, 6),
                Margin = new Thickness(0, 0, 0, 2), BorderThickness = new Thickness(0),
                Background = bot.Id == _store.SelectedBotId ? new SolidColorBrush(Color.FromArgb(0x30, 0x80, 0x80, 0x80)) : Brushes.Transparent,
            };
            item.Click += (_, _) => { _store.SelectedBotId = bot.Id; Render(); };
            item.ContextMenu = new ContextMenu();
            item.ContextMenu.Items.Add(Menu(_model.L("bots.edit"), () => Edit(bot)));
            item.ContextMenu.Items.Add(Menu(_model.L("bots.clear"), () => _store.ClearHistory(bot.Id)));
            item.ContextMenu.Items.Add(Menu(_model.L("common.delete"), () => Delete(bot)));
            _list.Children.Add(item);
        }
        _detail.Content = _store.Find(_store.SelectedBotId) is { } selected ? Chat(selected) : Empty();
    }

    private static MenuItem Menu(string header, Action click)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => click();
        return item;
    }

    /// <summary>The empty screen offers the presets as starting points.</summary>
    private Control Empty()
    {
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 560 };
        stack.Children.Add(new TextBlock { Text = "💬", FontSize = 36, HorizontalAlignment = HorizontalAlignment.Center });
        var title = Ui.Text(_model.L("bots.empty.title"), 16, bold: true, wrap: true);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        title.Margin = new Thickness(0, 6, 0, 14);
        stack.Children.Add(title);
        var presets = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var preset in Bot.Presets(_model.Localization))
        {
            var card = new StackPanel { Width = 150 };
            card.Children.Add(Ui.Text(Bot.Glyph(preset.Symbol) + "  " + preset.Name, bold: true));
            card.Children.Add(Ui.Text(preset.Instructions, 11, secondary: true, wrap: true));
            var border = Ui.Card(card);
            border.Cursor = new Cursor(StandardCursorType.Hand);
            border.MaxHeight = 150;
            border.PointerReleased += (_, _) =>
            {
                _store.Upsert(preset);
                _store.SelectedBotId = preset.Id;
                Render();
            };
            presets.Children.Add(border);
        }
        stack.Children.Add(presets);
        stack.Children.Add(Ui.Button("+ " + _model.L("bots.new"), () => Edit(null), primary: true));
        return stack;
    }

    private Control Chat(Bot bot)
    {
        // Header: name, model, effort, actions.
        var header = new DockPanel { Margin = new Thickness(16, 10, 16, 10) };
        var actions = Ui.Row(
            ModelPicker(bot),
            EffortPicker(bot),
            Ui.Button("✎", () => Edit(bot), _model.L("bots.edit")),
            Ui.Button("⌫", () => _store.ClearHistory(bot.Id), _model.L("bots.clear")));
        actions.Margin = new Thickness(0);
        DockPanel.SetDock(actions, Dock.Right);
        header.Children.Add(actions);
        var name = new StackPanel();
        name.Children.Add(Ui.Text(Bot.Glyph(bot.Symbol) + "  " + bot.Name, 15, bold: true));
        if (ScheduledTaskRunner.NormalizeWorkspace(bot.WorkspacePath) is { } folder)
            name.Children.Add(Ui.Text(_model.L("bots.agentIn", System.IO.Path.GetFileName(folder.TrimEnd('\\', '/'))), 11, secondary: true));
        header.Children.Add(name);

        var messages = new StackPanel { Margin = new Thickness(16, 8, 16, 8) };
        if (bot.Messages.Count == 0)
            messages.Children.Add(Ui.Text(_model.L("bots.greeting", bot.Name), secondary: true, wrap: true));
        foreach (var message in bot.Messages)
        {
            var bubble = new Border
            {
                Child = new TextBox
                {
                    Text = message.Text, IsReadOnly = true, BorderThickness = new Thickness(0), Background = null,
                    TextWrapping = TextWrapping.Wrap, Foreground = Ui.Brush("TextPrimary"),
                },
                Background = Ui.Brush(message.IsUser ? "BubbleUser" : "BubbleAssistant"),
                CornerRadius = new CornerRadius(14), Padding = new Thickness(10, 6, 10, 6), MaxWidth = 560,
                Margin = new Thickness(0, 0, 0, 6), Opacity = message.Delivered ? 1 : 0.6,
                HorizontalAlignment = message.IsUser ? HorizontalAlignment.Right : HorizontalAlignment.Left,
            };
            messages.Children.Add(bubble);
        }
        if (_store.IsBusy(bot.Id)) messages.Children.Add(Ui.Text("…", 18, secondary: true));
        if (_store.Errors.TryGetValue(bot.Id, out var error))
        {
            var text = Ui.Text(error, 12, wrap: true);
            text.Foreground = Brushes.IndianRed;
            messages.Children.Add(text);
        }
        _messagesScroll = new ScrollViewer { Content = messages, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        _messagesScroll.Loaded += (_, _) => _messagesScroll.ScrollToEnd();

        var busy = _store.IsBusy(bot.Id);
        var send = busy
            ? Ui.Button("■", () => _store.Stop(bot.Id), _model.L("common.stop"))
            : Ui.Button("↑", Send, _model.L("bots.send"), primary: true);
        send.Margin = new Thickness(6, 0, 0, 0);
        var composer = new DockPanel { Margin = new Thickness(16, 6, 16, 14) };
        DockPanel.SetDock(send, Dock.Right);
        composer.Children.Add(send);
        ToolTip.SetTip(_draft, _model.L("bots.placeholder", bot.Name));
        if (_draft.Parent is Panel old) old.Children.Remove(_draft);
        composer.Children.Add(_draft);

        var root = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        DockPanel.SetDock(composer, Dock.Bottom);
        root.Children.Add(header);
        root.Children.Add(composer);
        root.Children.Add(_messagesScroll);
        return root;
    }

    private ComboBox ModelPicker(Bot bot)
    {
        var box = new ComboBox { MinWidth = 150, Margin = new Thickness(0, 0, 6, 0), [ToolTip.TipProperty] = _model.L("studio.settings.model") };
        box.Items.Add(new ComboBoxItem { Content = _model.L("models.followApp"), Tag = "" });
        foreach (var id in _model.Router.Models) box.Items.Add(new ComboBoxItem { Content = id, Tag = id });
        box.SelectedItem = box.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == bot.ModelId) ?? box.Items[0];
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedItem is not ComboBoxItem { Tag: string id } || id == bot.ModelId) return;
            bot.ModelId = id;
            _store.Upsert(bot);
        };
        return box;
    }

    private ComboBox EffortPicker(Bot bot)
    {
        var model = _store.UsableModel(bot.ModelId) is { Length: > 0 } chosen ? chosen : _model.Router.SelectedModelID;
        var box = new ComboBox { MinWidth = 90, Margin = new Thickness(0, 0, 6, 0), [ToolTip.TipProperty] = _model.L("modelPicker.effort") };
        box.Items.Add(new ComboBoxItem { Content = "—", Tag = "" });
        foreach (var level in NativeEffortCatalog.Levels(model)) box.Items.Add(new ComboBoxItem { Content = level, Tag = level });
        box.SelectedItem = box.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == bot.Effort) ?? box.Items[0];
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedItem is not ComboBoxItem { Tag: string level } || level == bot.Effort) return;
            bot.Effort = level;
            _store.Upsert(bot);
        };
        return box;
    }

    private void Send()
    {
        if (_store.SelectedBotId is not { } id || string.IsNullOrWhiteSpace(_draft.Text)) return;
        var text = _draft.Text;
        _draft.Text = "";
        _store.Send(text, id);
        _draft.Focus();
    }

    private async void Delete(Bot bot)
    {
        if (await Ui.Confirm(this, _model.L("bots.deleteConfirm", bot.Name), _model.L("common.delete")))
            _store.Delete(bot.Id);
    }

    /// <summary>Name, icon, instructions and the folder that makes the bot an agent.</summary>
    private async void Edit(Bot? existing)
    {
        var bot = existing?.Copy() ?? new Bot { Name = _model.L("bots.new") };
        var name = Ui.Field(bot.Name);
        var symbols = new ComboBox { Margin = new Thickness(0, 0, 0, 6) };
        foreach (var symbol in Bot.Symbols) symbols.Items.Add(new ComboBoxItem { Content = Bot.Glyph(symbol), Tag = symbol });
        symbols.SelectedItem = symbols.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == bot.Symbol) ?? symbols.Items[0];
        var instructions = Ui.Field(bot.Instructions, multiline: true);
        instructions.MinHeight = 110;
        var workspace = Ui.Text(string.IsNullOrEmpty(bot.WorkspacePath) ? _model.L("bots.workspace.none") : bot.WorkspacePath, 12, secondary: true, wrap: true);
        var choose = Ui.Button(_model.L("bots.workspace.choose"), async () =>
        {
            if (await Ui.OpenFolder(this) is { } folder) { bot.WorkspacePath = folder; workspace.Text = folder; }
        });
        var clear = Ui.Button(_model.L("bots.workspace.clear"), () => { bot.WorkspacePath = ""; workspace.Text = _model.L("bots.workspace.none"); });

        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(Ui.Text(_model.L("bots.name"), 11, bold: true));
        panel.Children.Add(name);
        panel.Children.Add(Ui.Text(_model.L("bots.icon"), 11, bold: true));
        panel.Children.Add(symbols);
        panel.Children.Add(Ui.Text(_model.L("bots.instructions"), 11, bold: true));
        panel.Children.Add(instructions);
        panel.Children.Add(Ui.Text(_model.L("bots.instructionsHelp"), 11, secondary: true, wrap: true));
        var workspaceTitle = Ui.Text(_model.L("bots.workspace"), 11, bold: true);
        workspaceTitle.Margin = new Thickness(0, 10, 0, 0);
        panel.Children.Add(workspaceTitle);
        panel.Children.Add(workspace);
        panel.Children.Add(Ui.Row(choose, clear));
        panel.Children.Add(Ui.Text(_model.L("bots.workspaceHelp"), 11, secondary: true, wrap: true));
        var window = new Window
        {
            Title = existing is null ? _model.L("bots.new") : _model.L("bots.edit"),
            Width = 460, SizeToContent = SizeToContent.Height, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = Ui.Brush("WindowBackground"), CanResize = false,
        };
        var save = Ui.Button(_model.L("common.save"), () =>
        {
            if (string.IsNullOrWhiteSpace(name.Text)) return;
            bot.Name = name.Text.Trim();
            bot.Symbol = (symbols.SelectedItem as ComboBoxItem)?.Tag as string ?? "sparkles";
            bot.Instructions = instructions.Text;
            _store.Upsert(bot);
            _store.SelectedBotId = bot.Id;
            window.Close(true);
        }, primary: true);
        save.IsDefault = true;
        var cancel = Ui.Button(_model.L("common.cancel"), () => window.Close(false));
        var buttons = Ui.Row(save, cancel);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        buttons.Margin = new Thickness(0, 12, 0, 0);
        panel.Children.Add(buttons);
        window.Content = panel;
        if (Ui.OwnerOf(this) is { } owner && await window.ShowDialog<bool>(owner)) Render();
    }
}
