// Copyright (c) 2026 DOTS
// Media section: the project grid, templates, library and music, plus the
// settings that feed generation. Mirrors MediaView, MediaLibraryView and MusicStudioView on macOS.

using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using DotsHarnessCore;

namespace DotsHarness.Views;

internal sealed class MediaView : UserControl, ISectionView
{
    private static readonly string[] Tabs = ["projects", "templates", "music", "library"];
    private static readonly Dictionary<string, string> TabGlyphs = new()
    {
        ["projects"] = "◷", ["templates"] = "▦", ["music"] = "♪", ["library"] = "📚",
    };

    private readonly AppModel _model;
    private readonly MediaStudioStore _store;
    private readonly MusicStudioStore _music;
    private readonly ContentControl _body = new();
    private readonly TextBox _query = new() { Padding = new Thickness(6, 4, 6, 4) };
    private readonly StackPanel _sidebar = new() { Margin = new Thickness(10) };
    private readonly DockPanel _home = new();
    private string _tab = "projects";
    private string _category = "social";
    private bool _sortByName;
    private string? _libraryKind;
    private string _pendingPrompt = "";
    private string? _notice;
    private readonly HashSet<string> _starred;

    public MediaView(AppModel model)
    {
        _model = model;
        _store = model.MediaStudio;
        _music = model.MusicStudio;
        _starred = ReadSet("media.home.starred");
        _tab = model.Host.Settings.Get("media.home.tab")?.AsString() is { } saved && Tabs.Contains(saved) ? saved : "projects";
        _query.TextChanged += (_, _) => RenderBody();
        _query.ToolTip = model.L("studio.home.search");
        _store.Changed += () => Dispatcher.BeginInvoke(RenderIfHome);
        _music.Changed += () => Dispatcher.BeginInvoke(RenderIfHome);
        MediaLibrary.Changed += () => Dispatcher.BeginInvoke(RenderIfHome);
        var left = new Border { Width = 240, Background = Ui.Brush("ChromeBackground"), BorderBrush = Ui.Brush("BorderSubtle"), BorderThickness = new Thickness(0, 0, 1, 0), Child = new ScrollViewer { Content = _sidebar, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
        DockPanel.SetDock(left, Dock.Left);
        _home.Children.Add(left);
        _home.Children.Add(_body);
        _home.Background = Ui.Brush("WindowBackground");
    }

    private HashSet<string> ReadSet(string key) =>
        (_model.Host.Settings.Get(key)?.AsString() ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries).ToHashSet();

    private void WriteSet(string key, HashSet<string> set) =>
        _model.Host.Settings.Set(key, HarnessPluginKit.JsonValue.String(string.Join(",", set.Order())));

    public void Activate()
    {
        _store.LoadIfNeeded();
        _music.LoadIfNeeded();
        Render();
    }

    private void RenderIfHome()
    {
        if (_store.OpenProjectId is null && _music.OpenProjectId is null) Render();
    }

    /// <summary>An open project takes over the section; closing it lands back on the home grid.</summary>
    private void Render()
    {
        if (_store.Find(_store.OpenProjectId) is { } project)
        {
            if (Content is not MediaEditorView editor || editor.ProjectId != project.Id)
                Content = new MediaEditorView(_model, project, _pendingPrompt, Close);
            _pendingPrompt = "";
            return;
        }
        if (_music.Find(_music.OpenProjectId) is { } song)
        {
            if (Content is not MusicEditorView editor || editor.ProjectId != song.Id)
                Content = new MusicEditorView(_model, song, Close);
            return;
        }
        Content = _home;
        RenderSidebar();
        RenderBody();
    }

    private void Close()
    {
        _store.OpenProjectId = null;
        _music.OpenProjectId = null;
        Render();
    }

    private Button SidebarRow(string glyph, string title, bool selected, Action click)
    {
        var button = new Button
        {
            Content = new TextBlock { Text = $"{glyph}   {title}", TextTrimming = TextTrimming.CharacterEllipsis },
            HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(8, 6, 8, 6),
            BorderThickness = new Thickness(0), Margin = new Thickness(0, 0, 0, 2),
            Background = selected ? new SolidColorBrush(Color.FromArgb(0x40, 0x3B, 0x82, 0xF6)) : Brushes.Transparent,
            Foreground = Ui.Brush("TextPrimary"),
        };
        button.Click += (_, _) => click();
        return button;
    }

    private void RenderSidebar()
    {
        _sidebar.Children.Clear();
        _query.Margin = new Thickness(0, 0, 0, 10);
        if (_query.Parent is Panel old) old.Children.Remove(_query);
        _sidebar.Children.Add(_query);
        foreach (var tab in Tabs)
        {
            _sidebar.Children.Add(SidebarRow(TabGlyphs[tab], _model.L($"studio.{tab}"), _tab == tab, () =>
            {
                _tab = tab;
                _model.Host.Settings.Set("media.home.tab", HarnessPluginKit.JsonValue.String(tab));
                Render();
            }));
        }
        _sidebar.Children.Add(new Separator { Margin = new Thickness(0, 8, 0, 8) });
        var settings = new StackPanel();
        settings.Children.Add(Ui.Text(_model.L("studio.settings.title"), bold: true));
        settings.Children.Add(Ui.Text(MediaSettingsPanel.Summary(_store.Settings, NativeMediaKind.Image), 11, secondary: true));
        var card = Ui.Card(settings, 10);
        card.Margin = new Thickness(0);
        card.Cursor = Cursors.Hand;
        card.MouseLeftButtonUp += (_, _) => MediaSettingsPanel.ShowDialog(_model, this, Render);
        _sidebar.Children.Add(card);
        _sidebar.Children.Add(new Separator { Margin = new Thickness(0, 8, 0, 8) });
        _sidebar.Children.Add(Ui.Text(_model.L("studio.home.starred"), 12, bold: true));
        foreach (var project in _store.Projects.Where(p => _starred.Contains(p.Id)))
        {
            var row = SidebarRow("📁", project.Name, false, () => Open(project));
            row.ContextMenu = ProjectMenu(project);
            _sidebar.Children.Add(row);
        }
    }

    private bool Matches(string name) => _query.Text.Length == 0 || name.Contains(_query.Text, StringComparison.CurrentCultureIgnoreCase);

    private void RenderBody()
    {
        if (Content != _home) return;
        _body.Content = _tab switch
        {
            "music" => MusicPane(),
            "library" => LibraryPane(),
            _ => Grid(),
        };
        if (_notice is { } notice)
        {
            _notice = null;
            MessageBox.Show(Ui.OwnerOf(this)!, notice, _model.L("rail.media"));
        }
    }

    private static DockPanel Page(string title, UIElement? trailing, UIElement content)
    {
        var header = new DockPanel { Margin = new Thickness(28, 12, 28, 8) };
        if (trailing is not null)
        {
            DockPanel.SetDock(trailing, Dock.Right);
            header.Children.Add(trailing);
        }
        header.Children.Add(Ui.Text(title, 15, bold: true));
        var page = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        page.Children.Add(header);
        page.Children.Add(new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        return page;
    }

    private UIElement Grid()
    {
        var content = new StackPanel();
        content.Children.Add(Hero());

        // Filter chips narrow templates and sort projects.
        var filters = new WrapPanel { Margin = new Thickness(28, 0, 28, 12) };
        ToggleButtonLike(filters);
        content.Children.Add(filters);

        var cards = new WrapPanel { Margin = new Thickness(28, 0, 16, 28) };
        if (_tab == "templates")
        {
            foreach (var template in MediaTemplate.All.Where(t => t.Category == _category && Matches(t.Title)))
            {
                var canvas = template.Canvas();
                cards.Children.Add(Card(canvas, "", template.Title, $"{(int)canvas.Width} × {(int)canvas.Height}",
                    () => Open(_store.Create(template.Title, template.Canvas()))));
            }
        }
        else
        {
            var projects = _store.Projects.Where(p => Matches(p.Name));
            projects = _sortByName ? projects.OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase) : projects.OrderByDescending(p => p.UpdatedAt);
            if (_store.Projects.Count == 0)
            {
                var empty = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 60, 0, 0) };
                empty.Children.Add(Ui.Text(_model.L("studio.empty.title"), 15, bold: true));
                empty.Children.Add(Ui.Text(_model.L("studio.empty.detail"), secondary: true, wrap: true));
                empty.Children.Add(Ui.Button(_model.L("studio.newProject"), NewProject, primary: true));
                content.Children.Add(empty);
            }
            foreach (var project in projects)
            {
                var card = Card(project.Canvases.FirstOrDefault(), project.Id, project.Name,
                    _model.L("studio.projectMeta", project.Canvases.Count, Ui.Relative(project.UpdatedAt)), () => Open(project));
                card.ContextMenu = ProjectMenu(project);
                cards.Children.Add(card);
            }
        }
        content.Children.Add(cards);
        return Page(_model.L("rail.media"), Ui.Button("+ " + _model.L("studio.newProject"), NewProject), content);
    }

