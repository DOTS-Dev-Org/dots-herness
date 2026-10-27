// Copyright (c) 2026 DOTS
// Media editor: layers on the left, a zoomable board of canvases, the inspector on the right,
// a floating tool dock and the AI request bar. Mirrors MediaEditorView, MediaEditorPanels and
// MediaEditorState on macOS; the editing logic itself is the shared MediaEditorModel.

using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using DotsHarnessCore;

namespace DotsHarness.Views;

internal sealed class MediaEditorView : UserControl
{
    private enum DragKind { None, Pan, MoveLayer, MoveCanvas, Resize, Draw, Pencil, Scale }

    private static readonly (double X, double Y)[] Handles = [(0, 0), (0.5, 0), (1, 0), (1, 0.5), (1, 1), (0.5, 1), (0, 1), (0, 0.5)];
    private static readonly string[][] ToolGroups =
    [
        ["move", "hand", "scale"], ["frame", "section", "slice"],
        ["rectangle", "line", "arrow", "ellipse", "polygon", "star"], ["pen", "pencil", "marker"], ["text", "textPath"], ["comment"],
    ];

    private readonly AppModel _app;
    private readonly MediaEditorModel _m;
    private readonly Action _close;
    private readonly Grid _viewport = new() { ClipToBounds = true, Background = Brushes.Transparent, Focusable = true };
    private readonly Canvas _board = new() { IsHitTestVisible = false };
    private readonly Canvas _overlay = new() { IsHitTestVisible = false };
    private readonly StackPanel _layers = new() { Margin = new Thickness(6) };
    private readonly StackPanel _inspector = new() { Margin = new Thickness(12) };
    private readonly StackPanel _dock = new() { Orientation = Orientation.Horizontal };
    private readonly TextBlock _status = new() { Foreground = Brushes.White, Margin = new Thickness(8, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center, MaxWidth = 280, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBox _prompt = new() { MinWidth = 220, MaxWidth = 460, Padding = new Thickness(6, 4, 6, 4), VerticalContentAlignment = VerticalAlignment.Center };
    private readonly ComboBox _aiKind = new() { Margin = new Thickness(0, 0, 6, 0) };
    private readonly Button _run;
    private readonly Border _layersPane;
    private readonly Border _inspectorPane;
    private readonly Dictionary<string, string> _groupTool = [];
    private DragKind _drag;
    private Point _dragStart;
    private (double X, double Y) _handle;
    private MediaLayer? _startLayer;
    private MediaCanvas? _startCanvas;
    private List<MediaCanvas> _startChildren = [];
    private string? _dragCanvasId;
    private readonly List<BoardPoint> _stroke = [];
    private bool _spaceDown;
    private bool _promptRan;
    private string _initialPrompt;
    private IReadOnlyList<MediaTemplate> _templates = [];

    public MediaEditorView(AppModel app, MediaProject project, string initialPrompt, Action close)
    {
        _app = app;
        _close = close;
        _initialPrompt = initialPrompt;
        _m = new MediaEditorModel(project, app.MediaStudio) { NaturalSize = MediaRenderer.NaturalSize };
        _m.Changed += () => Dispatcher.BeginInvoke(Refresh);
        ProjectId = project.Id;

        // Toolbar.
        var name = new TextBox { Text = project.Name, MinWidth = 120, MaxWidth = 240, FontWeight = FontWeights.SemiBold, BorderThickness = new Thickness(0), Background = null, Foreground = Ui.Brush("TextPrimary"), VerticalContentAlignment = VerticalAlignment.Center };
        name.LostFocus += (_, _) => app.MediaStudio.Rename(project.Id, name.Text);
        var toolbar = new DockPanel { Height = 40, Margin = new Thickness(8, 0, 8, 0) };
        var right = Ui.Row(
            Ui.Button("↶", _m.Undo, app.L("studio.undo")), Ui.Button("↷", _m.Redo, app.L("studio.redo")),
            Ui.Button("−", () => _m.ZoomBy(1 / 1.25), app.L("studio.zoomOut")), Ui.Button("⤢", _m.Fit, app.L("studio.zoomFit")),
            Ui.Button("+", () => _m.ZoomBy(1.25), app.L("studio.zoomIn")),
            Ui.Button("⇩", ShowExportMenu, app.L("studio.export")),
            Ui.Button("☰", () => TogglePane(_layersPane!), app.L("studio.layers")),
            Ui.Button("⚙", () => MediaSettingsPanel.ShowDialog(app, this, Refresh), app.L("studio.settings.title")));
        right.Margin = new Thickness(0);
        right.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(right, Dock.Right);
        toolbar.Children.Add(right);
        var back = Ui.Button("‹ " + app.L("studio.projects"), () => { _m.Commit(); _close(); });
        back.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(back, Dock.Left);
        toolbar.Children.Add(back);
        toolbar.Children.Add(name);

        // Board, with the dock and the request bar floating over its foot.
        _viewport.Background = SystemColors.ControlDarkBrush;
        _viewport.Children.Add(_board);
        _viewport.Children.Add(_overlay);
        foreach (var kind in MediaEditorModel.AiKinds) _aiKind.Items.Add(new ComboBoxItem { Content = app.L($"studio.ai.kind.{kind}"), Tag = kind });
        _aiKind.SelectedIndex = 0;
        _prompt.KeyDown += (_, e) => { if (e.Key == Key.Enter) { RunAI(); e.Handled = true; } };
        _run = Ui.Button("→", RunAI, app.L("studio.ai.run"), primary: true);
        var promptBar = new Border
        {
            Child = Ui.Row(_aiKind, _prompt, _run), Padding = new Thickness(8, 8, 2, 0), CornerRadius = new CornerRadius(12),
            Background = Ui.Brush("PanelBackground"), BorderBrush = Ui.Brush("BorderSubtle"), BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(12, 0, 12, 76),
        };
        var dock = new Border
        {
            Child = new StackPanel { Orientation = Orientation.Horizontal, Children = { _dock, _status } },
            Background = new SolidColorBrush(Color.FromRgb(0x1E, 0x1E, 0x22)), CornerRadius = new CornerRadius(12), Padding = new Thickness(6),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(12, 0, 12, 16),
        };
        _viewport.Children.Add(promptBar);
        _viewport.Children.Add(dock);
        _viewport.SizeChanged += (_, e) =>
        {
            _m.ViewportWidth = e.NewSize.Width;
            _m.ViewportHeight = e.NewSize.Height;
            if (e.PreviousSize.Width == 0) { _m.Fit(); RunInitialPrompt(); }
            Refresh();
        };
        _viewport.MouseDown += OnDown;
        _viewport.MouseMove += OnMove;
        _viewport.MouseUp += OnUp;
        _viewport.MouseWheel += OnWheel;
        _viewport.AllowDrop = true;
        _viewport.Drop += (_, e) =>
        {
            if (e.Data.GetData(DataFormats.FileDrop) is string[] files)
            {
                var p = e.GetPosition(_viewport);
                _m.AddFiles(files, _m.BoardPointAt(p.X, p.Y));
            }
        };
        _viewport.ContextMenu = BoardMenu();

        _layersPane = new Border { Width = 220, Background = Ui.Brush("ChromeBackground"), BorderBrush = Ui.Brush("BorderSubtle"), BorderThickness = new Thickness(0, 0, 1, 0), Child = new ScrollViewer { Content = _layers, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
        _inspectorPane = new Border { Width = 250, Background = Ui.Brush("ChromeBackground"), BorderBrush = Ui.Brush("BorderSubtle"), BorderThickness = new Thickness(1, 0, 0, 0), Child = new ScrollViewer { Content = _inspector, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
        var body = new DockPanel();
        DockPanel.SetDock(_layersPane, Dock.Left);
        DockPanel.SetDock(_inspectorPane, Dock.Right);
        body.Children.Add(_layersPane);
        body.Children.Add(_inspectorPane);
        body.Children.Add(_viewport);
        var root = new DockPanel { Background = Ui.Brush("WindowBackground") };
        DockPanel.SetDock(toolbar, Dock.Top);
        root.Children.Add(toolbar);
        root.Children.Add(body);
        Content = root;
        Focusable = true;
        PreviewKeyDown += OnKey;
        KeyUp += (_, e) => { if (e.Key == Key.Space) _spaceDown = false; };
        // The side panels give way before the board does, so the dock keeps its room in a narrow window.
        SizeChanged += (_, e) =>
        {
            _layersPane.Visibility = e.NewSize.Width < 900 ? Visibility.Collapsed : _layersPane.Visibility == Visibility.Collapsed && e.PreviousSize.Width < 900 ? Visibility.Visible : _layersPane.Visibility;
            _inspectorPane.Visibility = e.NewSize.Width < 640 ? Visibility.Collapsed : Visibility.Visible;
        };
        Loaded += (_, _) => _viewport.Focus();
        _ = RefreshTemplateCatalogAsync();
    }

    public string ProjectId { get; }

    private static void TogglePane(Border pane) =>
        pane.Visibility = pane.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;

    private void RunInitialPrompt()
    {
        if (_promptRan || string.IsNullOrWhiteSpace(_initialPrompt)) return;
        _promptRan = true;
        _m.RunAI(_initialPrompt, "design", _app.Router, _app.Paths, _app.Secrets);
    }

    private async Task RefreshTemplateCatalogAsync()
    {
        IReadOnlyList<MediaTemplate> templates;
        try
        {
            var cachePath = System.IO.Path.Combine(_app.Paths.Root, "media-studio", "template-catalog.json");
            templates = await MediaTemplateCatalogClient.LoadAsync(cachePath, _app.Localization.Culture.TwoLetterISOLanguageName);
        }
        catch { templates = []; }
        Dispatcher.BeginInvoke(() => { _templates = templates; DrawInspector(); });
    }

    private void RunAI()
    {
        if (_m.AiBusy) { _m.StopAI(); return; }
        var kind = (_aiKind.SelectedItem as ComboBoxItem)?.Tag as string ?? "design";
        _m.RunAI(_prompt.Text, kind, _app.Router, _app.Paths, _app.Secrets);
        if (_m.AiBusy) _prompt.Text = "";
    }

    // Drawing

    private void Refresh()
    {
        DrawBoard();
        DrawLayers();
        DrawInspector();
        DrawDock();
        _run.Content = _m.AiBusy ? "■" : "→";
        _status.Text = _m.AiBusy ? _m.AiStatus : _m.AiError ?? _m.AiNote ?? "";
        _status.Foreground = _m.AiError is not null && !_m.AiBusy ? Brushes.IndianRed : Brushes.White;
    }

    private void DrawBoard()
    {
        _board.Children.Clear();
        foreach (var canvas in _m.OrderedCanvases)
        {
            var (sx, sy) = _m.ScreenPoint(canvas.X, canvas.Y);
            // A canvas wholly off screen is not built at all.
            if (sx > _m.ViewportWidth || sy > _m.ViewportHeight || sx + canvas.Width * _m.Zoom < 0 || sy + canvas.Height * _m.Zoom < 0) continue;
            var surface = MediaRenderer.Canvas(canvas, [], _m.AssetPath, showComments: true);
            surface.RenderTransform = new ScaleTransform(_m.Zoom, _m.Zoom);
            if (canvas.Section == true) surface.Opacity = 0.9;
            Canvas.SetLeft(surface, sx);
            Canvas.SetTop(surface, sy);
            _board.Children.Add(surface);
            var tag = new TextBlock
            {
                Text = canvas.Name, FontSize = 11, Foreground = canvas.Id == _m.CanvasId ? Brushes.DodgerBlue : Brushes.Gray,
                MaxWidth = Math.Max(canvas.Width * _m.Zoom, 40), TextTrimming = TextTrimming.CharacterEllipsis,
            };
            Canvas.SetLeft(tag, sx);
            Canvas.SetTop(tag, sy - 16);
            _board.Children.Add(tag);
        }
        DrawSelection();
    }

    private void DrawSelection()
    {
        _overlay.Children.Clear();
        if (SelectionRect() is not { } rect) return;
        var frame = new Rectangle { Width = rect.Width, Height = rect.Height, Stroke = Brushes.DodgerBlue, StrokeThickness = 1.5 };
        Canvas.SetLeft(frame, rect.X);
        Canvas.SetTop(frame, rect.Y);
        _overlay.Children.Add(frame);
        foreach (var handle in VisibleHandles())
        {
            var grip = new Rectangle { Width = 8, Height = 8, Fill = Brushes.White, Stroke = Brushes.DodgerBlue, StrokeThickness = 1.5 };
            Canvas.SetLeft(grip, rect.X + rect.Width * handle.X - 4);
            Canvas.SetTop(grip, rect.Y + rect.Height * handle.Y - 4);
            _overlay.Children.Add(grip);
        }
        if (_drag == DragKind.Pencil || _stroke.Count > 0)
        {
            var line = new Polyline { Stroke = Brushes.DodgerBlue, StrokeThickness = 2 };
            foreach (var point in _stroke) { var (x, y) = _m.ScreenPoint(point.X, point.Y); line.Points.Add(new Point(x, y)); }
            _overlay.Children.Add(line);
        }
    }

    /// <summary>A canvas grows from its top-left corner, so only its far edges have grips.</summary>
    private IEnumerable<(double X, double Y)> VisibleHandles() =>
        _m.Layer is not null ? Handles : Handles.Where(h => h.X == 1 || h.Y == 1);

    private Rect? SelectionRect()
    {
        if (_m.Canvas is not { } canvas) return null;
        var (x, y, w, h) = _m.Layer is { } layer
            ? (canvas.X + layer.X, canvas.Y + layer.Y, layer.Width, layer.Height)
            : (canvas.X, canvas.Y, canvas.Width, canvas.Height);
        var (sx, sy) = _m.ScreenPoint(x, y);
        return new Rect(sx, sy, w * _m.Zoom, h * _m.Zoom);
    }

    private void DrawLayers()
    {
        _layers.Children.Clear();
        _layers.Children.Add(Ui.Text(_app.L("studio.layers"), 12, bold: true));
        foreach (var canvas in _m.OrderedCanvases)
        {
            var depth = 0;
            for (var parent = canvas.ParentID; parent is not null; parent = _m.FindCanvas(parent)?.ParentID) depth++;
            _layers.Children.Add(LayerRow((canvas.Section == true ? "⬚ " : "# ") + canvas.Name, depth * 12, canvas.Id == _m.CanvasId && _m.LayerId is null,
                () => _m.Select(canvas.Id), null, null));
            // Front layer first, as a layers panel reads.
            foreach (var layer in Enumerable.Reverse(canvas.Layers))
            {
                _layers.Children.Add(LayerRow(Glyph(layer) + " " + layer.Name, depth * 12 + 16, layer.Id == _m.LayerId,
                    () => _m.Select(canvas.Id, layer.Id),
                    () => _m.ToggleHidden(layer.Id, canvas.Id), () => _m.ToggleLocked(layer.Id, canvas.Id), layer));
            }
        }
    }

    private static string Glyph(MediaLayer layer) => layer.Kind switch
    {
        "text" => "T", "image" => "🖼", "video" => "▶", "icon" => "★", "path" => "╱", _ => layer.Shape == "ellipse" ? "○" : "□",
    };

    private FrameworkElement LayerRow(string title, double indent, bool selected, Action select, Action? hide, Action? lockToggle, MediaLayer? layer = null)
    {
        var row = new DockPanel { Margin = new Thickness(indent, 0, 0, 0) };
        if (hide is not null && lockToggle is not null && layer is not null)
        {
            var buttons = Ui.Row(MiniButton(layer.Hidden ? "◌" : "◉", hide), MiniButton(layer.Locked ? "🔒" : "🔓", lockToggle));
            buttons.Margin = new Thickness(0);
            DockPanel.SetDock(buttons, Dock.Right);
            row.Children.Add(buttons);
        }
        var text = Ui.Text(title, 12, bold: selected);
        if (layer?.Hidden == true) text.Opacity = 0.5;
        row.Children.Add(text);
        var border = new Border
        {
            Child = row, Padding = new Thickness(6, 3, 4, 3), CornerRadius = new CornerRadius(5), Cursor = Cursors.Hand,
            Background = selected ? new SolidColorBrush(Color.FromArgb(0x40, 0x3B, 0x82, 0xF6)) : Brushes.Transparent,
        };
        border.MouseLeftButtonUp += (_, e) => { if (e.OriginalSource is not TextBlock { Parent: Button }) select(); };
        return border;
    }

    private static Button MiniButton(string text, Action click)
    {
        var button = new Button { Content = text, FontSize = 10, Padding = new Thickness(2, 0, 2, 0), Margin = new Thickness(2, 0, 0, 0), BorderThickness = new Thickness(0), Background = Brushes.Transparent };
        button.Click += (_, e) => { click(); e.Handled = true; };
        return button;
    }

    private void DrawDock()
    {
        _dock.Children.Clear();
        Button DockButton(string text, string tip, bool active, Action click, bool enabled = true)
        {
            var button = new Button
            {
                Content = text, ToolTip = tip, Width = 34, Height = 32, Margin = new Thickness(1, 0, 1, 0), FontSize = 15,
                Foreground = Brushes.White, BorderThickness = new Thickness(0), IsEnabled = enabled,
                Background = active ? new SolidColorBrush(Color.FromRgb(0x0D, 0x99, 0xFF)) : Brushes.Transparent,
            };
            button.Click += (_, _) => click();
            return button;
        }
        foreach (var group in ToolGroups)
        {
            var current = _groupTool.TryGetValue(group[0], out var last) ? last : group[0];
            if (group.Contains(_m.Tool)) current = _m.Tool;
            var tool = current;
            var key = MediaTools.Key(tool);
            var button = DockButton(MediaTools.Glyph(tool), MediaTools.Title(tool) + (key is { } k ? $"  ({(char.IsUpper(k) ? "⇧" : "")}{char.ToUpperInvariant(k)})" : ""), _m.Tool == tool, () => Pick(tool));
            _dock.Children.Add(button);
            if (group.Length > 1)
            {
                var more = DockButton("˄", MediaTools.Title(group[0]), false, () => { });
                more.Width = 14;
                more.FontSize = 9;
                var menu = new ContextMenu { PlacementTarget = more, Placement = PlacementMode.Top };
                foreach (var option in group)
                {
                    var item = new MenuItem { Header = MediaTools.Glyph(option) + "  " + MediaTools.Title(option), IsChecked = option == _m.Tool };
                    item.Click += (_, _) => Pick(option);
                    menu.Items.Add(item);
                }
                more.Click += (_, _) => menu.IsOpen = true;
                _dock.Children.Add(more);
            }
        }
        _dock.Children.Add(new Border { Width = 1, Background = Brushes.DimGray, Margin = new Thickness(6, 4, 6, 4) });
        _dock.Children.Add(DockButton("★", _app.L("studio.layer.icon"), false, _m.AddIcon));
        _dock.Children.Add(DockButton("🖼", _app.L("studio.layer.upload"), false, ImportFiles));
        _dock.Children.Add(DockButton("↶", _app.L("studio.undo"), false, _m.Undo, _m.CanUndo));
        _dock.Children.Add(DockButton("↷", _app.L("studio.redo"), false, _m.Redo, _m.CanRedo));
    }

    private void Pick(string tool)
    {
        FinishPen();
        _m.Tool = tool;
        foreach (var group in ToolGroups.Where(g => g.Contains(tool))) _groupTool[group[0]] = tool;
        _viewport.Cursor = tool == "hand" ? Cursors.Hand : tool == "move" ? Cursors.Arrow : Cursors.Cross;
        Refresh();
        _viewport.Focus();
    }

    // Inspector

    private void DrawInspector()
    {
        _inspector.Children.Clear();
        if (_m.Canvas is not { } canvas)
        {
            Frames();
            return;
        }
        if (_m.Layer is { } layer) LayerInspector(canvas, layer);
        else CanvasInspector(canvas);
    }

    private void Heading(string text)
    {
        var block = Ui.Text(text, 11, bold: true);
        block.Margin = new Thickness(0, 10, 0, 4);
        _inspector.Children.Add(block);
    }

    /// <summary>Numeric field; changes land on Enter or when focus leaves, as one undo step.</summary>
    private UIElement Number(string label, double value, Action<double> set)
    {
        var box = new TextBox { Text = Math.Round(value, 1).ToString(System.Globalization.CultureInfo.InvariantCulture), Width = 64, Padding = new Thickness(4, 2, 4, 2) };
        void Apply()
        {
            if (!double.TryParse(box.Text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var number) || number == Math.Round(value, 1)) return;
            _m.Checkpoint();
            set(number);
            _m.Commit();
        }
        box.LostFocus += (_, _) => Apply();
        box.KeyDown += (_, e) => { if (e.Key == Key.Enter) Apply(); };
        var row = new DockPanel { Margin = new Thickness(0, 0, 8, 4), Width = 104 };
        var text = Ui.Text(label, 11, secondary: true);
        text.Width = 36;
        DockPanel.SetDock(text, Dock.Left);
        row.Children.Add(text);
        row.Children.Add(box);
        return row;
    }

    private UIElement Grid2(params UIElement[] items)
    {
        var wrap = new WrapPanel();
        foreach (var item in items) wrap.Children.Add(item);
        return wrap;
    }

    private UIElement TextField(string value, Action<string> set, bool multiline = false)
    {
        var box = Ui.Field(value, multiline: multiline);
        box.LostFocus += (_, _) =>
        {
            if (box.Text == value) return;
            _m.Checkpoint();
            set(box.Text);
            _m.Commit();
        };
        return box;
    }

    /// <summary>A hex field with a swatch; an empty value clears optional colours.</summary>
    private UIElement ColorField(string label, string? value, Action<string?> set, bool optional = false)
    {
        var swatch = new Border { Width = 18, Height = 18, CornerRadius = new CornerRadius(4), Margin = new Thickness(0, 0, 6, 0), BorderBrush = Brushes.Gray, BorderThickness = new Thickness(1), Background = value is null ? Brushes.Transparent : new SolidColorBrush(Ui.Hex(value)) };
        var box = new TextBox { Text = value ?? "", Width = 80, Padding = new Thickness(4, 2, 4, 2) };
        void Apply()
        {
            var text = box.Text.Trim();
            if (text.Length > 0 && !text.StartsWith('#')) text = "#" + text;
            var valid = System.Text.RegularExpressions.Regex.IsMatch(text, "^#[0-9A-Fa-f]{6}$");
            if (text == (value ?? "") || (!valid && !(optional && text.Length == 0))) return;
            _m.Checkpoint();
            set(text.Length == 0 ? null : text.ToUpperInvariant());
            _m.Commit();
        }
        box.LostFocus += (_, _) => Apply();
        box.KeyDown += (_, e) => { if (e.Key == Key.Enter) Apply(); };
        var row = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
        var text = Ui.Text(label, 11, secondary: true);
        text.Width = 80;
        DockPanel.SetDock(text, Dock.Left);
        row.Children.Add(text);
        row.Children.Add(swatch);
        row.Children.Add(box);
        return row;
    }

    private UIElement Choice(string label, string value, IEnumerable<(string Value, string Title)> options, Action<string> set)
    {
        var box = new ComboBox { Width = 120 };
        foreach (var (option, title) in options) box.Items.Add(new ComboBoxItem { Content = title, Tag = option });
        box.SelectedItem = box.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == value);
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedItem is not ComboBoxItem { Tag: string chosen } || chosen == value) return;
            _m.Checkpoint();
            set(chosen);
            _m.Commit();
        };
        var row = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
        var text = Ui.Text(label, 11, secondary: true);
        text.Width = 80;
        DockPanel.SetDock(text, Dock.Left);
        row.Children.Add(text);
        row.Children.Add(box);
        return row;
    }

    private void CanvasInspector(MediaCanvas canvas)
    {
        Heading(_app.L(canvas.Section == true ? "studio.tool.section" : "studio.position"));
        _inspector.Children.Add(TextField(canvas.Name, v => canvas.Name = v));
        _inspector.Children.Add(Grid2(
            Number("X", canvas.X, v => canvas.X = v), Number("Y", canvas.Y, v => canvas.Y = v),
            Number("W", canvas.Width, v => _m.UpdateCanvas(canvas.Id, c => c.Width = v)),
            Number("H", canvas.Height, v => _m.UpdateCanvas(canvas.Id, c => c.Height = v))));
        _inspector.Children.Add(ColorField(_app.L("studio.background"), canvas.BackgroundHex, v => canvas.BackgroundHex = v ?? "#FFFFFF"));
        _inspector.Children.Add(Ui.Row(
            Ui.Button(_app.L("studio.duplicate"), _m.DuplicateSelectedCanvas),
            Ui.Button(_app.L("studio.deleteCanvas"), _m.DeleteSelectedCanvas)));
        Heading(_app.L("studio.export"));
        _inspector.Children.Add(Ui.Row(
            Ui.Button("PNG", () => ExportCanvas(canvas, "png")), Ui.Button("JPEG", () => ExportCanvas(canvas, "jpeg"))));
        Frames(canvas);
    }

    /// <summary>Ready-made sizes: a new canvas on an empty board, a resize of the selected one otherwise.</summary>
    private void Frames(MediaCanvas? selected = null)
    {
        Heading(_app.L("studio.addCanvas"));
        foreach (var group in MediaFrameGroup.All)
        {
            var expander = new Expander { Header = group.Title, Margin = new Thickness(0, 0, 0, 2), IsExpanded = selected is null && group.Id == "desktop" };
            var list = new StackPanel();
            foreach (var preset in group.Presets)
            {
                var row = new DockPanel();
                var size = Ui.Text($"{preset.Width:0}×{preset.Height:0}", 11, secondary: true);
                DockPanel.SetDock(size, Dock.Right);
                row.Children.Add(size);
                row.Children.Add(Ui.Text(preset.Name, 12));
                var button = new Button { Content = row, HorizontalContentAlignment = HorizontalAlignment.Stretch, BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(4, 2, 4, 2) };
                button.Click += (_, _) =>
                {
                    if (selected is null) _m.AddCanvas(new MediaCanvas { Name = preset.Name, Width = preset.Width, Height = preset.Height });
                    else
                    {
                        _m.Checkpoint();
                        _m.UpdateCanvas(selected.Id, c => { c.Width = preset.Width; c.Height = preset.Height; });
                        _m.Commit();
                    }
                };
                list.Children.Add(button);
            }
            expander.Content = list;
            _inspector.Children.Add(expander);
        }
        Heading(_app.L("studio.templates"));
        foreach (var template in _templates)
            _inspector.Children.Add(Ui.Button(template.Title, () => _m.AddCanvas(template.Canvas())));
    }

    private void LayerInspector(MediaCanvas canvas, MediaLayer layer)
    {
        Heading(_app.L("studio.name"));
        _inspector.Children.Add(TextField(layer.Name, v => layer.Name = v));
        _inspector.Children.Add(Grid2(
            Number("X", layer.X, v => layer.X = v), Number("Y", layer.Y, v => layer.Y = v),
            Number("W", layer.Width, v => layer.Width = Math.Max(1, v)), Number("H", layer.Height, v => layer.Height = Math.Max(1, v)),
            Number("↻", layer.Rotation, v => layer.Rotation = v), Number("α %", layer.Opacity * 100, v => layer.Opacity = Math.Clamp(v / 100, 0.05, 1))));
        _inspector.Children.Add(Ui.Row(
            Ui.Button("⇤", () => _m.AlignSelectedLayer(horizontal: 0)), Ui.Button("↔", () => _m.AlignSelectedLayer(horizontal: 0.5)),
            Ui.Button("⇥", () => _m.AlignSelectedLayer(horizontal: 1)), Ui.Button("⤒", () => _m.AlignSelectedLayer(vertical: 0)),
            Ui.Button("↕", () => _m.AlignSelectedLayer(vertical: 0.5)), Ui.Button("⤓", () => _m.AlignSelectedLayer(vertical: 1))));

        if (layer.Kind == "text")
        {
            Heading(_app.L("studio.layer.text"));
            _inspector.Children.Add(TextField(layer.Text, v => layer.Text = v, multiline: true));
            _inspector.Children.Add(Grid2(Number("pt", layer.FontSize, v => layer.FontSize = Math.Clamp(v, 1, 600)), Number("◠°", layer.Arc, v => layer.Arc = Math.Clamp(v, -360, 360))));
            _inspector.Children.Add(Choice("Aa", layer.FontDesign, new[] { "default", "rounded", "serif", "mono" }.Select(f => (f, _app.L($"studio.font.{f}"))), v => layer.FontDesign = v));
            _inspector.Children.Add(Choice("B", layer.FontWeight, new[] { "regular", "medium", "bold" }.Select(w => (w, _app.L($"studio.weight.{w}"))), v => layer.FontWeight = v));
            _inspector.Children.Add(Choice("≡", layer.Alignment, new[] { ("leading", "⇤"), ("center", "↔"), ("trailing", "⇥") }, v => layer.Alignment = v));
        }
        if (layer.Kind == "shape")
            _inspector.Children.Add(Choice(_app.L("studio.layer.shape"), layer.Shape, new[] { "rectangle", "ellipse", "polygon", "star" }.Select(s => (s, _app.L($"studio.shape.{s}"))), v => layer.Shape = v));
        if (layer.Kind == "icon")
            _inspector.Children.Add(Choice(_app.L("studio.symbol"), layer.Symbol, MediaIcons.Glyphs.Select(p => (p.Key, p.Value + "  " + p.Key)), v => layer.Symbol = v));

        Heading(_app.L("studio.fill"));
        _inspector.Children.Add(ColorField(_app.L("studio.fill"), layer.ColorHex, v => layer.ColorHex = v ?? "#111111"));
        _inspector.Children.Add(ColorField(_app.L("studio.gradient"), layer.GradientHex, v => layer.GradientHex = v, optional: true));
        _inspector.Children.Add(ColorField(_app.L("studio.stroke"), layer.StrokeHex, v => layer.StrokeHex = v, optional: true));
        _inspector.Children.Add(Grid2(
            Number("—", layer.StrokeWidth, v => layer.StrokeWidth = Math.Clamp(v, 0, 200)),
            Number("◐", layer.Shadow, v => layer.Shadow = Math.Clamp(v, 0, 200)),
            Number("◜", layer.CornerRadius, v => layer.CornerRadius = Math.Clamp(v, 0, Math.Min(layer.Width, layer.Height) / 2))));

        if (layer.Kind == "image")
        {
            Heading(_app.L("studio.crop"));
            void Crop(double? ratio)
            {
                _m.Checkpoint();
                if (ratio is null) { layer.CropX = layer.CropY = layer.CropWidth = layer.CropHeight = null; }
                else
                {
                    var size = layer.AssetName is { } name ? MediaRenderer.NaturalSize(_m.AssetPath(name)) : null;
                    var sourceRatio = size is { } dimensions ? dimensions.Item1 / Math.Max(dimensions.Item2, 1) : ratio.Value;
                    var normalized = ratio.Value / Math.Max(sourceRatio, 0.001);
                    var width = normalized >= 1 ? 1 : normalized;
                    var height = normalized >= 1 ? 1 / normalized : 1;
                    layer.CropX = (1 - width) / 2; layer.CropY = (1 - height) / 2;
                    layer.CropWidth = width; layer.CropHeight = height;
                }
                _m.Commit();
            }
            _inspector.Children.Add(Ui.Row(
                Ui.Button(_app.L("studio.crop.free"), () => Crop(null)),
                Ui.Button("1:1", () => Crop(1)),
                Ui.Button("16:9", () => Crop(16.0 / 9.0)),
                Ui.Button("9:16", () => Crop(9.0 / 16.0))));
            _inspector.Children.Add(Grid2(
                Number("X %", (layer.CropX ?? 0) * 100, value => { _m.Checkpoint(); layer.CropX = Math.Clamp(value / 100, 0, 0.95); layer.CropWidth = Math.Min(layer.CropWidth ?? 1, 1 - layer.CropX.Value); _m.Commit(); }),
                Number("Y %", (layer.CropY ?? 0) * 100, value => { _m.Checkpoint(); layer.CropY = Math.Clamp(value / 100, 0, 0.95); layer.CropHeight = Math.Min(layer.CropHeight ?? 1, 1 - layer.CropY.Value); _m.Commit(); }),
                Number("W %", (layer.CropWidth ?? 1) * 100, value => { _m.Checkpoint(); layer.CropWidth = Math.Clamp(value / 100, 0.05, 1 - (layer.CropX ?? 0)); _m.Commit(); }),
                Number("H %", (layer.CropHeight ?? 1) * 100, value => { _m.Checkpoint(); layer.CropHeight = Math.Clamp(value / 100, 0.05, 1 - (layer.CropY ?? 0)); _m.Commit(); })));
            Heading(_app.L("studio.imagePrompt"));
            _inspector.Children.Add(TextField(layer.Prompt ?? "", v => layer.Prompt = v, multiline: true));
            var generate = Ui.Button(_app.L("studio.generateImage"),
                () => _m.GenerateImage(layer, canvas.Id, _app.Router, _app.Paths, _app.Secrets), primary: true);
            generate.IsEnabled = !_m.AiBusy && !string.IsNullOrWhiteSpace(layer.Prompt);
            _inspector.Children.Add(generate);
        }
        if (layer.Kind == "video" && layer.AssetName is { } videoAsset)
            VideoTrimInspector(canvas, layer, videoAsset);
        if (layer.AssetName is { } asset)
            _inspector.Children.Add(Ui.Button(_app.L("media.showInFinder"), () => Ui.Reveal(_m.AssetPath(asset))));

        Heading("");
        _inspector.Children.Add(Ui.Row(
            Ui.Button(_app.L("studio.layer.front"), () => _m.ReorderSelectedLayer(true)),
            Ui.Button(_app.L("studio.layer.back"), () => _m.ReorderSelectedLayer(false))));
        _inspector.Children.Add(Ui.Row(
            Ui.Button(_app.L("studio.duplicate"), _m.DuplicateSelectedLayer),
            Ui.Button(_app.L("common.delete"), _m.DeleteSelectedLayer)));
        _inspector.Children.Add(Ui.Row(Ui.Button("PNG", () => ExportLayer(layer))));
    }

    private void VideoTrimInspector(MediaCanvas canvas, MediaLayer layer, string assetName)
    {
        Heading(_app.L("studio.ai.kind.video"));
        var source = _m.AssetPath(assetName);
        var preview = new MediaElement
        {
            Source = new Uri(source), Height = 170, LoadedBehavior = MediaState.Manual,
            UnloadedBehavior = MediaState.Stop, Stretch = Stretch.Uniform,
        };
        var seek = new Slider { Minimum = 0, Maximum = 1, IsEnabled = false };
        var inPoint = new TextBox { Text = "0", Width = 72, Padding = new Thickness(4, 2, 4, 2) };
        var outPoint = new TextBox { Text = "", Width = 72, Padding = new Thickness(4, 2, 4, 2) };
        var status = Ui.Text(_app.L("studio.video.loading"), 11, secondary: true, wrap: true);
        var progress = new ProgressBar { Height = 5, Minimum = 0, Maximum = 1, Visibility = Visibility.Collapsed };
        CancellationTokenSource? cancellation = null;
        var cancel = Ui.Button(_app.L("common.cancel"), () => cancellation?.Cancel());
        cancel.IsEnabled = false;
        preview.MediaOpened += (_, _) =>
        {
            var seconds = preview.NaturalDuration.HasTimeSpan ? preview.NaturalDuration.TimeSpan.TotalSeconds : 0;
            if (seconds <= 0) { status.Text = _app.L("studio.video.playerUnavailable"); return; }
            seek.Maximum = seconds; seek.IsEnabled = true;
            outPoint.Text = seconds.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
            status.Text = _app.L("studio.video.ready");
        };
        preview.MediaFailed += (_, e) => status.Text = e.ErrorException?.Message ?? _app.L("studio.video.playerUnavailable");
        seek.ValueChanged += (_, _) => { if (preview.NaturalDuration.HasTimeSpan) preview.Position = TimeSpan.FromSeconds(seek.Value); };
        _inspector.Children.Add(preview);
        _inspector.Children.Add(seek);
        _inspector.Children.Add(Ui.Row(
            Ui.Button(_app.L("studio.video.play"), () => preview.Play()),
            Ui.Button(_app.L("studio.video.pause"), () => preview.Pause()),
            Ui.Button("−1f", () => preview.Position = TimeSpan.FromSeconds(Math.Max(0, preview.Position.TotalSeconds - 1.0 / 30))),
            Ui.Button("+1f", () => preview.Position = TimeSpan.FromSeconds(preview.Position.TotalSeconds + 1.0 / 30))));
        _inspector.Children.Add(Ui.Row(
            Ui.Button(_app.L("studio.video.markIn"), () => inPoint.Text = preview.Position.TotalSeconds.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture)),
            inPoint,
            Ui.Button(_app.L("studio.video.markOut"), () => outPoint.Text = preview.Position.TotalSeconds.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture)),
            outPoint));
        _inspector.Children.Add(Ui.Row(
            Ui.Button(_app.L("studio.video.trimExport"), async () =>
            {
                if (!double.TryParse(inPoint.Text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var start)
                    || !double.TryParse(outPoint.Text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var end)
                    || end <= start)
                { status.Text = _app.L("studio.video.trimRangeInvalid"); return; }
                cancellation?.Dispose();
                cancellation = new CancellationTokenSource();
                var token = cancellation.Token;
                var temp = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"herness-trim-{Guid.NewGuid():N}.mp4");
                progress.Visibility = Visibility.Visible; progress.Value = 0; cancel.IsEnabled = true;
                status.Text = _app.L("studio.video.exporting");
                try
                {
                    var reporter = new Progress<double>(value => progress.Value = value);
                    await MediaVideoTools.TrimMp4Async(source, temp, start, end, reporter, token);
                    token.ThrowIfCancellationRequested();
                    var newAsset = _m.Store.ImportAsset(temp, _m.Project.Id);
                    _m.Checkpoint();
                    _m.UpdateLayer(layer.Id, canvas.Id, current => current.AssetName = newAsset);
                    _m.Commit();
                    preview.Source = new Uri(_m.AssetPath(newAsset));
                    preview.Play();
                    seek.Value = 0;
                    status.Text = _app.L("studio.video.trimAdded");
                }
                catch (OperationCanceledException) { status.Text = _app.L("studio.video.trimCancelled"); }
                catch (Exception error) { status.Text = error.Message; }
                finally
                {
                    cancellation?.Dispose(); cancellation = null; cancel.IsEnabled = false;
                    progress.Visibility = Visibility.Collapsed;
                    try { if (System.IO.File.Exists(temp)) System.IO.File.Delete(temp); } catch (IOException) { }
                }
            }, primary: true),
            cancel));
        _inspector.Children.Add(progress);
        _inspector.Children.Add(status);
    }

