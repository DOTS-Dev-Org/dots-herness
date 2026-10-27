// Copyright (c) 2026 DOTS
// Android emulator panel: live screen over the emulator's gRPC stream, touch and device keys.

using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;
using DotsHarnessCore;

namespace DotsHarness.Views;

internal sealed class AndroidEmulatorPanel : UserControl
{
    /// <summary>Frame width asked of the emulator; it scales on its side and never exceeds the device.</summary>
    private const int StreamWidth = 720;

    private readonly ComboBox _devices = new() { Margin = new Thickness(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBlock _badge = new() { FontSize = 11 };
    private readonly Ellipse _dot = new() { Width = 6, Height = 6, Margin = new Thickness(0, 0, 5, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly Image _screen = new() { Stretch = Stretch.Uniform, Cursor = new Cursor(StandardCursorType.Hand) };
    private readonly Border _bezel;
    private readonly StackPanel _placeholder = new() { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 60) };
    private readonly TextBlock _placeholderText = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, MaxWidth = 220, Margin = new Thickness(0, 12, 0, 12) };
    private readonly Button _bootButton = new() { Content = "Boot emulator", Padding = new Thickness(14, 5), HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock _status = new() { FontSize = 11, Margin = new Thickness(12, 6), TextWrapping = TextWrapping.Wrap, IsVisible = false };
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
        Bind(BackgroundProperty, this.GetResourceObservable("WindowBackground"));

        var title = new TextBlock { Text = "Android Emulator", FontWeight = FontWeight.SemiBold, FontSize = 14, VerticalAlignment = VerticalAlignment.Center };
        title.Bind(TextBlock.ForegroundProperty, this.GetResourceObservable("TextPrimary"));
        _badge.Bind(TextBlock.ForegroundProperty, this.GetResourceObservable("TextSecondary"));
        var badge = new Border
        {
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(7, 2),
            Margin = new Thickness(8, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
            Background = new SolidColorBrush(Color.FromArgb(0x1F, 0x80, 0x80, 0x80)),
            Child = new StackPanel { Orientation = Orientation.Horizontal, Children = { _dot, _badge } },
        };
        var header = new StackPanel { Margin = new Thickness(12, 10) };
        header.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Children = { title, badge } });
        header.Children.Add(_devices);
        var headerBorder = new Border { BorderThickness = new Thickness(0, 0, 0, 1), Child = header };
        headerBorder.Bind(Border.BorderBrushProperty, this.GetResourceObservable("BorderSubtle"));

        _bezel = new Border
        {
            Background = Brushes.Black,
            CornerRadius = new CornerRadius(26),
            Padding = new Thickness(8),
            Margin = new Thickness(16, 16, 16, 72),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Child = _screen,
            IsVisible = false,
            BoxShadow = BoxShadows.Parse("0 8 22 0 #66000000"),
        };

        var iconText = new TextBlock { Text = "📱", FontSize = 30, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var icon = new Border
        {
            Width = 72,
            Height = 72,
            CornerRadius = new CornerRadius(36),
            HorizontalAlignment = HorizontalAlignment.Center,
            Background = new SolidColorBrush(Color.FromArgb(0x1A, 0x80, 0x80, 0x80)),
            Child = iconText,
        };
        _placeholderText.Bind(TextBlock.ForegroundProperty, this.GetResourceObservable("TextSecondary"));
        _bootButton.Click += async (_, _) => await BootSelectedAsync();
        _placeholder.Children.Add(icon);
        _placeholder.Children.Add(_placeholderText);
        _placeholder.Children.Add(_bootButton);

        _streamButton = DockButton("❚❚", "Pause or resume the live view", ToggleStream);
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
            BoxShadow = BoxShadows.Parse("0 3 10 0 #4D000000"),
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Children =
                {
                    DockButton("◀", "Back", () => SendKey("GoBack")),
                    DockButton("⌂", "Home", () => SendKey("GoHome")),
                    DockButton("▢", "Recent apps", () => SendKey("AppSwitch")),
                    DockDivider(),
                    _streamButton,
                    DockButton("↻", "Refresh devices", () => _ = RefreshAsync()),
                    DockDivider(),
                    DockButton("⏻", "Boot or shut down", () => _ = TogglePowerAsync()),
                },
            },
        };

        var screenArea = new Grid { Children = { _placeholder, _bezel, dock } };
        screenArea.Bind(Panel.BackgroundProperty, this.GetResourceObservable("ChromeBackground"));
        _status.Bind(TextBlock.ForegroundProperty, this.GetResourceObservable("TextSecondary"));

        var root = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(headerBorder, Dock.Top);
        DockPanel.SetDock(_status, Dock.Bottom);
        root.Children.Add(headerBorder);
        root.Children.Add(_status);
        root.Children.Add(screenArea);
        Content = root;

        _devices.SelectionChanged += (_, _) => ShowSelected();
        _screen.PointerPressed += OnPointerPressed;
        _screen.PointerMoved += OnPointerMoved;
        _screen.PointerReleased += OnPointerReleased;
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
        _bootButton.IsVisible = target is not null;
    }