    private void ToggleButtonLike(WrapPanel filters)
    {
        Button Chip(string title, bool selected, Action click)
        {
            var chip = Ui.Button(title, click);
            chip.Margin = new Thickness(0, 0, 8, 6);
            if (selected) chip.Background = new SolidColorBrush(Color.FromArgb(0x50, 0x3B, 0x82, 0xF6));
            return chip;
        }
        if (_tab == "templates")
            foreach (var category in MediaTemplate.Categories)
                filters.Children.Add(Chip(_model.L($"studio.category.{category}"), _category == category, () => { _category = category; RenderBody(); }));
        else
        {
            filters.Children.Add(Chip(_model.L("sidebar.sortLastUpdate"), !_sortByName, () => { _sortByName = false; RenderBody(); }));
            filters.Children.Add(Chip(_model.L("studio.home.sort.name"), _sortByName, () => { _sortByName = true; RenderBody(); }));
        }
    }

    /// <summary>The band that turns a typed idea into a project with the request already running.</summary>
    private UIElement Hero()
    {
        var idea = new TextBox { FontSize = 14, BorderThickness = new Thickness(0), VerticalContentAlignment = VerticalAlignment.Center, ToolTip = _model.L("studio.ai.placeholder.design") };
        void Make()
        {
            var text = idea.Text.Trim();
            if (text.Length == 0) return;
            _pendingPrompt = text;
            Open(_store.Create(text.Length > 40 ? text[..40] : text));
        }
        idea.KeyDown += (_, e) => { if (e.Key == Key.Enter) Make(); };
        var create = Ui.Button(_model.L("studio.create") + " →", Make, primary: true);
        DockPanel.SetDock(create, Dock.Right);
        var bar = new DockPanel { Height = 52 };
        bar.Children.Add(create);
        bar.Children.Add(idea);
        var box = new Border
        {
            Child = bar, Padding = new Thickness(16, 6, 10, 6), CornerRadius = new CornerRadius(14), Background = Ui.Brush("PanelBackground"),
            BorderBrush = Ui.Brush("BorderSubtle"), BorderThickness = new Thickness(1),
        };
        var stack = new StackPanel { Margin = new Thickness(28, 18, 28, 22) };
        stack.Children.Add(Ui.Text(_model.L("studio.home.title") + "  · AI", 20, bold: true));
        box.Margin = new Thickness(0, 12, 0, 0);
        stack.Children.Add(box);
        return new Border
        {
            Child = stack,
            Background = new LinearGradientBrush(Color.FromArgb(0x50, 0x3B, 0x82, 0xF6), Color.FromArgb(0, 0x3B, 0x82, 0xF6), 90),
        };
    }