    // Pointer

    private MediaLayer? LayerAt(BoardPoint point, out MediaCanvas? owner)
    {
        foreach (var canvas in Enumerable.Reverse(_m.OrderedCanvases))
        {
            if (!BoardRect.Of(canvas).Contains(point)) continue;
            // A locked layer lets clicks through to whatever is under it.
            var layer = Enumerable.Reverse(canvas.Layers).FirstOrDefault(l => !l.Hidden && !l.Locked
                && new BoardRect(canvas.X + l.X, canvas.Y + l.Y, l.Width, l.Height).Contains(point));
            if (layer is not null) { owner = canvas; return layer; }
        }
        owner = null;
        return null;
    }

    private (double X, double Y)? HandleAt(Point screen)
    {
        if (SelectionRect() is not { } rect) return null;
        foreach (var handle in VisibleHandles())
            if (Math.Abs(screen.X - (rect.X + rect.Width * handle.X)) <= 7 && Math.Abs(screen.Y - (rect.Y + rect.Height * handle.Y)) <= 7)
                return handle;
        return null;
    }

    private MediaCanvas? CanvasTagAt(Point screen) => Enumerable.Reverse(_m.OrderedCanvases).FirstOrDefault(c =>
    {
        var (x, y) = _m.ScreenPoint(c.X, c.Y);
        return screen.X >= x && screen.X <= x + Math.Max(c.Width * _m.Zoom, 40) && screen.Y >= y - 18 && screen.Y <= y;
    });

