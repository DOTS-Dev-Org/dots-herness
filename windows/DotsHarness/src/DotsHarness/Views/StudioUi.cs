// Copyright (c) 2026 DOTS
// Small building blocks shared by the rail sections (Media, Bots, Tasks, Memory), and the
// WPF drawing of media canvases. Mirrors MediaRendering.swift on macOS.

using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using DotsHarnessCore;

namespace DotsHarness.Views;

internal static class Ui
{
    public static Brush Brush(string key) => Application.Current?.TryFindResource(key) as Brush ?? Brushes.Gray;

    public static TextBlock Text(string text, double size = 13, bool bold = false, bool secondary = false, bool wrap = false) => new()
    {
        Text = text,
        FontSize = size,
        FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        Foreground = Brush(secondary ? "TextSecondary" : "TextPrimary"),
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
        TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
    };

    public static Button Button(string content, Action click, string? tooltip = null, bool primary = false)
    {
        var button = new Button
        {
            Content = content,
            Padding = new Thickness(10, 4, 10, 4),
            Margin = new Thickness(0, 0, 6, 0),
            ToolTip = tooltip,
        };
        if (primary)
        {
            button.Background = Brush("Accent");
            button.Foreground = Brushes.White;
        }
        button.Click += (_, _) => click();
        return button;
    }

    public static TextBox Field(string text, string? hint = null, bool multiline = false)
    {
        var box = new TextBox
        {
            Text = text,
            Padding = new Thickness(6, 4, 6, 4),
            Margin = new Thickness(0, 0, 0, 6),
            ToolTip = hint,
            AcceptsReturn = multiline,
            TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
            MinLines = multiline ? 3 : 1,
        };
        return box;
    }

    public static Border Card(UIElement child, double padding = 12) => new()
    {
        Child = child,
        Padding = new Thickness(padding),
        Margin = new Thickness(0, 0, 12, 12),
        CornerRadius = new CornerRadius(12),
        BorderThickness = new Thickness(1),
        BorderBrush = Brush("BorderSubtle"),
        Background = Brush("PanelBackground"),
    };

    public static StackPanel Row(params UIElement[] children)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
        foreach (var child in children) row.Children.Add(child);
        return row;
    }

    public static Color Hex(string? hex)
    {
        var digits = (hex ?? "").Trim('#', ' ');
        return digits.Length == 6 && uint.TryParse(digits, System.Globalization.NumberStyles.HexNumber, null, out var value)
            ? Color.FromRgb((byte)(value >> 16), (byte)(value >> 8), (byte)value)
            : Colors.Gray;
    }

    public static string Hex(Color color) => $"#{color.R:X2}{color.G:X2}{color.B:X2}";

    public static string Relative(DateTimeOffset date)
    {
        var age = DateTimeOffset.Now - date;
        return age.TotalMinutes < 1 ? "now"
            : age.TotalHours < 1 ? $"{(int)age.TotalMinutes} min"
            : age.TotalDays < 1 ? $"{(int)age.TotalHours} h"
            : date.LocalDateTime.ToString("d", LocalizationService.Current.Culture);
    }

    public static void Open(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception) { }
    }

    public static void Reveal(string path)
    {
        try { Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true }); }
        catch (Exception) { }
    }

    /// <summary>Asks for one line of text; null when cancelled.</summary>
    public static string? Prompt(Window? owner, string title, string text = "")
    {
        var box = Field(text);
        var ok = new Button { Content = LocalizationService.Current.Get("common.save"), IsDefault = true, Padding = new Thickness(12, 4, 12, 4) };
        var cancel = new Button { Content = LocalizationService.Current.Get("common.cancel"), IsCancel = true, Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(6, 0, 0, 0) };
        var panel = new StackPanel { Margin = new Thickness(14) };
        panel.Children.Add(Text(title, bold: true));
        box.Margin = new Thickness(0, 8, 0, 10);
        panel.Children.Add(box);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(ok);
        buttons.Children.Add(cancel);
        panel.Children.Add(buttons);
        var dialog = new Window
        {
            Owner = owner, Content = panel, Width = 380, SizeToContent = SizeToContent.Height, Title = title,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize,
            Background = Brush("WindowBackground"),
        };
        ok.Click += (_, _) => dialog.DialogResult = true;
        box.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        return dialog.ShowDialog() == true ? box.Text.Trim() : null;
    }

    public static Window? OwnerOf(DependencyObject element) => Window.GetWindow(element);
}

