// Copyright (c) 2026 DOTS
// Android emulator panel: live screen over the emulator's gRPC stream, touch and device keys.

using System.Net.Http;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using DotsHarnessCore;

namespace DotsHarness.Views;

internal sealed class AndroidEmulatorPanel : UserControl
{
    /// <summary>Frame width asked of the emulator; it scales on its side and never exceeds the device.</summary>
    private const int StreamWidth = 720;

    private static readonly FontFamily Glyphs = new("Segoe MDL2 Assets");

    private readonly ComboBox _devices = new() { Margin = new Thickness(0, 8, 0, 0) };
    private readonly TextBlock _badge = new() { FontSize = 11 };
    private readonly Ellipse _dot = new() { Width = 6, Height = 6, Margin = new Thickness(0, 0, 5, 0) };
    private readonly Image _screen = new() { Stretch = Stretch.Uniform, Cursor = Cursors.Hand };
    private readonly Border _bezel;
    private readonly StackPanel _placeholder = new() { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock _placeholderText = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, MaxWidth = 220, Margin = new Thickness(0, 12, 0, 12) };
    private readonly Button _bootButton = new() { Content = "Boot emulator", Padding = new Thickness(14, 5, 14, 5) };
    private readonly TextBlock _status = new() { FontSize = 11, Margin = new Thickness(12, 6, 12, 6), TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
    private readonly Button _streamButton;
    private readonly DispatcherTimer _fpsTimer = new() { Interval = TimeSpan.FromSeconds(1) };

    private AndroidEmulatorMirror? _mirror;
    private WriteableBitmap? _bitmap;
    private Task _touches = Task.CompletedTask;
    private bool _pressed;
    private int _frames;
    private bool _busy;

    public AndroidEmulatorPanel()
    {
        SetResourceReference(BackgroundProperty, "WindowBackground");

        var title = new TextBlock { Text = "Android Emulator", FontWeight = FontWeights.SemiBold, FontSize = 14, VerticalAlignment = VerticalAlignment.Center };
        title.SetResourceReference(TextBlock.ForegroundProperty, "TextPrimary");
        _badge.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
        var badge = new Border
        {
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(7, 2, 7, 2),
            Margin = new Thickness(8, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
            Background = new SolidColorBrush(Color.FromArgb(0x1F, 0x80, 0x80, 0x80)),
            Child = new StackPanel { Orientation = Orientation.Horizontal, Children = { _dot, _badge } },
        };
        _dot.VerticalAlignment = VerticalAlignment.Center;
        var header = new StackPanel { Margin = new Thickness(12, 10, 12, 10) };
        header.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Children = { title, badge } });
        header.Children.Add(_devices);
        var headerBorder = new Border { BorderThickness = new Thickness(0, 0, 0, 1), Child = header };
        headerBorder.SetResourceReference(Border.BorderBrushProperty, "BorderSubtle");

        _bezel = new Border
        {
            Background = Brushes.Black,
            CornerRadius = new CornerRadius(26),
            Padding = new Thickness(8),
            Margin = new Thickness(16, 16, 16, 72),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Child = _screen,
            Visibility = Visibility.Collapsed,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 22, ShadowDepth = 8, Opacity = 0.4 },
        };

        var icon = new Border
        {
            Width = 72,
            Height = 72,
            CornerRadius = new CornerRadius(36),
            HorizontalAlignment = HorizontalAlignment.Center,
            Background = new SolidColorBrush(Color.FromArgb(0x1A, 0x80, 0x80, 0x80)),
            Child = new TextBlock { Text = "", FontFamily = Glyphs, FontSize = 30, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
        };
        ((TextBlock)icon.Child).SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
        _placeholderText.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
        _bootButton.Click += async (_, _) => await BootSelectedAsync();
        _placeholder.Children.Add(icon);
        _placeholder.Children.Add(_placeholderText);
        _placeholder.Children.Add(_bootButton);
        _placeholder.Margin = new Thickness(0, 0, 0, 60);

        _streamButton = DockButton("", "Pause or resume the live view", ToggleStream);
        var dock = new Border
        {
            Background = new SolidColorBrush(Color.FromRgb(0x2B, 0x2B, 0x2B)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(13),
            Padding = new Thickness(5),
            Margin = new Thickness(0, 0, 0, 12),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Bottom,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 10, ShadowDepth = 3, Opacity = 0.3 },
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Children =
                {
                    DockButton("", "Back", () => SendKey("GoBack")),
                    DockButton("", "Home", () => SendKey("GoHome")),
                    DockButton("", "Recent apps", () => SendKey("AppSwitch")),
                    DockDivider(),
                    _streamButton,
                    DockButton("", "Refresh devices", () => _ = RefreshAsync()),
                    DockDivider(),
                    DockButton("", "Boot or shut down", () => _ = TogglePowerAsync()),
                },
            },
        };