    private FrameworkElement Card(MediaCanvas? canvas, string projectId, string title, string detail, Action open)
    {
        var preview = new Border { Height = 170, Background = new SolidColorBrush(Color.FromArgb(0x2E, 0, 0, 0)), Padding = new Thickness(12), CornerRadius = new CornerRadius(10, 10, 0, 0) };
        preview.Child = MediaRenderer.Preview(canvas, name => _store.AssetPath(projectId, name));
        var stack = new StackPanel { Width = 250 };
        stack.Children.Add(preview);
        var texts = new StackPanel { Margin = new Thickness(12, 10, 12, 4) };
        texts.Children.Add(Ui.Text(title, bold: true));
        texts.Children.Add(Ui.Text(detail, 12, secondary: true));
        stack.Children.Add(texts);
        var card = Ui.Card(stack, 0);
        card.Margin = new Thickness(0, 0, 18, 18);
        card.Cursor = Cursors.Hand;
        card.MouseLeftButtonUp += (_, e) => { if (e.OriginalSource is not Button) open(); };
        return card;
    }

    private static UIElement Centered(string text)
    {
        var block = Ui.Text(text, secondary: true, wrap: true);
        block.HorizontalAlignment = HorizontalAlignment.Center;
        block.Margin = new Thickness(0, 60, 0, 0);
        return block;
    }