/// <summary>Draws media canvases and layers as WPF elements at their natural size.</summary>
internal static class MediaRenderer
{
    private static readonly Dictionary<string, BitmapSource?> Images = [];

    public static BitmapSource? Image(string? path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return null;
        if (Images.TryGetValue(path, out var cached)) return cached;
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.UriSource = new Uri(path);
            image.EndInit();
            image.Freeze();
            if (Images.Count > 64) Images.Clear();
            return Images[path] = image;
        }
        catch (Exception) { return Images[path] = null; }
    }

    public static (double, double)? NaturalSize(string path) =>
        Image(path) is { } image ? (image.PixelWidth, image.PixelHeight) : null;

    private static Brush Fill(MediaLayer layer) => layer.GradientHex is { } second
        ? new LinearGradientBrush(Ui.Hex(layer.ColorHex), Ui.Hex(second), new Point(0, 0), new Point(1, 1))
        : new SolidColorBrush(Ui.Hex(layer.ColorHex));

    private static Geometry Polygon(double w, double h, bool star)
    {
        var points = new List<Point>();
        if (star)
        {
            for (var i = 0; i < 10; i++)
            {
                var angle = i * Math.PI / 5 - Math.PI / 2;
                var reach = i % 2 == 0 ? 1.0 : 0.4;
                points.Add(new Point(w / 2 + Math.Cos(angle) * reach * w / 2, h / 2 + Math.Sin(angle) * reach * h / 2));
            }
        }
        else points.AddRange([new Point(w / 2, 0), new Point(w, h), new Point(0, h)]);
        var figure = new PathFigure { StartPoint = points[0], IsClosed = true, IsFilled = true };
        foreach (var point in points.Skip(1)) figure.Segments.Add(new LineSegment(point, true));
        return new PathGeometry([figure]);
    }

    private static FontFamily Font(string design) => new(design switch
    {
        "serif" => "Georgia",
        "mono" => "Consolas",
        "rounded" => "Segoe UI Variable Display, Segoe UI",
        _ => "Segoe UI",
    });

    private static FontWeight Weight(string weight) =>
        weight == "bold" ? FontWeights.Bold : weight == "medium" ? FontWeights.Medium : FontWeights.Normal;

    /// <summary>One layer at its natural size; the caller positions it.</summary>
    public static FrameworkElement Layer(MediaLayer layer, Func<string, string> assetPath)
    {
        FrameworkElement content;
        var w = Math.Max(layer.Width, 1);
        var h = Math.Max(layer.Height, 1);
        switch (layer.Kind)
        {
            case "text" when layer.Arc != 0:
                content = ArcText(layer);
                break;
            case "text":
                content = new TextBlock
                {
                    Text = layer.Text, FontSize = Math.Max(layer.FontSize, 1), FontWeight = Weight(layer.FontWeight),
                    FontFamily = Font(layer.FontDesign), Foreground = Fill(layer), TextWrapping = TextWrapping.Wrap,
                    TextAlignment = layer.Alignment == "center" ? TextAlignment.Center : layer.Alignment == "trailing" ? TextAlignment.Right : TextAlignment.Left,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                content = new Grid { Children = { content } };
                break;
            case "shape" when layer.Shape is "polygon" or "star":
                content = new System.Windows.Shapes.Path
                {
                    Data = Polygon(w, h, layer.Shape == "star"), Fill = Fill(layer),
                    Stroke = layer.StrokeHex is { } s && layer.StrokeWidth > 0 ? new SolidColorBrush(Ui.Hex(s)) : null,
                    StrokeThickness = layer.StrokeWidth, StrokeLineJoin = PenLineJoin.Round,
                };
                break;
            case "shape" when layer.Shape == "ellipse":
                content = new Ellipse
                {
                    Fill = Fill(layer),
                    Stroke = layer.StrokeHex is { } s2 && layer.StrokeWidth > 0 ? new SolidColorBrush(Ui.Hex(s2)) : null,
                    StrokeThickness = layer.StrokeWidth,
                };
                break;
            case "shape":
                content = new Border
                {
                    Background = Fill(layer), CornerRadius = new CornerRadius(layer.CornerRadius),
                    BorderBrush = layer.StrokeHex is { } s3 && layer.StrokeWidth > 0 ? new SolidColorBrush(Ui.Hex(s3)) : null,
                    BorderThickness = new Thickness(layer.StrokeHex is not null ? layer.StrokeWidth : 0),
                };
                break;
            case "path":
                content = PathLayer(layer, w, h);
                break;
            case "icon":
                content = new Viewbox
                {
                    Child = new TextBlock { Text = MediaIcons.Glyph(layer.Symbol), Foreground = Fill(layer), FontFamily = new FontFamily("Segoe UI Symbol, Segoe UI Emoji") },
                };
                break;
            default:
                content = Picture(layer, layer.AssetName is { } name ? Image(assetPath(name)) : null, layer.Kind == "video");
                break;
        }
        content.Width = w;
        content.Height = h;
        content.Opacity = layer.Opacity;
        if (layer.Shadow > 0) content.Effect = new DropShadowEffect { BlurRadius = layer.Shadow * 2, ShadowDepth = layer.Shadow / 3, Direction = 270, Opacity = 0.22 };
        if (layer.Rotation != 0) content.RenderTransform = new RotateTransform(layer.Rotation, w / 2, h / 2);
        content.IsHitTestVisible = false;
        return content;
    }

    private static FrameworkElement PathLayer(MediaLayer layer, double w, double h)
    {
        var points = new List<Point>();
        for (var i = 0; i + 1 < layer.Points.Count; i += 2) points.Add(new Point(layer.Points[i] * w, layer.Points[i + 1] * h));
        var geometry = new PathGeometry();
        if (points.Count >= 2)
        {
            var figure = new PathFigure { StartPoint = points[0] };
            foreach (var point in points.Skip(1)) figure.Segments.Add(new LineSegment(point, true));
            geometry.Figures.Add(figure);
            if (layer.Arrow)
            {
                var tip = points[^1];
                var from = points[^2];
                var angle = Math.Atan2(tip.Y - from.Y, tip.X - from.X);
                var head = Math.Max(layer.StrokeWidth, 1) * 4;
                foreach (var side in new[] { -1.0, 1.0 })
                {
                    var arm = new PathFigure { StartPoint = tip };
                    arm.Segments.Add(new LineSegment(new Point(tip.X - Math.Cos(angle + side * 0.5) * head, tip.Y - Math.Sin(angle + side * 0.5) * head), true));
                    geometry.Figures.Add(arm);
                }
            }
        }
        return new System.Windows.Shapes.Path
        {
            Data = geometry, Stroke = Fill(layer), StrokeThickness = Math.Max(layer.StrokeWidth, 1),
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round,
        };
    }

    // ponytail: even advance per character on a circular arc, as on macOS.
    private static FrameworkElement ArcText(MediaLayer layer)
    {
        var characters = layer.Text.Replace('\n', ' ').ToCharArray();
        var canvas = new Canvas { ClipToBounds = false };
        if (characters.Length == 0) return canvas;
        var total = layer.Arc * Math.PI / 180;
        var radius = characters.Length * layer.FontSize * 0.6 / total;
        var step = total / Math.Max(characters.Length - 1, 1);
        for (var i = 0; i < characters.Length; i++)
        {
            var angle = -total / 2 + step * i;
            var glyph = new TextBlock
            {
                Text = characters[i].ToString(), FontSize = Math.Max(layer.FontSize, 1), FontWeight = Weight(layer.FontWeight),
                FontFamily = Font(layer.FontDesign), Foreground = Fill(layer),
                RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = new RotateTransform(angle * 180 / Math.PI),
            };
            glyph.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            System.Windows.Controls.Canvas.SetLeft(glyph, layer.Width / 2 + radius * Math.Sin(angle) - glyph.DesiredSize.Width / 2);
            System.Windows.Controls.Canvas.SetTop(glyph, layer.Height / 2 + radius * (1 - Math.Cos(angle)) - radius * (1 - Math.Cos(total / 2)) / 2 - glyph.DesiredSize.Height / 2);
            canvas.Children.Add(glyph);
        }
        return canvas;
    }

    /// <summary>Without a file the layer still reads as part of the design: its own tint and a mark.</summary>
    private static FrameworkElement Picture(MediaLayer layer, BitmapSource? image, bool video)
    {
        var frame = new Border { CornerRadius = new CornerRadius(layer.CornerRadius), ClipToBounds = true, Background = image is null ? Fill(layer) : null };
        var grid = new Grid();
        if (image is not null) grid.Children.Add(new Image { Source = image, Stretch = Stretch.UniformToFill });
        // ponytail: videos show their tint, not a poster frame; decode one when the board needs it.
        if (image is null || video)
        {
            grid.Children.Add(new Viewbox
            {
                Width = Math.Max(Math.Min(layer.Width, layer.Height) * 0.22, 8),
                Child = new TextBlock { Text = video ? "▶" : "🖼", Foreground = Brushes.White, Opacity = 0.75 },
            });
        }
        frame.Child = grid;
        // A clip keeps the image inside rounded corners.
        frame.Loaded += (_, _) => frame.Clip = new RectangleGeometry(new Rect(0, 0, frame.ActualWidth, frame.ActualHeight), layer.CornerRadius, layer.CornerRadius);
        return frame;
    }

    /// <summary>A whole canvas at its natural size, clipped to its bounds; nested canvases drawn over it.</summary>
    public static Canvas Canvas(MediaCanvas canvas, IEnumerable<MediaCanvas> nested, Func<string, string> assetPath, bool showComments = false)
    {
        var surface = new Canvas
        {
            Width = canvas.Width, Height = canvas.Height, ClipToBounds = true,
            Background = new SolidColorBrush(Ui.Hex(canvas.BackgroundHex)), FlowDirection = FlowDirection.LeftToRight,
        };
        foreach (var layer in canvas.Layers.Where(l => !l.Hidden && (showComments || !l.Comment)))
        {
            var element = Layer(layer, assetPath);
            System.Windows.Controls.Canvas.SetLeft(element, layer.X);
            System.Windows.Controls.Canvas.SetTop(element, layer.Y);
            surface.Children.Add(element);
        }
        foreach (var child in nested)
        {
            var element = Canvas(child, [], assetPath, showComments);
            System.Windows.Controls.Canvas.SetLeft(element, child.X - canvas.X);
            System.Windows.Controls.Canvas.SetTop(element, child.Y - canvas.Y);
            surface.Children.Add(element);
        }
        return surface;
    }

    /// <summary>A canvas scaled down to fit the space it is given.</summary>
    public static FrameworkElement Preview(MediaCanvas? canvas, Func<string, string> assetPath)
    {
        if (canvas is null || canvas.Width <= 0 || canvas.Height <= 0) return new Grid();
        return new Viewbox { Child = Canvas(canvas, [], assetPath), Stretch = Stretch.Uniform, IsHitTestVisible = false };
    }

    /// <summary>PNG or JPEG of a canvas region at <paramref name="scale"/>; JPEG is flattened onto white.</summary>
    public static byte[] Export(MediaCanvas canvas, IEnumerable<MediaCanvas> nested, Func<string, string> assetPath, string format, double scale,
        BoardRect? region = null)
    {
        var surface = Canvas(canvas, nested, assetPath);
        var area = region ?? new BoardRect(0, 0, canvas.Width, canvas.Height);
        var host = new Canvas { Width = area.Width, Height = area.Height, ClipToBounds = true, Background = format == "jpeg" ? Brushes.White : Brushes.Transparent };
        System.Windows.Controls.Canvas.SetLeft(surface, -area.X);
        System.Windows.Controls.Canvas.SetTop(surface, -area.Y);
        host.Children.Add(surface);
        host.Measure(new Size(area.Width, area.Height));
        host.Arrange(new Rect(0, 0, area.Width, area.Height));
        host.UpdateLayout();
        var bitmap = new RenderTargetBitmap(Math.Max(1, (int)(area.Width * scale)), Math.Max(1, (int)(area.Height * scale)), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
        bitmap.Render(host);
        BitmapEncoder encoder = format == "jpeg" ? new JpegBitmapEncoder { QualityLevel = 92 } : new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    public static string FileName(string name)
    {
        var cleaned = string.Concat(name.Split(System.IO.Path.GetInvalidFileNameChars())).Trim();
        return cleaned.Length == 0 ? "canvas" : cleaned;
    }
}