    private void OnDown(object sender, MouseButtonEventArgs e)
    {
        _viewport.Focus();
        if (e.ChangedButton == MouseButton.Right) return;
        var screen = e.GetPosition(_viewport);
        var point = _m.BoardPointAt(screen.X, screen.Y);
        _dragStart = screen;
        _viewport.CaptureMouse();
        if (e.ChangedButton == MouseButton.Middle || _spaceDown || _m.Tool == "hand") { _drag = DragKind.Pan; return; }
        switch (_m.Tool)
        {
            case "move":
                if (HandleAt(screen) is { } handle)
                {
                    _m.Checkpoint();
                    _handle = handle;
                    _startLayer = _m.Layer?.Clone();
                    _startCanvas = _m.Canvas?.Clone();
                    _drag = DragKind.Resize;
                }
                else if (CanvasTagAt(screen) is { } tagged)
                {
                    BeginCanvasDrag(tagged);
                }
                else if (LayerAt(point, out var owner) is { } layer && owner is not null)
                {
                    _m.Checkpoint();
                    _m.Select(owner.Id, layer.Id);
                    _startLayer = layer.Clone();
                    _dragCanvasId = owner.Id;
                    _drag = DragKind.MoveLayer;
                }
                else if (_m.Hit(point) is { } canvas)
                {
                    // Pressing a canvas's empty area selects it; a drag moves it.
                    BeginCanvasDrag(canvas);
                }
                else
                {
                    _m.LayerId = null;
                    _drag = DragKind.Pan;
                    _m.Notify();
                }
                break;
            case "scale":
                _m.Checkpoint();
                _startLayer = _m.Layer?.Clone();
                _startCanvas = _m.Canvas?.Clone();
                _drag = DragKind.Scale;
                break;
            case "pencil":
            case "marker":
                _stroke.Clear();
                _stroke.Add(point);
                _drag = DragKind.Pencil;
                break;
            case "pen":
                // A pen path ends on Enter, Escape, a double click or a change of tool.
                if (e.ClickCount == 2) { FinishPen(); return; }
                _stroke.Add(point);
                DrawSelection();
                break;
            default:
                _drag = DragKind.Draw;
                break;
        }
    }