    private ContextMenu ProjectMenu(MediaProject project)
    {
        var menu = new ContextMenu();
        void Add(string header, Action click)
        {
            var item = new MenuItem { Header = header };
            item.Click += (_, _) => click();
            menu.Items.Add(item);
        }
        Add(_model.L(_starred.Contains(project.Id) ? "studio.home.unstar" : "studio.home.star"), () =>
        {
            if (!_starred.Remove(project.Id)) _starred.Add(project.Id);
            WriteSet("media.home.starred", _starred);
            Render();
        });
        Add(_model.L("studio.rename"), () =>
        {
            if (Ui.Prompt(Ui.OwnerOf(this), _model.L("studio.rename"), project.Name) is { } name) _store.Rename(project.Id, name);
        });
        Add(_model.L("studio.duplicate"), () => _store.Duplicate(project.Id));
        menu.Items.Add(new Separator());
        Add(_model.L("common.delete"), () =>
        {
            if (MessageBox.Show(Ui.OwnerOf(this)!, _model.L("studio.deleteConfirm", project.Name), _model.L("rail.media"), MessageBoxButton.OKCancel) == MessageBoxResult.OK)
                _store.Delete(project.Id);
        });
        return menu;
    }

    private void NewProject() => Open(_store.Create(_model.L("studio.untitled")));

    private void Open(MediaProject project)
    {
        _store.OpenProjectId = project.Id;
        Render();
    }

    // Library

