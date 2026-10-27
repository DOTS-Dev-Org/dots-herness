// Copyright (c) 2026 DOTS
// Music editor: the arrangement board (sections over a bar ruler, one lane per track) with
// the inspector for whatever is selected on the right. Mirrors MusicEditorView.swift on macOS.

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

/// <summary>
/// Plays every track's file at once, each at its own level, through ffplay.
/// ponytail: levels apply when playback starts; live mixing needs an audio library.
/// </summary>
internal sealed class MusicMixer
{
    private readonly List<System.Diagnostics.Process> _players = [];
    private readonly System.Diagnostics.Stopwatch _clock = new();
    public bool IsPlaying { get; private set; }
    public double Cue { get; set; }
    public double Time => IsPlaying ? Cue + _clock.Elapsed.TotalSeconds : Cue;

    public void Play(MusicProject project, MusicStudioStore store)
    {
        Halt();
        foreach (var track in project.Tracks)
        {
            if (track.Clips.FirstOrDefault(c => c.SectionID is null) is not { } clip || project.Gain(track) <= 0) continue;
            var path = store.AssetPath(project.Id, clip.AssetName);
            if (!File.Exists(path)) continue;
            var start = new System.Diagnostics.ProcessStartInfo("ffplay") { UseShellExecute = false, RedirectStandardError = true, RedirectStandardOutput = true };
            foreach (var argument in new[] { "-nodisp", "-autoexit", "-loglevel", "quiet", "-ss", Cue.ToString(System.Globalization.CultureInfo.InvariantCulture),
                "-volume", ((int)(project.Gain(track) * 100)).ToString(), path })
                start.ArgumentList.Add(argument);
            try { if (System.Diagnostics.Process.Start(start) is { } process) _players.Add(process); }
            catch (System.ComponentModel.Win32Exception) { throw new InvalidOperationException("Install ffmpeg (ffplay) to play songs."); }
        }
        if (_players.Count == 0) return;
        _clock.Restart();
        IsPlaying = true;
    }

    public void Stop()
    {
        Halt();
        Cue = 0;
    }

    public void Apply(MusicProject project) { }

    private void Halt()
    {
        foreach (var player in _players)
        {
            try { if (!player.HasExited) player.Kill(); } catch (Exception) { }
            player.Dispose();
        }
        _players.Clear();
        _clock.Reset();
        IsPlaying = false;
    }
}