    private void BeginCanvasDrag(MediaCanvas canvas)
    {
        _m.Checkpoint();
        _m.Select(canvas.Id);
        _startCanvas = canvas.Clone();
        _startChildren = _m.Descendants(canvas.Id).Select(c => c.Clone()).ToList();
        _drag = DragKind.MoveCanvas;
    }

    private void OnMove(object sender, MouseEventArgs e)
    {
        if (_drag == DragKind.None) return;
        var screen = e.GetPosition(_viewport);
        var dx = (screen.X - _dragStart.X) / _m.Zoom;
        var dy = (screen.Y - _dragStart.Y) / _m.Zoom;
        switch (_drag)
        {
            case DragKind.Pan:
                _m.PanX += screen.X - _dragStart.X;
                _m.PanY += screen.Y - _dragStart.Y;
                _dragStart = screen;
                break;
            case DragKind.MoveLayer when _startLayer is not null && _dragCanvasId is not null:
                _m.UpdateLayer(_startLayer.Id, _dragCanvasId, l => { l.X = Math.Round(_startLayer.X + dx); l.Y = Math.Round(_startLayer.Y + dy); });
                break;
            case DragKind.MoveCanvas when _startCanvas is not null:
                _m.UpdateCanvas(_startCanvas.Id, c => { c.X = Math.Round(_startCanvas.X + dx); c.Y = Math.Round(_startCanvas.Y + dy); });
                // Canvases nested in it travel along.
                foreach (var child in _startChildren)
                    _m.UpdateCanvas(child.Id, c => { c.X = Math.Round(child.X + dx); c.Y = Math.Round(child.Y + dy); });
                break;
            case DragKind.Resize:
                Resize(dx, dy);
                break;
            case DragKind.Scale:
                // Dragging right grows the selection, left shrinks it.
                var factor = Math.Max(0.05, 1 + (screen.X - _dragStart.X) / 200);
                if (_startLayer is not null && _m.CanvasId is { } id) _m.Scale(_startLayer, id, factor);
                else if (_startCanvas is not null) _m.Scale(_startCanvas, factor);
                break;
            case DragKind.Pencil:
                var point = _m.BoardPointAt(screen.X, screen.Y);
                var last = _stroke[^1];
                // Skip points closer than two screen points.
                if (Math.Abs(point.X - last.X) * _m.Zoom + Math.Abs(point.Y - last.Y) * _m.Zoom >= 2) _stroke.Add(point);
                DrawSelection();
                return;
            case DragKind.Draw:
                DrawSelection();
                var start = _m.BoardPointAt(_dragStart.X, _dragStart.Y);
                var end = _m.BoardPointAt(screen.X, screen.Y);
                var (sx, sy) = _m.ScreenPoint(Math.Min(start.X, end.X), Math.Min(start.Y, end.Y));
                var ghost = new Rectangle { Width = Math.Abs(screen.X - _dragStart.X), Height = Math.Abs(screen.Y - _dragStart.Y), Stroke = Brushes.DodgerBlue, StrokeDashArray = [4, 3] };
                Canvas.SetLeft(ghost, sx);
                Canvas.SetTop(ghost, sy);
                _overlay.Children.Add(ghost);
                return;
        }
        DrawBoard();
    }