    private UIElement LibraryPane()
    {
        var content = new StackPanel();
        var kinds = new WrapPanel { Margin = new Thickness(28, 0, 28, 12) };
        foreach (var kind in new string?[] { null }.Concat(MediaLibraryItem.Kinds))
        {
            var chip = Ui.Button(kind is null ? _model.L("library.all") : _model.L($"library.kind.{kind}"), () => { _libraryKind = kind; RenderBody(); });
            chip.Margin = new Thickness(0, 0, 6, 6);
            if (_libraryKind == kind) chip.Background = new SolidColorBrush(Color.FromArgb(0x50, 0x3B, 0x82, 0xF6));
            kinds.Children.Add(chip);
        }
        content.Children.Add(kinds);
        var items = MediaLibrary.Items(_model.Paths.Root)
            .Where(i => (_libraryKind is null || i.Kind == _libraryKind) && Matches(i.DisplayTitle)).ToList();
        if (items.Count == 0)
        {
            var empty = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 50, 0, 0) };
            empty.Children.Add(Ui.Text(_model.L("library.empty.title"), 15, bold: true));
            empty.Children.Add(Ui.Text(_model.L("library.empty.detail"), secondary: true, wrap: true));
            content.Children.Add(empty);
        }
        var cards = new WrapPanel { Margin = new Thickness(28, 0, 16, 28) };
        foreach (var item in items)
        {
            var exists = File.Exists(item.Path);
            var thumb = new Border { Height = 140, Background = new SolidColorBrush(Color.FromArgb(0x2E, 0, 0, 0)), CornerRadius = new CornerRadius(10, 10, 0, 0) };
            thumb.Child = !exists ? Centered(_model.L("media.fileMissing"))
                : item.Kind == "image" && MediaRenderer.Image(item.Path) is { } image ? new Image { Source = image, Stretch = Stretch.UniformToFill }
                : new TextBlock { Text = item.Kind switch { "video" => "🎬", "audio" => "🔊", "music" => "♪", _ => "📄" }, FontSize = 40, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            var stack = new StackPanel { Width = 220 };
            stack.Children.Add(thumb);
            var texts = new StackPanel { Margin = new Thickness(12, 8, 12, 10) };
            texts.Children.Add(Ui.Text(item.DisplayTitle, bold: true));
            texts.Children.Add(Ui.Text($"{_model.L($"library.kind.{item.Kind}")} · {Ui.Relative(item.CreatedAt)}", 11, secondary: true));
            stack.Children.Add(texts);
            var card = Ui.Card(stack, 0);
            card.Margin = new Thickness(0, 0, 16, 16);
            card.ToolTip = item.Title;
            card.Cursor = Cursors.Hand;
            card.MouseLeftButtonUp += (_, _) => { if (exists) Ui.Open(item.Path); };
            var menu = new ContextMenu();
            var open = new MenuItem { Header = _model.L("library.open"), IsEnabled = exists };
            open.Click += (_, _) => Ui.Open(item.Path);
            var reveal = new MenuItem { Header = _model.L("media.showInFinder"), IsEnabled = exists };
            reveal.Click += (_, _) => Ui.Reveal(item.Path);
            var remove = new MenuItem { Header = _model.L("common.remove") };
            remove.Click += (_, _) => MediaLibrary.Remove(item.Id, _model.Paths.Root);
            menu.Items.Add(open);
            menu.Items.Add(reveal);
            menu.Items.Add(new Separator());
            menu.Items.Add(remove);
            card.ContextMenu = menu;
            cards.Children.Add(card);
        }
        content.Children.Add(cards);
        var page = Page(_model.L("studio.library"), Ui.Button("+ " + _model.L("library.add"), AddFiles), content);
        page.AllowDrop = true;
        page.Drop += (_, e) => { if (e.Data.GetData(DataFormats.FileDrop) is string[] files) Add(files); };
        return page;
    }

    private void AddFiles()
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Multiselect = true };
        if (dialog.ShowDialog() == true) Add(dialog.FileNames);
    }

    private void Add(IEnumerable<string> files)
    {
        var failed = 0;
        foreach (var file in files)
        {
            try { MediaLibrary.ImportFile(file, _model.Paths.Root); }
            catch (Exception) { failed++; }
        }
        if (failed > 0) _notice = _model.L("library.addFailed", failed);
        RenderBody();
    }

    // Music

    private UIElement MusicPane()
    {
        var content = new StackPanel { Margin = new Thickness(28, 0, 28, 28) };
        var brief = new TextBox { FontSize = 14, BorderThickness = new Thickness(0), VerticalContentAlignment = VerticalAlignment.Center, ToolTip = _model.L("studio.music.placeholder") };
        var status = Ui.Text("", 12, secondary: true, wrap: true);
        Button? plan = null;
        async void Plan()
        {
            var text = brief.Text.Trim();
            if (text.Length == 0 || plan is null || !plan.IsEnabled) return;
            plan.IsEnabled = false;
            status.Text = "…";
            try
            {
                var project = await MusicStudioAI.PlanAsync(text, _model.Router, _store.Settings);
                _music.Save(project);
                _music.OpenProjectId = project.Id;
                Render();
            }
            catch (Exception ex) { status.Text = ex.Message; plan.IsEnabled = true; }
        }
        plan = Ui.Button(_model.L("studio.music.plan"), Plan, primary: true);
        brief.KeyDown += (_, e) => { if (e.Key == Key.Enter) Plan(); };
        var source = Ui.Button(MediaSettingsPanel.Summary(_store.Settings, NativeMediaKind.Music), () => MediaSettingsPanel.ShowDialog(_model, this, Render), _model.L("studio.settings.title"));
        var trailing = Ui.Row(source, plan);
        trailing.Margin = new Thickness(0);
        DockPanel.SetDock(trailing, Dock.Right);
        var composer = new DockPanel { Height = 46 };
        composer.Children.Add(trailing);
        composer.Children.Add(brief);
        content.Children.Add(new Border { Child = composer, Padding = new Thickness(14, 4, 8, 4), CornerRadius = new CornerRadius(14), Background = Ui.Brush("PanelBackground"), BorderBrush = Ui.Brush("BorderSubtle"), BorderThickness = new Thickness(1), Margin = new Thickness(0, 0, 0, 8) });
        content.Children.Add(status);
        var songs = _music.Projects.Where(p => Matches(p.Name)).ToList();
        if (songs.Count == 0) content.Children.Add(Centered(_model.L("studio.music.empty")));
        var cards = new WrapPanel { Margin = new Thickness(0, 12, 0, 0) };
        foreach (var song in songs)
        {
            var stack = new StackPanel { Width = 200 };
            stack.Children.Add(Ui.Text("🎼", 22));
            stack.Children.Add(Ui.Text(song.Name, bold: true));
            stack.Children.Add(Ui.Text(_model.L("studio.music.trackCount", song.Tracks.Count) + " · " + Ui.Relative(song.UpdatedAt), 11, secondary: true));
            var card = Ui.Card(stack);
            card.Cursor = Cursors.Hand;
            card.MouseLeftButtonUp += (_, _) => { _music.OpenProjectId = song.Id; Render(); };
            var menu = new ContextMenu();
            var delete = new MenuItem { Header = _model.L("common.delete") };
            delete.Click += (_, _) =>
            {
                if (MessageBox.Show(Ui.OwnerOf(this)!, _model.L("studio.music.deleteConfirm", song.Name), _model.L("studio.music"), MessageBoxButton.OKCancel) == MessageBoxResult.OK)
                    _music.Delete(song.Id);
            };
            menu.Items.Add(delete);
            card.ContextMenu = menu;
            cards.Children.Add(card);
        }
        content.Children.Add(cards);
        return Page(_model.L("studio.music"), Ui.Button("+ " + _model.L("studio.music.new"), () =>
        {
            var song = new MusicProject { Name = _model.L("studio.untitled"), Sections = [new MusicSection { Name = _model.L("studio.music.section.default") }] };
            _music.Save(song);
            _music.OpenProjectId = song.Id;
            Render();
        }), content);
    }
}