internal sealed class MusicEditorView : UserControl
{
    private const double LaneHeight = 54;
    private readonly AppModel _app;
    private readonly MusicStudioStore _store;
    private readonly MusicProject _project;
    private readonly Action _close;
    private readonly MusicMixer _mixer = new();
    private readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private readonly Grid _board = new() { Background = Ui.Brush("ChromeBackground"), ClipToBounds = true };
    private readonly StackPanel _inspector = new() { Margin = new Thickness(12) };
    private readonly Border _inspectorPane;
    private readonly HashSet<string> _busy = [];
    private readonly TextBlock _time = new() { Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 8, 0) };
    private readonly Avalonia.Controls.Shapes.Rectangle _playhead = new() { Width = 1.5, Fill = Brushes.DodgerBlue, HorizontalAlignment = HorizontalAlignment.Left, IsHitTestVisible = false };
    private string _selection = "song";
    private string? _error;
    private double _header = 168;

    public MusicEditorView(AppModel app, MusicProject project, Action close)
    {
        _app = app;
        _store = app.MusicStudio;
        _project = project.Clone();
        _close = close;
        ProjectId = project.Id;
        var name = new TextBox { Text = _project.Name, MinWidth = 100, MaxWidth = 220, FontWeight = FontWeight.SemiBold, BorderThickness = new Thickness(0), Background = null, Foreground = Ui.Brush("TextPrimary"), VerticalContentAlignment = VerticalAlignment.Center };
        name.LostFocus += (_, _) => { _project.Name = name.Text.Trim(); Save(); };
        var toolbar = new DockPanel { Height = 40, Margin = new Thickness(8, 0, 8, 0) };
        var right = Ui.Row(
            Ui.Button("⚙", () => MediaSettingsPanel.ShowDialog(app, this, Render), app.L("studio.settings.title")),
            Ui.Button("◨", () => _inspectorPane!.IsVisible = _inspectorPane.IsVisible ? false : true, app.L("studio.music.inspector")));
        right.Margin = new Thickness(0);
        right.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(right, Dock.Right);
        toolbar.Children.Add(right);
        var back = Ui.Button("‹ " + app.L("studio.music"), () => { _mixer.Stop(); _close(); });
        back.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(back, Dock.Left);
        toolbar.Children.Add(back);
        toolbar.Children.Add(name);

        _inspectorPane = new Border { Width = 264, Background = Ui.Brush("ChromeBackground"), BorderBrush = Ui.Brush("BorderSubtle"), BorderThickness = new Thickness(1, 0, 0, 0), Child = new ScrollViewer { Content = _inspector, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
        var body = new DockPanel();
        DockPanel.SetDock(_inspectorPane, Dock.Right);
        body.Children.Add(_inspectorPane);
        body.Children.Add(_board);
        var root = new DockPanel { Background = Ui.Brush("WindowBackground") };
        DockPanel.SetDock(toolbar, Dock.Top);
        root.Children.Add(toolbar);
        root.Children.Add(body);
        Content = root;
        _clock.Tick += (_, _) => Tick();
        _board.SizeChanged += (_, e) => { _header = e.NewSize.Width < 480 ? 104 : 168; Render(); };
        // Too narrow to hold both: the inspector gives way to the board.
        SizeChanged += (_, e) => { if (e.NewSize.Width < 720 && e.PreviousSize.Width >= 720) _inspectorPane.IsVisible = false; };
        Unloaded += (_, _) => { _mixer.Stop(); _clock.Stop(); };
        Render();
    }

    public string ProjectId { get; }
    private int TotalBars => Math.Max(_project.Sections.Sum(s => s.Bars), 1);

    private void Save()
    {
        _store.Save(_project.Clone());
        _mixer.Apply(_project);
    }

    private void Changed()
    {
        Save();
        Render();
    }

    private static string Clock(double seconds) => $"{(int)seconds / 60}:{(int)seconds % 60:00}";

    /// <summary>A hue of its own for each track, the same every time the song is opened.</summary>
    private static Color TrackColor(MusicTrack track)
    {
        var hue = track.Id.Aggregate(0, (hash, c) => (hash * 31 + c) % 360) / 60.0;
        double Channel(double n)
        {
            var k = (n + hue) % 6;
            return 0.9 - 0.9 * 0.55 * Math.Max(0, Math.Min(Math.Min(k, 4 - k), 1));
        }
        return Color.FromRgb((byte)(255 * Channel(5)), (byte)(255 * Channel(3)), (byte)(255 * Channel(1)));
    }

    private string Title(MusicTrack track) =>
        _project.Artists.FirstOrDefault(a => a.Id == track.ArtistID)?.Name
        ?? (track.Instrument.Length == 0 ? _app.L("studio.music.track.instrument") : track.Instrument);

    private static bool CanGenerate(MusicTrack track) => track.ArtistID is not null || track.Instrument.Trim().Length > 0;

    private void Tick()
    {
        var seconds = Math.Max(_project.Seconds, 1);
        var time = _mixer.IsPlaying ? _mixer.Time : _mixer.Cue;
        _time.Text = $"{Clock(Math.Min(time, seconds))} / {Clock(seconds)}";
        var lane = Math.Max(_board.Bounds.Width - _header, 1);
        _playhead.Margin = new Thickness(_header + lane * Math.Min(time / seconds, 1), 0, 0, 0);
        if (_mixer.IsPlaying && time >= seconds + 0.3) { _mixer.Stop(); Render(); }
    }

    private void Render()
    {
        RenderBoard();
        RenderInspector();
        Tick();
    }

    private void RenderBoard()
    {
        _board.Children.Clear();
        var lane = Math.Max(_board.Bounds.Width - _header, 1);
        var stack = new StackPanel();

        // Ruler: a press moves the playhead.
        var ruler = new Canvas { Height = 24, Background = Brushes.Transparent, Margin = new Thickness(_header, 0, 0, 0) };
        var barWidth = lane / TotalBars;
        var step = new[] { 1, 2, 4, 8, 16, 32, 64 }.FirstOrDefault(s => s * barWidth >= 34, 64);
        for (var bar = 0; bar < TotalBars; bar++)
        {
            var labelled = bar % step == 0;
            var tick = new Avalonia.Controls.Shapes.Rectangle { Width = 1, Height = labelled ? 12 : 6, Fill = Brushes.Gray, Opacity = labelled ? 0.6 : 0.3 };
            Canvas.SetLeft(tick, bar * barWidth);
            Canvas.SetTop(tick, labelled ? 12 : 18);
            ruler.Children.Add(tick);
            if (!labelled) continue;
            var label = new TextBlock { Text = (bar + 1).ToString(), FontSize = 9, Foreground = Brushes.Gray };
            Canvas.SetLeft(label, bar * barWidth + 4);
            ruler.Children.Add(label);
        }
        ruler.PointerPressed += (_, e) =>
        {
            var wasPlaying = _mixer.IsPlaying;
            _mixer.Stop();
            _mixer.Cue = Math.Clamp(e.GetPosition(ruler).X / lane, 0, 1) * _project.Seconds;
            if (wasPlaying) _mixer.Play(_project, _store);
            Tick();
        };
        stack.Children.Add(ruler);

        // Sections.
        var sections = new DockPanel { Height = 46 };
        var addSection = Ui.Button("+ " + _app.L("studio.music.section.add"), () =>
        {
            var section = new MusicSection { Name = _app.L("studio.music.section.default") };
            _project.Sections.Add(section);
            _selection = "section:" + section.Id;
            Changed();
        });
        addSection.Width = _header - 8;
        addSection.Margin = new Thickness(4, 6, 4, 6);
        DockPanel.SetDock(addSection, Dock.Left);
        sections.Children.Add(addSection);
        var blocks = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var section in _project.Sections)
        {
            var selected = _selection == "section:" + section.Id;
            var texts = new StackPanel();
            texts.Children.Add(Ui.Text(section.Name, 11, bold: true));
            texts.Children.Add(Ui.Text(section.Lines.FirstOrDefault(l => l.Text.Length > 0)?.Text ?? _app.L("studio.music.section.bars", section.Bars), 10, secondary: true));
            var block = new Border
            {
                Child = texts, Width = Math.Max(lane * section.Bars / TotalBars - 2, 4), Margin = new Thickness(1, 5, 1, 5), Padding = new Thickness(6, 2, 4, 2),
                CornerRadius = new CornerRadius(6), Background = new SolidColorBrush(Color.FromArgb(selected ? (byte)0x58 : (byte)0x22, 0x3B, 0x82, 0xF6)),
                BorderBrush = Brushes.DodgerBlue, BorderThickness = new Thickness(selected ? 1 : 0), Cursor = new Cursor(StandardCursorType.Hand), ClipToBounds = true,
            };
            block.PointerReleased += (_, _) => { _selection = "section:" + section.Id; Render(); };
            blocks.Children.Add(block);
        }
        sections.Children.Add(blocks);
        stack.Children.Add(sections);
        stack.Children.Add(new Separator());

        // Lanes.
        var lanes = new StackPanel { Margin = new Thickness(0, 0, 0, 96) };
        foreach (var track in _project.Tracks) lanes.Children.Add(Lane(track, lane));
        var addTrack = Ui.Button("+ " + _app.L("studio.music.track.add"), () =>
        {
            var track = new MusicTrack();
            _project.Tracks.Add(track);
            _selection = "track:" + track.Id;
            Changed();
        });
        addTrack.HorizontalAlignment = HorizontalAlignment.Left;
        addTrack.Margin = new Thickness(6);
        lanes.Children.Add(addTrack);
        var scroll = new ScrollViewer { Content = lanes, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var page = new DockPanel();
        DockPanel.SetDock(stack, Dock.Top);
        page.Children.Add(stack);
        page.Children.Add(scroll);
        page.Background = Brushes.Transparent;
        page.PointerReleased += (_, e) => { if (e.Source == page) { _selection = "song"; Render(); } };
        _board.Children.Add(page);
        _board.Children.Add(_playhead);

        // Dock.
        var play = Ui.Button(_mixer.IsPlaying ? "■" : "▶", () =>
        {
            if (_mixer.IsPlaying) { _mixer.Stop(); _clock.Stop(); }
            else
            {
                try { _mixer.Play(_project, _store); _clock.Start(); }
                catch (InvalidOperationException ex) { _error = ex.Message; }
            }
            Render();
        });
        play.IsEnabled = _project.Tracks.Any(t => t.Clips.Count > 0);
        var dockRow = new StackPanel { Orientation = Orientation.Horizontal };
        dockRow.Children.Add(play);
        dockRow.Children.Add(_time);
        if (_busy.Count == 0)
        {
            var generate = Ui.Button("✨ " + _app.L("studio.music.generateAll"), () => Generate(_project.Tracks.Where(CanGenerate).Select(t => t.Id).ToList()), MediaSettingsPanel.Summary(_app.MediaStudio.Settings, NativeMediaKind.Music), primary: true);
            generate.IsEnabled = _project.Tracks.Any(CanGenerate);
            dockRow.Children.Add(generate);
        }
        else dockRow.Children.Add(new TextBlock { Text = _app.L("studio.music.generating", _busy.Count), Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center });
        var foot = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(12, 0, 12, 16) };
        if (_error is { } error)
        {
            var note = new Border { Child = Ui.Text(error, 12, wrap: true), Background = Ui.Brush("PanelBackground"), Padding = new Thickness(10, 6, 10, 6), CornerRadius = new CornerRadius(8), Margin = new Thickness(0, 0, 0, 8), MaxWidth = 520 };
            ((TextBlock)note.Child).Foreground = Brushes.IndianRed;
            note.PointerReleased += (_, _) => { _error = null; Render(); };
            foot.Children.Add(note);
        }
        foot.Children.Add(new Border { Child = dockRow, Background = new SolidColorBrush(Color.FromRgb(0x1E, 0x1E, 0x22)), CornerRadius = new CornerRadius(12), Padding = new Thickness(8, 6, 4, 6) });
        _board.Children.Add(foot);
    }

    private Control Lane(MusicTrack track, double lane)
    {
        var selected = _selection == "track:" + track.Id;
        var color = TrackColor(track);
        var row = new DockPanel { Height = LaneHeight, Background = selected ? new SolidColorBrush(Color.FromArgb(0x30, 0x3B, 0x82, 0xF6)) : Brushes.Transparent };
        var head = new DockPanel { Width = _header, Margin = new Thickness(8, 0, 6, 0) };
        head.Children.Add(new Border { Width = 3, Height = 26, Background = new SolidColorBrush(color), CornerRadius = new CornerRadius(1.5), Margin = new Thickness(0, 0, 6, 0) });
        var toggles = Ui.Row(Toggle("M", track.Muted, Brushes.Orange, () => track.Muted = !track.Muted, "studio.music.mute"),
            Toggle("S", track.Solo, Brushes.Gold, () => track.Solo = !track.Solo, "studio.music.solo"));
        toggles.Margin = new Thickness(0);
        toggles.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(toggles, Dock.Right);
        head.Children.Add(toggles);
        var title = Ui.Text(Title(track), 12, bold: selected);
        title.VerticalAlignment = VerticalAlignment.Center;
        head.Children.Add(title);
        DockPanel.SetDock(head, Dock.Left);
        row.Children.Add(head);

        Control content;
        if (_busy.Contains(track.Id))
            content = new TextBlock { Text = "⏳ " + _app.L("studio.music.composing"), Foreground = Brushes.Gray, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        else if (track.Clips.FirstOrDefault(c => c.SectionID is null) is { } clip)
        {
            // ponytail: a solid clip block instead of a decoded waveform.
            content = new Border
            {
                Margin = new Thickness(0, 6, 4, 6), CornerRadius = new CornerRadius(6),
                Background = new SolidColorBrush(Color.FromArgb(0xB0, color.R, color.G, color.B)), Opacity = _project.Gain(track) > 0 ? 1 : 0.3,
                Child = new TextBlock { Text = "♫  " + clip.AssetName, Foreground = Brushes.White, FontSize = 10, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis },
            };
        }
        else
        {
            content = new Border
            {
                Margin = new Thickness(0, 6, 4, 6), CornerRadius = new CornerRadius(6), BorderBrush = Brushes.Gray, BorderThickness = new Thickness(1), Opacity = 0.6,
                Child = new TextBlock { Text = _app.L("studio.music.track.empty"), Foreground = Brushes.Gray, FontSize = 11, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center },
            };
        }
        row.Children.Add(content);
        row.Cursor = new Cursor(StandardCursorType.Hand);
        row.PointerReleased += (_, e) => { if (e.Source is not TextBlock { Parent: Button }) { _selection = "track:" + track.Id; Render(); } };
        var menu = new ContextMenu();
        var generate = new MenuItem { Header = _app.L("studio.music.track.generate"), IsEnabled = CanGenerate(track) };
        generate.Click += (_, _) => Generate([track.Id]);
        menu.Items.Add(generate);
        if (track.Clips.FirstOrDefault() is { } first)
        {
            var reveal = new MenuItem { Header = _app.L("media.showInFinder") };
            reveal.Click += (_, _) => Ui.Reveal(_store.AssetPath(_project.Id, first.AssetName));
            menu.Items.Add(reveal);
        }
        var delete = new MenuItem { Header = _app.L("studio.music.track.delete") };
        delete.Click += (_, _) => RemoveTrack(track.Id);
        menu.Items.Add(delete);
        row.ContextMenu = menu;
        return new Border { Child = row, BorderBrush = Ui.Brush("BorderSubtle"), BorderThickness = new Thickness(0, 0, 0, 1) };
    }

    private Button Toggle(string letter, bool on, IBrush tint, Action change, string help)
    {
        var button = new Button
        {
            Content = letter, Width = 18, Height = 18, FontSize = 9, FontWeight = FontWeight.Bold, Padding = new Thickness(0),
            Margin = new Thickness(2, 0, 0, 0), BorderThickness = new Thickness(0), [ToolTip.TipProperty] = _app.L(help),
            Background = on ? tint : new SolidColorBrush(Color.FromArgb(0x20, 0x80, 0x80, 0x80)), Foreground = on ? Brushes.Black : Brushes.Gray,
        };
        button.Click += (_, _) => { change(); Changed(); };
        return button;
    }

    // Inspector

    private void Group(string? title)
    {
        if (title is null) { _inspector.Children.Add(new Separator { Margin = new Thickness(0, 8, 0, 8) }); return; }
        var text = Ui.Text(title, 11, bold: true);
        text.Margin = new Thickness(0, 10, 0, 6);
        _inspector.Children.Add(text);
    }

    private TextBox Field(string value, Action<string> set, bool multiline = false, string? hint = null)
    {
        var box = Ui.Field(value, hint, multiline);
        box.LostFocus += (_, _) => { if (box.Text != value) { set(box.Text); Changed(); } };
        return box;
    }

    private Control Stepper(string label, int value, int min, int max, Action<int> set)
    {
        var minus = Ui.Button("−", () => { set(Math.Max(min, value - 1)); Changed(); });
        var plus = Ui.Button("+", () => { set(Math.Min(max, value + 1)); Changed(); });
        var text = Ui.Text(label, 12);
        text.VerticalAlignment = VerticalAlignment.Center;
        text.Margin = new Thickness(0, 0, 8, 0);
        return Ui.Row(text, minus, plus);
    }

    private void RenderInspector()
    {
        _inspector.Children.Clear();
        if (_selection.StartsWith("track:") && _project.Tracks.FirstOrDefault(t => "track:" + t.Id == _selection) is { } track) TrackInspector(track);
        else if (_selection.StartsWith("section:") && _project.Sections.FirstOrDefault(s => "section:" + s.Id == _selection) is { } section) SectionInspector(section);
        else SongInspector();
    }

    private void SongInspector()
    {
        Group(_app.L("studio.music.script"));
        _inspector.Children.Add(Field(_project.Script, v => _project.Script = v, multiline: true));
        Group(_app.L("studio.music.tempo"));
        _inspector.Children.Add(Stepper(_app.L("studio.music.bpm", _project.Bpm), _project.Bpm, 40, 240, v => _project.Bpm = v));
        _inspector.Children.Add(Field(_project.Key, v => _project.Key = v, hint: _app.L("studio.music.key")));
        _inspector.Children.Add(Ui.Text($"{_app.L("studio.music.section.bars", TotalBars)}   {Clock(_project.Seconds)}", 11, secondary: true));
        Group(_app.L("studio.music.artists"));
        foreach (var artist in _project.Artists.ToList())
        {
            var remove = Ui.Button("✕", () => RemoveArtist(artist.Id), _app.L("common.remove"));
            var nameRow = new DockPanel();
            DockPanel.SetDock(remove, Dock.Right);
            nameRow.Children.Add(remove);
            nameRow.Children.Add(Field(artist.Name, v => artist.Name = v, hint: _app.L("studio.music.artist.name")));
            _inspector.Children.Add(nameRow);
            _inspector.Children.Add(Field(artist.Style, v => artist.Style = v, hint: _app.L("studio.music.artist.style")));
        }
        _inspector.Children.Add(Ui.Button("+ " + _app.L("studio.music.artist.add"), () =>
        {
            // An artist always comes with the vocal track that sings their lines.
            var artist = new MusicArtist { Name = _app.L("studio.music.artist.default", _project.Artists.Count + 1) };
            _project.Artists.Add(artist);
            _project.Tracks.Add(new MusicTrack { Instrument = "vocals", ArtistID = artist.Id });
            Changed();
        }));
    }

    private void SectionInspector(MusicSection section)
    {
        Group(_app.L("studio.music.section"));
        _inspector.Children.Add(Field(section.Name, v => section.Name = v));
        _inspector.Children.Add(Stepper(_app.L("studio.music.section.bars", section.Bars), section.Bars, 1, 64, v => section.Bars = v));
        Group(_app.L("studio.music.lyrics"));
        foreach (var line in section.Lines.ToList())
        {
            var singer = new ComboBox { MinWidth = 150 };
            singer.Items.Add(new ComboBoxItem { Content = _app.L("studio.music.line.unsung"), Tag = null });
            foreach (var artist in _project.Artists) singer.Items.Add(new ComboBoxItem { Content = artist.Name, Tag = artist.Id });
            singer.SelectedItem = singer.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string?)i.Tag == line.ArtistID) ?? singer.Items[0];
            singer.SelectionChanged += (_, _) => { line.ArtistID = (singer.SelectedItem as ComboBoxItem)?.Tag as string; Save(); };
            var remove = Ui.Button("✕", () => { section.Lines.Remove(line); Changed(); }, _app.L("common.remove"));
            _inspector.Children.Add(Ui.Row(singer, remove));
            _inspector.Children.Add(Field(line.Text, v => line.Text = v, hint: _app.L("studio.music.line.placeholder")));
        }
        _inspector.Children.Add(Ui.Button("+ " + _app.L("studio.music.line.add"), () =>
        {
            section.Lines.Add(new MusicLine { ArtistID = section.Lines.LastOrDefault()?.ArtistID ?? _project.Artists.FirstOrDefault()?.Id });
            Changed();
        }));
        Group(null);
        _inspector.Children.Add(Ui.Button(_app.L("studio.music.section.delete"), () =>
        {
            _selection = "song";
            _project.Sections.Remove(section);
            Changed();
        }));
    }

    private void TrackInspector(MusicTrack track)
    {
        Group(_app.L("studio.music.track"));
        if (_project.Artists.FirstOrDefault(a => a.Id == track.ArtistID) is { } artist)
            _inspector.Children.Add(Ui.Text("🎤 " + _app.L("studio.music.track.vocal", artist.Name), 12, bold: true));
        else _inspector.Children.Add(Field(track.Instrument, v => track.Instrument = v.Trim(), hint: _app.L("studio.music.track.instrument")));
        _inspector.Children.Add(Field(track.Prompt, v => track.Prompt = v, multiline: true, hint: _app.L("studio.music.track.prompt")));
        if (_busy.Contains(track.Id)) _inspector.Children.Add(Ui.Text("⏳ " + _app.L("studio.music.composing"), 12, secondary: true));
        else
        {
            var generate = Ui.Button("✨ " + _app.L(track.Clips.Count == 0 ? "studio.music.track.generate" : "studio.music.regenerate"), () => Generate([track.Id]), primary: true);
            generate.IsEnabled = CanGenerate(track);
            _inspector.Children.Add(generate);
        }
        Group(_app.L("studio.music.mix"));
        var volume = new Slider { Minimum = 0, Maximum = 1, Value = track.Volume, Width = 180 };
        volume.ValueChanged += (_, _) => { track.Volume = volume.Value; _mixer.Apply(_project); };
        volume.PointerCaptureLost += (_, _) => Save();
        _inspector.Children.Add(Ui.Row(Ui.Text("🔈", 12), volume));
        var mute = new CheckBox { Content = _app.L("studio.music.mute"), IsChecked = track.Muted, Margin = new Thickness(0, 0, 12, 0) };
        mute.Click += (_, _) => { track.Muted = mute.IsChecked == true; Changed(); };
        var solo = new CheckBox { Content = _app.L("studio.music.solo"), IsChecked = track.Solo };
        solo.Click += (_, _) => { track.Solo = solo.IsChecked == true; Changed(); };
        _inspector.Children.Add(Ui.Row(mute, solo));
        Group(null);
        if (track.Clips.FirstOrDefault() is { } clip)
            _inspector.Children.Add(Ui.Button(_app.L("media.showInFinder"), () => Ui.Reveal(_store.AssetPath(_project.Id, clip.AssetName))));
        _inspector.Children.Add(Ui.Button(_app.L("studio.music.track.delete"), () => RemoveTrack(track.Id)));
    }

    // Edits

    private void RemoveArtist(string id)
    {
        foreach (var track in _project.Tracks.Where(t => t.ArtistID == id).ToList()) RemoveTrack(track.Id, render: false);
        _project.Artists.RemoveAll(a => a.Id == id);
        foreach (var line in _project.Sections.SelectMany(s => s.Lines).Where(l => l.ArtistID == id)) line.ArtistID = null;
        Changed();
    }

    private void RemoveTrack(string id, bool render = true)
    {
        if (_project.Tracks.FirstOrDefault(t => t.Id == id) is not { } track) return;
        if (_selection == "track:" + id) _selection = "song";
        _mixer.Stop();
        DeleteFiles(track);
        _project.Tracks.Remove(track);
        if (render) Changed();
    }

    private void DeleteFiles(MusicTrack track)
    {
        foreach (var clip in track.Clips)
        {
            try { File.Delete(_store.AssetPath(_project.Id, clip.AssetName)); } catch (IOException) { }
        }
    }

    private async void Generate(List<string> ids)
    {
        var pending = ids.Where(id => _busy.Add(id)).ToList();
        if (pending.Count == 0) return;
        _error = null;
        _mixer.Stop();
        Render();
        var snapshot = _project.Clone();
        var settings = _app.MediaStudio.Settings;
        var serial = settings.MusicEndpoint is { } endpoint ? endpoint.Format == MusicEndpoint.Standard : settings.MusicSource == MediaStudioSettings.Local;
        // A server of your own renders one request at a time; cloud services take them together.
        if (serial) foreach (var id in pending) await RenderTrack(id, snapshot, settings);
        else await Task.WhenAll(pending.Select(id => RenderTrack(id, snapshot, settings)));
    }

    /// <summary>Replaces the track's audio with a fresh take of whatever the track says now.</summary>
    private async Task RenderTrack(string id, MusicProject snapshot, MediaStudioSettings settings)
    {
        try
        {
            if (snapshot.Tracks.FirstOrDefault(t => t.Id == id) is not { } track) return;
            var clip = await MusicStudioAI.RenderAsync(track, snapshot, _app.Router, settings, _app.Paths, _app.Secrets, _store);
            if (_project.Tracks.FirstOrDefault(t => t.Id == id) is not { } live)
            {
                try { File.Delete(_store.AssetPath(_project.Id, clip.AssetName)); } catch (IOException) { }
                return;
            }
            DeleteFiles(live);
            live.Clips = [clip];
            Save();
        }
        catch (Exception ex)
        {
            var title = _project.Tracks.FirstOrDefault(t => t.Id == id) is { } t ? Title(t) : "";
            _error = $"{title}: {ex.Message}";
        }
        finally
        {
            _busy.Remove(id);
            Render();
        }
    }
}