    private void Resize(double dx, double dy)
    {
        var (fx, fy) = _handle;
        void Apply(ref double x, ref double y, ref double w, ref double h, bool farOnly)
        {
            if (fx == 0 && !farOnly) { x += dx; w -= dx; }
            if (fx == 1) w += dx;
            if (fy == 0 && !farOnly) { y += dy; h -= dy; }
            if (fy == 1) h += dy;
            w = Math.Max(1, Math.Round(w));
            h = Math.Max(1, Math.Round(h));
            x = Math.Round(x);
            y = Math.Round(y);
        }
        if (_startLayer is { } layer && _m.CanvasId is { } canvasId)
        {
            double x = layer.X, y = layer.Y, w = layer.Width, h = layer.Height;
            Apply(ref x, ref y, ref w, ref h, false);
            _m.UpdateLayer(layer.Id, canvasId, l => { l.X = x; l.Y = y; l.Width = w; l.Height = h; });
        }
        else if (_startCanvas is { } canvas)
        {
            double x = canvas.X, y = canvas.Y, w = canvas.Width, h = canvas.Height;
            Apply(ref x, ref y, ref w, ref h, true);
            _m.UpdateCanvas(canvas.Id, c => { c.Width = w; c.Height = h; });
        }
    }

    private void OnUp(object sender, MouseButtonEventArgs e)
    {
        _viewport.ReleaseMouseCapture();
        var screen = e.GetPosition(_viewport);
        var drag = _drag;
        _drag = DragKind.None;
        switch (drag)
        {
            case DragKind.MoveLayer when _startLayer is not null && _dragCanvasId is not null:
                // Where it was let go decides where it now belongs.
                _m.RehomeLayer(_startLayer.Id, _dragCanvasId);
                _m.Commit();
                break;
            case DragKind.MoveCanvas when _startCanvas is not null:
                _m.ReparentCanvas(_startCanvas.Id);
                _m.Commit();
                break;
            case DragKind.Resize or DragKind.Scale:
                _m.Commit();
                break;
            case DragKind.Pencil:
                if (_m.Tool == "marker") _m.AddPath(_stroke.ToList(), MediaTools.Title("marker"), colorHex: "#FFD400", strokeWidth: 24, opacity: 0.42);
                else _m.AddPath(_stroke.ToList(), MediaTools.Title("pencil"));
                _stroke.Clear();
                _m.Tool = "move";
                Refresh();
                break;
            case DragKind.Draw:
                var tool = _m.Tool;
                if (_m.Place(tool, _m.BoardPointAt(_dragStart.X, _dragStart.Y), _m.BoardPointAt(screen.X, screen.Y)) is { } slice)
                    SaveExport(MediaRenderer.Export(slice.Canvas, [], _m.AssetPath, "png", 1, slice.Region), $"{slice.Canvas.Name} {MediaTools.Title("slice")}", "png");
                break;
            case DragKind.Pan:
                Refresh();
                break;
        }
        _startLayer = null;
        _startCanvas = null;
        _dragCanvasId = null;
    }