/// <summary>Which models the studio uses. Shown in Media and under Settings.</summary>
internal sealed class MediaSettingsPanel : UserControl
{
    private readonly AppModel _model;
    private readonly MediaStudioStore _store;
    private readonly StackPanel _panel = new() { MaxWidth = 520, HorizontalAlignment = HorizontalAlignment.Left };

    public MediaSettingsPanel(AppModel model)
    {
        _model = model;
        _store = model.MediaStudio;
        _store.LoadIfNeeded();
        Content = _panel;
        Render();
    }

    public static string Summary(MediaStudioSettings settings, NativeMediaKind kind)
    {
        var model = settings.ModelFor(kind);
        var source = (kind == NativeMediaKind.Music ? settings.MusicEndpoint?.Name : null)
            ?? LocalizationService.Current.Get($"studio.settings.source.{settings.SourceFor(kind)}");
        return model.Length == 0 ? source : $"{source} · {model}";
    }

    public static void ShowDialog(AppModel model, DependencyObject owner, Action done)
    {
        var window = new Window
        {
            Owner = Ui.OwnerOf(owner), Title = model.L("studio.settings.title"), Width = 500, Height = 600,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Ui.Brush("WindowBackground"),
            Content = new ScrollViewer { Content = new MediaSettingsPanel(model) { Margin = new Thickness(16) }, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
        };
        window.ShowDialog();
        done();
    }

    private void Save() => _store.Settings = _store.Settings;

    private void Section(string title) => _panel.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, FontSize = 14, Margin = new Thickness(0, 14, 0, 6), Foreground = Ui.Brush("TextPrimary") });

    private ComboBox Source(string value, Action<string> set)
    {
        var box = new ComboBox { Margin = new Thickness(0, 0, 0, 6) };
        foreach (var source in new[] { MediaStudioSettings.Provider, MediaStudioSettings.Local })
            box.Items.Add(new ComboBoxItem { Content = _model.L($"studio.settings.source.{source}"), Tag = source });
        box.SelectedItem = box.Items.OfType<ComboBoxItem>().First(i => (string)i.Tag == value);
        box.SelectionChanged += (_, _) => { set((string)((ComboBoxItem)box.SelectedItem).Tag); Save(); };
        return box;
    }

    private TextBox Text(string value, string hint, Action<string> set)
    {
        var box = Ui.Field(value, hint);
        box.LostFocus += (_, _) => { set(box.Text.Trim()); Save(); };
        return box;
    }

    private void Render()
    {
        _panel.Children.Clear();
        var settings = _store.Settings;
        Section(_model.L("studio.settings.design"));
        var planner = new ComboBox { Margin = new Thickness(0, 0, 0, 6) };
        planner.Items.Add(new ComboBoxItem { Content = _model.L("models.followApp"), Tag = "" });
        foreach (var id in _model.Router.Models) planner.Items.Add(new ComboBoxItem { Content = id, Tag = id });
        planner.SelectedItem = planner.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == settings.PlannerModelID) ?? planner.Items[0];
        planner.SelectionChanged += (_, _) => { settings.PlannerModelID = (string)((ComboBoxItem)planner.SelectedItem).Tag; Save(); };
        _panel.Children.Add(planner);
        _panel.Children.Add(Ui.Text(_model.L("studio.settings.designHelp"), 11, secondary: true, wrap: true));

        Section(_model.L("studio.ai.kind.image"));
        _panel.Children.Add(Source(settings.ImageSource, v => settings.ImageSource = v));
        _panel.Children.Add(Text(settings.ImageModel, _model.L("studio.settings.modelDefault"), v => settings.ImageModel = v));
        Section(_model.L("studio.ai.kind.video"));
        _panel.Children.Add(Source(settings.VideoSource, v => settings.VideoSource = v));
        _panel.Children.Add(Text(settings.VideoModel, _model.L("studio.settings.modelDefault"), v => settings.VideoModel = v));

        Section(_model.L("library.kind.music"));
        var music = new ComboBox { Margin = new Thickness(0, 0, 0, 6) };
        foreach (var source in new[] { MediaStudioSettings.Provider, MediaStudioSettings.Local })
            music.Items.Add(new ComboBoxItem { Content = _model.L($"studio.settings.source.{source}"), Tag = source });
        foreach (var endpoint in settings.MusicEndpoints) music.Items.Add(new ComboBoxItem { Content = endpoint.Name, Tag = endpoint.Id });
        music.SelectedItem = music.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == (settings.MusicEndpoint?.Id ?? settings.MusicSource)) ?? music.Items[0];
        music.SelectionChanged += (_, _) =>
        {
            var tag = (string)((ComboBoxItem)music.SelectedItem).Tag;
            if (tag is MediaStudioSettings.Provider or MediaStudioSettings.Local) { settings.MusicSource = tag; settings.MusicEndpointID = ""; }
            else settings.MusicEndpointID = tag;
            Save();
            Render();
        };
        _panel.Children.Add(music);
        if (settings.MusicEndpoint is { } chosen)
        {
            _panel.Children.Add(Text(chosen.Name, _model.L("studio.settings.music.name"), v => chosen.Name = v));
            _panel.Children.Add(Text(chosen.BaseURL, _model.L("studio.settings.localURL"), v => chosen.BaseURL = v));
            var key = new PasswordBox { Password = chosen.ApiKey(_model.Secrets) ?? "", Padding = new Thickness(6, 4, 6, 4), Margin = new Thickness(0, 0, 0, 6), ToolTip = _model.L("studio.settings.music.key") };
            key.LostFocus += (_, _) => chosen.SetApiKey(_model.Secrets, key.Password);
            _panel.Children.Add(key);
            _panel.Children.Add(ModelField(chosen.Model, v => chosen.Model = v, chosen));
            _panel.Children.Add(Ui.Button(_model.L("common.remove"), () =>
            {
                chosen.SetApiKey(_model.Secrets, null);
                settings.MusicEndpointID = "";
                settings.MusicEndpoints.Remove(chosen);
                Save();
                Render();
            }));
        }
        else _panel.Children.Add(ModelField(settings.MusicModel, v => settings.MusicModel = v, null));
        var connect = new ComboBox { Margin = new Thickness(0, 6, 0, 6), Text = _model.L("studio.settings.music.connect"), IsEditable = true, IsReadOnly = true };
        foreach (var format in new[] { MusicEndpoint.Standard, MusicEndpoint.ElevenLabs })
            connect.Items.Add(new ComboBoxItem { Content = _model.L($"studio.settings.music.type.{format}"), Tag = format });
        connect.SelectionChanged += (_, _) =>
        {
            if (connect.SelectedItem is not ComboBoxItem { Tag: string format }) return;
            var endpoint = new MusicEndpoint
            {
                Name = _model.L($"studio.settings.music.type.{format}"), Format = format,
                BaseURL = MusicEndpoint.DefaultBaseUrl(format), Model = MusicEndpoint.KnownModels(format).FirstOrDefault() ?? "",
            };
            settings.MusicEndpoints.Add(endpoint);
            settings.MusicEndpointID = endpoint.Id;
            Save();
            Render();
        };
        _panel.Children.Add(connect);
        _panel.Children.Add(Ui.Text(_model.L("studio.settings.music.help"), 11, secondary: true, wrap: true));

        Section(_model.L("studio.settings.local"));
        _panel.Children.Add(Text(settings.LocalBaseURL, _model.L("studio.settings.localURL"), v => settings.LocalBaseURL = v));
        _panel.Children.Add(Ui.Text(_model.L("studio.settings.localHelp"), 11, secondary: true, wrap: true));
    }

    /// <summary>A model name, with what the chosen server says it offers one click away.</summary>
    private UIElement ModelField(string value, Action<string> set, MusicEndpoint? endpoint)
    {
        var box = new ComboBox { IsEditable = true, Text = value, Margin = new Thickness(0, 0, 0, 6), ToolTip = _model.L("studio.settings.modelDefault") };
        box.LostFocus += (_, _) => { set(box.Text.Trim()); Save(); };
        box.SelectionChanged += (_, _) => { if (box.SelectedItem is string id) { set(id); Save(); } };
        box.DropDownOpened += async (_, _) =>
        {
            if (box.Items.Count > 0) return;
            var known = endpoint is null ? [] : MusicEndpoint.KnownModels(endpoint.Format);
            var models = known.Count > 0 ? known.ToList()
                : await MusicStudioAI.ModelsAsync(endpoint?.BaseURL ?? _store.Settings.LocalBaseURL, endpoint?.ApiKey(_model.Secrets));
            foreach (var id in models) box.Items.Add(id);
        };
        return box;
    }
}