    private void StartMirror(AndroidEmulatorEndpoint endpoint)
    {
        StopMirror();
        var mirror = new AndroidEmulatorMirror(endpoint);
        mirror.FrameReady += () => Dispatcher.UIThread.Post(DrawFrame, DispatcherPriority.Render);
        mirror.Failed += message => Dispatcher.UIThread.Post(() => ShowStatus(message));
        _mirror = mirror;
        mirror.Start(StreamWidth, rgba: true);
        _streamButton.Content = "❚❚";
        _placeholderText.Text = "Waiting for the first frame…";
        _bootButton.IsVisible = false;
        ShowStatus("");
        UpdateBadge(0);
    }

    private void StopMirror()
    {
        _mirror?.Dispose();
        _mirror = null;
        _bitmap?.Dispose();
        _bitmap = null;
        _screen.Source = null;
        _bezel.IsVisible = false;
        _placeholder.IsVisible = true;
        _streamButton.Content = "▶";
        UpdateBadge(0);
    }

    private void DrawFrame()
    {
        _mirror?.TryTakeFrame((pixels, length, width, height) =>
        {
            if (length < width * height * 4) return;
            if (_bitmap is null || _bitmap.PixelSize.Width != width || _bitmap.PixelSize.Height != height)
            {
                _bitmap?.Dispose();
                _bitmap = new WriteableBitmap(new PixelSize(width, height), new Vector(96, 96), PixelFormat.Rgba8888, AlphaFormat.Opaque);
                _screen.Source = _bitmap;
            }
            using (var target = _bitmap.Lock())
            {
                var row = width * 4;
                if (target.RowBytes == row) Marshal.Copy(pixels, 0, target.Address, row * height);
                else for (var y = 0; y < height; y++) Marshal.Copy(pixels, y * row, target.Address + y * target.RowBytes, row);
            }
            _screen.InvalidateVisual();
            _frames++;
        });
        if (_bitmap is not null && !_bezel.IsVisible)
        {
            _bezel.IsVisible = true;
            _placeholder.IsVisible = false;
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
            _streamButton.Content = "▶";
        }
        else
        {
            _mirror.Start(StreamWidth, rgba: true);
            _streamButton.Content = "❚❚";
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

    private void OnPointerPressed(object? sender, PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(_screen).Properties.IsLeftButtonPressed) return;
        _pressed = true;
        e.Pointer.Capture(_screen);
        Touch(e.GetPosition(_screen), down: true, force: true);
    }

    private void OnPointerMoved(object? sender, PointerEventArgs e)
    {
        if (_pressed) Touch(e.GetPosition(_screen), down: true, force: false);
    }

    private void OnPointerReleased(object? sender, PointerReleasedEventArgs e)
    {
        if (!_pressed) return;
        _pressed = false;
        e.Pointer.Capture(null);
        Touch(e.GetPosition(_screen), down: false, force: true);
    }

    /// <summary>Touches go out one at a time; a move is dropped while the previous touch is in flight.</summary>
    private void Touch(Point point, bool down, bool force)
    {
        var size = _screen.Bounds.Size;
        if (_mirror is not { } mirror || size.Width <= 0 || size.Height <= 0) return;
        if (!force && !_touches.IsCompleted) return;
        var x = (int)(Math.Clamp(point.X / size.Width, 0, 1) * mirror.Endpoint.ScreenWidth);
        var y = (int)(Math.Clamp(point.Y / size.Height, 0, 1) * mirror.Endpoint.ScreenHeight);
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
        _status.IsVisible = !string.IsNullOrEmpty(text);
    }

    private static Button DockButton(string glyph, string tip, Action action)
    {
        var button = new Button
        {
            Content = glyph,
            Width = 32,
            Height = 32,
            Padding = new Thickness(0),
            FontSize = 14,
            Foreground = Brushes.White,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(6),
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
            Cursor = new Cursor(StandardCursorType.Hand),
        };
        ToolTip.SetTip(button, tip);
        AutomationProperties.SetName(button, tip);
        button.Click += (_, _) => action();
        return button;
    }

    private static Control DockDivider() =>
        new Border { Width = 1, Height = 18, Margin = new Thickness(4, 0), Background = new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0xFF, 0xFF)) };
}