    private void FinishPen()
    {
        if (_stroke.Count >= 2) _m.AddPath(_stroke.ToList(), MediaTools.Title("pen"));
        _stroke.Clear();
        if (_m.Tool == "pen") _m.Tool = "move";
        _m.Notify();
    }

    /// <summary>Scroll pans; Ctrl-scroll zooms around the pointer, like other canvas editors.</summary>
    private void OnWheel(object sender, MouseWheelEventArgs e)
    {
        var screen = e.GetPosition(_viewport);
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) _m.ZoomBy(Math.Exp(e.Delta * 0.002), screen.X, screen.Y);
        else
        {
            if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) _m.PanX += e.Delta * 0.6;
            else _m.PanY += e.Delta * 0.6;
            DrawBoard();
        }
        e.Handled = true;
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        if (e.OriginalSource is TextBox) return;
        var ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        var shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        var step = shift ? 10 : 1;
        switch (e.Key)
        {
            case Key.Space: _spaceDown = true; break;
            case Key.Delete or Key.Back: _m.DeleteSelection(); break;
            case Key.Escape: if (_stroke.Count > 0) FinishPen(); else { _m.LayerId = null; Pick("move"); } break;
            case Key.Enter when _stroke.Count > 0: FinishPen(); break;
            case Key.Z when ctrl && shift: _m.Redo(); break;
            case Key.Z when ctrl: _m.Undo(); break;
            case Key.Y when ctrl: _m.Redo(); break;
            case Key.C when ctrl: if (_m.CopySelection() is { } copy) Clipboard.SetText(copy); break;
            case Key.X when ctrl: if (_m.CutSelection() is { } cut) Clipboard.SetText(cut); break;
            case Key.V when ctrl: Paste(null); break;
            case Key.D when ctrl: if (_m.Layer is not null) _m.DuplicateSelectedLayer(); else _m.DuplicateSelectedCanvas(); break;
            case Key.D0 when ctrl: _m.Fit(); break;
            case Key.OemPlus when ctrl: _m.ZoomBy(1.25); break;
            case Key.OemMinus when ctrl: _m.ZoomBy(0.8); break;
            case Key.Left: _m.Nudge(-step, 0); break;
            case Key.Right: _m.Nudge(step, 0); break;
            case Key.Up: _m.Nudge(0, -step); break;
            case Key.Down: _m.Nudge(0, step); break;
            default:
                if (ctrl) return;
                var letter = e.Key is >= Key.A and <= Key.Z ? (char)('a' + (e.Key - Key.A)) : '\0';
                if (shift) letter = char.ToUpperInvariant(letter);
                if (MediaTools.All.FirstOrDefault(t => MediaTools.Key(t) == letter) is { } tool) Pick(tool);
                else return;
                break;
        }
        e.Handled = true;
    }

    /// <summary>Pastes layers copied here, else image files or a picture from the system clipboard.</summary>
    private void Paste(BoardPoint? at)
    {
        if (Clipboard.ContainsText() && _m.Paste(Clipboard.GetText(), at)) return;
        if (Clipboard.ContainsFileDropList()) { _m.AddFiles(Clipboard.GetFileDropList().Cast<string>(), at); return; }
        if (Clipboard.ContainsImage() && Clipboard.GetImage() is { } image)
        {
            var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), Guid.NewGuid() + ".png");
            using (var stream = File.Create(path))
            {
                var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
                encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(image));
                encoder.Save(stream);
            }
            _m.AddMedia(path, 0.5, _app.L("studio.ai.kind.image"), center: at);
            File.Delete(path);
            return;
        }
        _m.Paste(null, at);
    }

    private ContextMenu BoardMenu()
    {
        var menu = new ContextMenu();
        void Add(string header, Action click)
        {
            var item = new MenuItem { Header = header };
            item.Click += (_, _) => click();
            menu.Items.Add(item);
        }
        Point? opened = null;
        menu.Opened += (_, _) => opened = Mouse.GetPosition(_viewport);
        BoardPoint? At() => opened is { } p ? _m.BoardPointAt(p.X, p.Y) : null;
        Add(_app.L("studio.cut"), () => { if (_m.CutSelection() is { } c) Clipboard.SetText(c); });
        Add(_app.L("conversation.copy"), () => { if (_m.CopySelection() is { } c) Clipboard.SetText(c); });
        Add(_app.L("studio.paste"), () => Paste(At()));
        Add(_app.L("studio.duplicate"), () => { if (_m.Layer is not null) _m.DuplicateSelectedLayer(); else _m.DuplicateSelectedCanvas(); });
        menu.Items.Add(new Separator());
        Add(_app.L("studio.layer.front"), () => _m.ReorderSelectedLayer(true));
        Add(_app.L("studio.layer.back"), () => _m.ReorderSelectedLayer(false));
        Add(_app.L("studio.unlockAll"), _m.UnlockAllLayers);
        Add(_app.L("studio.layer.upload"), ImportFiles);
        Add(_app.L("studio.zoomFit"), _m.Fit);
        menu.Items.Add(new Separator());
        Add(_app.L("common.delete"), _m.DeleteSelection);
        return menu;
    }

    private void ImportFiles()
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Multiselect = true, Filter = "Media|*.png;*.jpg;*.jpeg;*.gif;*.webp;*.bmp;*.mp4;*.mov;*.webm|*.*|*.*" };
        if (dialog.ShowDialog() != true) return;
        foreach (var file in dialog.FileNames) _m.AddMedia(file, 0.8);
    }

    // Export

    private void ShowExportMenu()
    {
        var menu = new ContextMenu();
        void Add(string header, Action click, bool enabled = true)
        {
            var item = new MenuItem { Header = header, IsEnabled = enabled };
            item.Click += (_, _) => click();
            menu.Items.Add(item);
        }
        Add((_m.Canvas?.Name ?? "") + " · PNG", () => { if (_m.Canvas is { } c) ExportCanvas(c, "png"); }, _m.Canvas is not null);
        Add((_m.Canvas?.Name ?? "") + " · JPEG", () => { if (_m.Canvas is { } c) ExportCanvas(c, "jpeg"); }, _m.Canvas is not null);
        Add((_m.Layer?.Name ?? _app.L("studio.layers")) + " · PNG", () => { if (_m.Layer is { } l) ExportLayer(l); }, _m.Layer is not null);
        Add(_app.L("studio.exportAll") + " · PNG", ExportAll, _m.Project.Canvases.Count > 0);
        menu.IsOpen = true;
    }

    private void ExportCanvas(MediaCanvas canvas, string format) =>
        SaveExport(MediaRenderer.Export(canvas, _m.Descendants(canvas.Id), _m.AssetPath, format, 2), canvas.Name, format);

    // ponytail: a layer exports at its own frame, so a rotated layer or a wide shadow is cut at the frame edge.
    private void ExportLayer(MediaLayer layer)
    {
        var holder = new MediaCanvas { Width = layer.Width, Height = layer.Height, BackgroundHex = "#000000" };
        var copy = layer.Clone();
        copy.X = 0;
        copy.Y = 0;
        holder.Layers.Add(copy);
        var surface = MediaRenderer.Canvas(holder, [], _m.AssetPath);
        surface.Background = Brushes.Transparent;
        surface.Measure(new Size(layer.Width, layer.Height));
        surface.Arrange(new Rect(0, 0, layer.Width, layer.Height));
        var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap((int)Math.Max(1, layer.Width * 2), (int)Math.Max(1, layer.Height * 2), 192, 192, PixelFormats.Pbgra32);
        bitmap.Render(surface);
        var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
        encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        SaveExport(stream.ToArray(), layer.Name, "png");
    }

    private static void SaveExport(byte[] data, string name, string format)
    {
        var extension = format == "jpeg" ? "jpg" : "png";
        var dialog = new Microsoft.Win32.SaveFileDialog { FileName = $"{MediaRenderer.FileName(name)}.{extension}", Filter = $"{extension.ToUpperInvariant()}|*.{extension}" };
        if (dialog.ShowDialog() == true) File.WriteAllBytes(dialog.FileName, data);
    }

    /// <summary>Writes every canvas into a folder; canvases sharing a name get a number.</summary>
    private void ExportAll()
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog();
        if (dialog.ShowDialog() != true) return;
        var used = new Dictionary<string, int>();
        foreach (var canvas in _m.Project.Canvases.Where(c => c.ParentID is null))
        {
            var name = MediaRenderer.FileName(canvas.Name);
            used[name] = used.GetValueOrDefault(name) + 1;
            var file = System.IO.Path.Combine(dialog.FolderName, (used[name] == 1 ? name : $"{name} {used[name]}") + ".png");
            File.WriteAllBytes(file, MediaRenderer.Export(canvas, _m.Descendants(canvas.Id), _m.AssetPath, "png", 2));
        }
    }
}