        var screenArea = new Grid { Children = { _placeholder, _bezel, dock } };
        screenArea.SetResourceReference(Panel.BackgroundProperty, "ChromeBackground");
        _status.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");

        var root = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(headerBorder, Dock.Top);
        DockPanel.SetDock(_status, Dock.Bottom);
        root.Children.Add(headerBorder);
        root.Children.Add(_status);
        root.Children.Add(screenArea);
        Content = root;

        _devices.SelectionChanged += (_, _) => ShowSelected();
        _screen.MouseLeftButtonDown += OnPointerDown;
        _screen.MouseMove += OnPointerMove;
        _screen.MouseLeftButtonUp += OnPointerUp;
        _fpsTimer.Tick += (_, _) => { UpdateBadge(_frames); _frames = 0; };
        Loaded += async (_, _) => { _fpsTimer.Start(); await RefreshAsync(); };
        Unloaded += (_, _) => { _fpsTimer.Stop(); StopMirror(); };
        UpdateBadge(0);
    }

    private AndroidEmulatorTarget? Selected => _devices.SelectedItem as AndroidEmulatorTarget;

    private async Task RefreshAsync()
    {
        var previous = Selected?.AvdName;
        var targets = await AndroidEmulatorTarget.ListAsync();
        _devices.ItemsSource = targets;
        _devices.SelectedItem = targets.FirstOrDefault(target => target.AvdName == previous) ?? targets.FirstOrDefault();
        if (targets.Count == 0) ShowSelected();
    }

    private void ShowSelected()
    {
        var target = Selected;
        if (target?.Endpoint is { } endpoint)
        {
            if (_mirror?.Endpoint != endpoint) StartMirror(endpoint);
            return;
        }
        StopMirror();
        _placeholderText.Text = target is null
            ? "No Android virtual devices found. Create one in Android Studio's Device Manager."
            : "This emulator is not running. Boot it to see its screen here.";
        _bootButton.Visibility = target is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void StartMirror(AndroidEmulatorEndpoint endpoint)
    {
        StopMirror();
        var mirror = new AndroidEmulatorMirror(endpoint);
        mirror.FrameReady += () => Dispatcher.BeginInvoke(DispatcherPriority.Render, DrawFrame);
        mirror.Failed += message => Dispatcher.BeginInvoke(() => ShowStatus(message));
        _mirror = mirror;
        mirror.Start(StreamWidth, rgba: false);
        _streamButton.Content = Glyph("");
        _placeholderText.Text = "Waiting for the first frame…";
        _bootButton.Visibility = Visibility.Collapsed;
        ShowStatus("");
        UpdateBadge(0);
    }

    private void StopMirror()
    {
        _mirror?.Dispose();
        _mirror = null;
        _bitmap = null;
        _screen.Source = null;
        _bezel.Visibility = Visibility.Collapsed;
        _placeholder.Visibility = Visibility.Visible;
        _streamButton.Content = Glyph("");
        UpdateBadge(0);
    }

    private void DrawFrame()
    {
        _mirror?.TryTakeFrame((pixels, length, width, height) =>
        {
            if (length < width * height * 3) return;
            if (_bitmap is null || _bitmap.PixelWidth != width || _bitmap.PixelHeight != height)
            {
                _bitmap = new WriteableBitmap(width, height, 96, 96, PixelFormats.Rgb24, null);
                _screen.Source = _bitmap;
            }
            _bitmap.WritePixels(new Int32Rect(0, 0, width, height), pixels, width * 3, 0);
            _frames++;
        });
        if (_bitmap is not null && _bezel.Visibility != Visibility.Visible)
        {
            _bezel.Visibility = Visibility.Visible;
            _placeholder.Visibility = Visibility.Collapsed;
        }
    }

    private void ToggleStream()
    {
        if (_mirror is null)
        {
            ShowSelected();
            return;
        }
        if (_mirror.IsStreaming)
        {
            _mirror.Stop();
            _streamButton.Content = Glyph("");
        }
        else
        {
            _mirror.Start(StreamWidth, rgba: false);
            _streamButton.Content = Glyph("");
        }
        UpdateBadge(0);
    }

    private async Task BootSelectedAsync()
    {
        if (Selected is not { IsRunning: false } target || _busy) return;
        _busy = true;
        try
        {
            ShowStatus($"Booting {target.AvdName}…");
            AndroidEmulatorService.Boot(target.AvdName, headless: true);
            var endpoint = await AndroidEmulatorTarget.WaitForEndpointAsync(target.AvdName, TimeSpan.FromSeconds(90));
            if (endpoint is null)
            {
                ShowStatus($"{target.AvdName} did not start within 90 seconds.");
                return;
            }
            await RefreshAsync();
            ShowStatus("");
        }
        catch (AndroidEmulatorException error) { ShowStatus(error.Message); }
        finally { _busy = false; }
    }

    private async Task TogglePowerAsync()
    {
        if (Selected?.Endpoint is not { } endpoint)
        {
            await BootSelectedAsync();
            return;
        }
        try
        {
            StopMirror();
            await AndroidEmulatorService.ShutdownAsync(endpoint.Serial);
            await Task.Delay(1500);
            await RefreshAsync();
        }
        catch (AndroidEmulatorException error) { ShowStatus(error.Message); }
    }

    private void SendKey(string key)
    {
        if (_mirror is { } mirror) _ = Report(mirror.KeyAsync(key));
    }

    private void OnPointerDown(object sender, MouseButtonEventArgs e)
    {
        _pressed = true;
        _screen.CaptureMouse();
        Touch(e.GetPosition(_screen), down: true, force: true);
    }

    private void OnPointerMove(object sender, MouseEventArgs e)
    {
        if (_pressed) Touch(e.GetPosition(_screen), down: true, force: false);
    }

    private void OnPointerUp(object sender, MouseButtonEventArgs e)
    {
        if (!_pressed) return;
        _pressed = false;
        _screen.ReleaseMouseCapture();
        Touch(e.GetPosition(_screen), down: false, force: true);
    }

    /// <summary>Touches go out one at a time; a move is dropped while the previous touch is in flight.</summary>
    private void Touch(Point point, bool down, bool force)
    {
        if (_mirror is not { } mirror || _screen.ActualWidth <= 0 || _screen.ActualHeight <= 0) return;
        if (!force && !_touches.IsCompleted) return;
        var x = (int)(Math.Clamp(point.X / _screen.ActualWidth, 0, 1) * mirror.Endpoint.ScreenWidth);
        var y = (int)(Math.Clamp(point.Y / _screen.ActualHeight, 0, 1) * mirror.Endpoint.ScreenHeight);
        _touches = _touches.ContinueWith(_ => mirror.TouchAsync(x, y, down), TaskScheduler.Default).Unwrap();
        _ = Report(_touches);
    }

    private async Task Report(Task task)
    {
        try { await task; }
        catch (Exception error) when (error is AndroidEmulatorException or HttpRequestException) { ShowStatus(error.Message); }
    }

    private void UpdateBadge(int fps)
    {
        var live = _mirror?.IsStreaming == true;
        _dot.Fill = live ? new SolidColorBrush(Color.FromRgb(0x2E, 0xCC, 0x71)) : new SolidColorBrush(Color.FromArgb(0x80, 0x80, 0x80, 0x80));
        _badge.Text = live ? $"gRPC · {fps} FPS" : "gRPC · stopped";
    }

    private void ShowStatus(string text)
    {
        _status.Text = text;
        _status.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
    }

    private static TextBlock Glyph(string glyph) =>
        new() { Text = glyph, FontFamily = Glyphs, FontSize = 14, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };

    private static Button DockButton(string glyph, string tip, Action action)
    {
        var button = new Button { Content = Glyph(glyph), ToolTip = tip, Width = 32, Height = 32, Template = FlatTemplate(), Cursor = Cursors.Hand };
        AutomationProperties.SetName(button, tip);
        button.Click += (_, _) => action();
        return button;
    }

    private static UIElement DockDivider() =>
        new Border { Width = 1, Height = 18, Margin = new Thickness(4, 0, 4, 0), Background = new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0xFF, 0xFF)) };

    /// <summary>Transparent button that tints on hover, like the macOS dock.</summary>
    private static ControlTemplate FlatTemplate()
    {
        var border = new FrameworkElementFactory(typeof(Border)) { Name = "Chrome" };
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
        border.SetValue(Border.BackgroundProperty, Brushes.Transparent);
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        content.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(content);
        var template = new ControlTemplate(typeof(Button)) { VisualTree = border };
        var hover = new Trigger { Property = IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty, new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0xFF, 0xFF)), "Chrome"));
        template.Triggers.Add(hover);
        return template;
    }
}
