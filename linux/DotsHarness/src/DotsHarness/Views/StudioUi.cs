// Copyright (c) 2026 DOTS
// Small building blocks shared by the rail sections (Media, Bots, Tasks, Memory), and the
// Avalonia drawing of media canvases. Mirrors MediaRendering.swift on macOS and StudioUi.cs on Windows.

using System.Diagnostics;
using System.IO;
using Avalonia;
using Avalonia.Collections;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Input.Platform;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using DotsHarnessCore;

namespace DotsHarness.Views;

internal static class Ui
{
    public static IBrush Brush(string key) =>
        Application.Current is { } app && app.TryGetResource(key, app.ActualThemeVariant, out var value) && value is IBrush brush ? brush : Brushes.Gray;

    public static TextBlock Text(string text, double size = 13, bool bold = false, bool secondary = false, bool wrap = false) => new()
    {
        Text = text,
        FontSize = size,
        FontWeight = bold ? FontWeight.SemiBold : FontWeight.Normal,
        Foreground = Brush(secondary ? "TextSecondary" : "TextPrimary"),
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
        TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
    };

    public static Button Button(string content, Action click, string? tooltip = null, bool primary = false)
    {
        var button = new Button { Content = content, Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(0, 0, 6, 0) };
        if (tooltip is not null) ToolTip.SetTip(button, tooltip);
        if (primary)
        {
            button.Background = Brush("Accent");
            button.Foreground = Brushes.White;
        }
        button.Click += (_, _) => click();
        return button;
    }

    public static TextBox Field(string text, string? hint = null, bool multiline = false) => new()
    {
        Text = text,
        Watermark = hint,
        Padding = new Thickness(6, 4, 6, 4),
        Margin = new Thickness(0, 0, 0, 6),
        AcceptsReturn = multiline,
        TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
        MinHeight = multiline ? 64 : 0,
    };

    public static Border Card(Control child, double padding = 12) => new()
    {
        Child = child,
        Padding = new Thickness(padding),
        Margin = new Thickness(0, 0, 12, 12),
        CornerRadius = new CornerRadius(12),
        BorderThickness = new Thickness(1),
        BorderBrush = Brush("BorderSubtle"),
        Background = Brush("PanelBackground"),
    };

    public static StackPanel Row(params Control[] children)
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
        try { Process.Start(new ProcessStartInfo("xdg-open") { ArgumentList = { path }, UseShellExecute = false }); }
        catch (Exception) { }
    }

    /// <summary>Opens the folder holding the file; file managers differ in how they select it.</summary>
    public static void Reveal(string path) => Open(System.IO.Path.GetDirectoryName(path) ?? path);

    public static Window? OwnerOf(Control element) => TopLevel.GetTopLevel(element) as Window;

    public static IClipboard? Clipboard(Control element) => TopLevel.GetTopLevel(element)?.Clipboard;

    private static Window Dialog(string title, Control content) => new()
    {
        Content = content, Width = 400, SizeToContent = SizeToContent.Height, Title = title,
        WindowStartupLocation = WindowStartupLocation.CenterOwner, CanResize = false, Background = Brush("WindowBackground"),
    };

    /// <summary>Asks for one line of text; null when cancelled.</summary>
    public static async Task<string?> Prompt(Control owner, string title, string text = "")
    {
        var box = Field(text);
        box.Margin = new Thickness(0, 8, 0, 10);
        var panel = new StackPanel { Margin = new Thickness(14) };
        panel.Children.Add(Text(title, bold: true));
        panel.Children.Add(box);
        Window? dialog = null;
        var buttons = Row(Button(LocalizationService.Current.Get("common.save"), () => dialog!.Close(box.Text?.Trim()), primary: true),
            Button(LocalizationService.Current.Get("common.cancel"), () => dialog!.Close(null)));
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        panel.Children.Add(buttons);
        dialog = Dialog(title, panel);
        box.AttachedToVisualTree += (_, _) => { box.Focus(); box.SelectAll(); };
        return OwnerOf(owner) is { } window ? await dialog.ShowDialog<string?>(window) : null;
    }

    public static async Task<bool> Confirm(Control owner, string message, string action)
    {
        var panel = new StackPanel { Margin = new Thickness(14) };
        panel.Children.Add(Text(message, wrap: true));
        Window? dialog = null;
        var buttons = Row(Button(action, () => dialog!.Close(true), primary: true),
            Button(LocalizationService.Current.Get("common.cancel"), () => dialog!.Close(false)));
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        buttons.Margin = new Thickness(0, 12, 0, 0);
        panel.Children.Add(buttons);
        dialog = Dialog(action, panel);
        return OwnerOf(owner) is { } window && await dialog.ShowDialog<bool>(window);
    }

    public static async Task Alert(Control owner, string message)
    {
        var panel = new StackPanel { Margin = new Thickness(14) };
        panel.Children.Add(Text(message, wrap: true));
        Window? dialog = null;
        var ok = Button(LocalizationService.Current.Get("common.done"), () => dialog!.Close(), primary: true);
        ok.HorizontalAlignment = HorizontalAlignment.Right;
        ok.Margin = new Thickness(0, 12, 0, 0);
        panel.Children.Add(ok);
        dialog = Dialog("", panel);
        if (OwnerOf(owner) is { } window) await dialog.ShowDialog(window);
    }

    public static async Task<List<string>> OpenFiles(Control owner, bool media = false)
    {
        if (TopLevel.GetTopLevel(owner)?.StorageProvider is not { } storage) return [];
        var files = await storage.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            AllowMultiple = true,
            FileTypeFilter = media
                ? [new FilePickerFileType("Media") { Patterns = ["*.png", "*.jpg", "*.jpeg", "*.gif", "*.webp", "*.bmp", "*.mp4", "*.mov", "*.webm"] }]
                : null,
        });
        return files.Select(f => f.TryGetLocalPath()).OfType<string>().ToList();
    }

    public static async Task<string?> SaveFile(Control owner, string name)
    {
        if (TopLevel.GetTopLevel(owner)?.StorageProvider is not { } storage) return null;
        var file = await storage.SaveFilePickerAsync(new FilePickerSaveOptions { SuggestedFileName = name });
        return file?.TryGetLocalPath();
    }

    public static async Task<string?> OpenFolder(Control owner)
    {
        if (TopLevel.GetTopLevel(owner)?.StorageProvider is not { } storage) return null;
        var folders = await storage.OpenFolderPickerAsync(new FolderPickerOpenOptions { AllowMultiple = false });
        return folders.FirstOrDefault()?.TryGetLocalPath();
    }
}

/// <summary>Draws media canvases and layers as Avalonia controls at their natural size.</summary>
internal static class MediaRenderer
{
    private static readonly Dictionary<string, Bitmap?> Images = [];

    public static Bitmap? Image(string? path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return null;
        if (Images.TryGetValue(path, out var cached)) return cached;
        try
        {
            if (Images.Count > 64) Images.Clear();
            return Images[path] = new Bitmap(path);
        }
        catch (Exception) { return Images[path] = null; }
    }

    public static (double, double)? NaturalSize(string path) =>
        Image(path) is { } image ? (image.PixelSize.Width, image.PixelSize.Height) : null;

    private static IBrush Fill(MediaLayer layer) => layer.GradientHex is { } second
        ? new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
            EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative),
            GradientStops = { new GradientStop(Ui.Hex(layer.ColorHex), 0), new GradientStop(Ui.Hex(second), 1) },
        }
        : new SolidColorBrush(Ui.Hex(layer.ColorHex));

    private static Geometry Lines(IReadOnlyList<Point> points, bool closed)
    {
        var geometry = new StreamGeometry();
        using var context = geometry.Open();
        context.BeginFigure(points[0], closed);
        foreach (var point in points.Skip(1)) context.LineTo(point);
        context.EndFigure(closed);
        return geometry;
    }

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
        return Lines(points, true);
    }

    private static FontFamily Font(string design) => new(design switch
    {
        "serif" => "DejaVu Serif, Liberation Serif, serif",
        "mono" => "DejaVu Sans Mono, Liberation Mono, monospace",
        _ => "Inter, DejaVu Sans, sans-serif",
    });

    private static FontWeight Weight(string weight) =>
        weight == "bold" ? FontWeight.Bold : weight == "medium" ? FontWeight.Medium : FontWeight.Normal;

    private static IBrush? Stroke(MediaLayer layer) =>
        layer.StrokeHex is { } stroke && layer.StrokeWidth > 0 ? new SolidColorBrush(Ui.Hex(stroke)) : null;

    /// <summary>One layer at its natural size; the caller positions it.</summary>
    public static Control Layer(MediaLayer layer, Func<string, string> assetPath)
    {
        Control content;
        var w = Math.Max(layer.Width, 1);
        var h = Math.Max(layer.Height, 1);
        switch (layer.Kind)
        {
            case "text" when layer.Arc != 0:
                content = ArcText(layer);
                break;
            case "text":
                content = new Grid
                {
                    Children =
                    {
                        new TextBlock
                        {
                            Text = layer.Text, FontSize = Math.Max(layer.FontSize, 1), FontWeight = Weight(layer.FontWeight),
                            FontFamily = Font(layer.FontDesign), Foreground = Fill(layer), TextWrapping = TextWrapping.Wrap,
                            TextAlignment = layer.Alignment == "center" ? TextAlignment.Center : layer.Alignment == "trailing" ? TextAlignment.Right : TextAlignment.Left,
                            VerticalAlignment = VerticalAlignment.Center,
                        },
                    },
                };
                break;
            case "shape" when layer.Shape is "polygon" or "star":
                content = new Avalonia.Controls.Shapes.Path
                {
                    Data = Polygon(w, h, layer.Shape == "star"), Fill = Fill(layer), Stroke = Stroke(layer),
                    StrokeThickness = layer.StrokeWidth, StrokeJoin = PenLineJoin.Round,
                };
                break;
            case "shape" when layer.Shape == "ellipse":
                content = new Ellipse { Fill = Fill(layer), Stroke = Stroke(layer), StrokeThickness = layer.StrokeWidth };
                break;
            case "shape":
                content = new Border
                {
                    Background = Fill(layer), CornerRadius = new CornerRadius(layer.CornerRadius),
                    BorderBrush = Stroke(layer), BorderThickness = new Thickness(Stroke(layer) is null ? 0 : layer.StrokeWidth),
                };
                break;
            case "path":
                content = PathLayer(layer, w, h);
                break;
            case "icon":
                content = new Viewbox { Child = new TextBlock { Text = MediaIcons.Glyph(layer.Symbol), Foreground = Fill(layer) } };
                break;
            default:
                content = Picture(layer, layer.AssetName is { } name ? Image(assetPath(name)) : null, layer.Kind == "video");
                break;
        }
        content.Width = w;
        content.Height = h;
        content.Opacity = layer.Opacity;
        if (layer.Shadow > 0) content.Effect = new DropShadowEffect { BlurRadius = layer.Shadow * 2, OffsetX = 0, OffsetY = layer.Shadow / 3, Opacity = 0.22 };
        if (layer.Rotation != 0) content.RenderTransform = new RotateTransform(layer.Rotation);
        content.IsHitTestVisible = false;
        return content;
    }

    private static Control PathLayer(MediaLayer layer, double w, double h)
    {
        var points = new List<Point>();
        for (var i = 0; i + 1 < layer.Points.Count; i += 2) points.Add(new Point(layer.Points[i] * w, layer.Points[i + 1] * h));
        var group = new GeometryGroup();
        if (points.Count >= 2)
        {
            group.Children.Add(Lines(points, false));
            if (layer.Arrow)
            {
                var tip = points[^1];
                var from = points[^2];
                var angle = Math.Atan2(tip.Y - from.Y, tip.X - from.X);
                var head = Math.Max(layer.StrokeWidth, 1) * 4;
                foreach (var side in new[] { -1.0, 1.0 })
                    group.Children.Add(Lines([tip, new Point(tip.X - Math.Cos(angle + side * 0.5) * head, tip.Y - Math.Sin(angle + side * 0.5) * head)], false));
            }
        }
        return new Avalonia.Controls.Shapes.Path
        {
            Data = group, Stroke = Fill(layer), StrokeThickness = Math.Max(layer.StrokeWidth, 1),
            StrokeLineCap = PenLineCap.Round, StrokeJoin = PenLineJoin.Round,
        };
    }

    // ponytail: even advance per character on a circular arc, as on macOS.
    private static Control ArcText(MediaLayer layer)
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
                FontFamily = Font(layer.FontDesign), Foreground = Fill(layer), RenderTransform = new RotateTransform(angle * 180 / Math.PI),
            };
            glyph.Measure(Size.Infinity);
            Avalonia.Controls.Canvas.SetLeft(glyph, layer.Width / 2 + radius * Math.Sin(angle) - glyph.DesiredSize.Width / 2);
            Avalonia.Controls.Canvas.SetTop(glyph, layer.Height / 2 + radius * (1 - Math.Cos(angle)) - radius * (1 - Math.Cos(total / 2)) / 2 - glyph.DesiredSize.Height / 2);
            canvas.Children.Add(glyph);
        }
        return canvas;
    }

    /// <summary>Without a file the layer still reads as part of the design: its own tint and a mark.</summary>
    private static Control Picture(MediaLayer layer, Bitmap? image, bool video)
    {
        var grid = new Grid();
        if (image is not null) grid.Children.Add(new Image { Source = image, Stretch = Stretch.UniformToFill });
        // ponytail: videos show their tint, not a poster frame.
        if (image is null || video)
        {
            grid.Children.Add(new Viewbox
            {
                Width = Math.Max(Math.Min(layer.Width, layer.Height) * 0.22, 8),
                Child = new TextBlock { Text = video ? "▶" : "🖼", Foreground = Brushes.White, Opacity = 0.75 },
            });
        }
        return new Border { CornerRadius = new CornerRadius(layer.CornerRadius), ClipToBounds = true, Background = image is null ? Fill(layer) : null, Child = grid };
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
            Avalonia.Controls.Canvas.SetLeft(element, layer.X);
            Avalonia.Controls.Canvas.SetTop(element, layer.Y);
            surface.Children.Add(element);
        }
        foreach (var child in nested)
        {
            var element = Canvas(child, [], assetPath, showComments);
            Avalonia.Controls.Canvas.SetLeft(element, child.X - canvas.X);
            Avalonia.Controls.Canvas.SetTop(element, child.Y - canvas.Y);
            surface.Children.Add(element);
        }
        return surface;
    }

    /// <summary>A canvas scaled down to fit the space it is given.</summary>
    public static Control Preview(MediaCanvas? canvas, Func<string, string> assetPath)
    {
        if (canvas is null || canvas.Width <= 0 || canvas.Height <= 0) return new Grid();
        return new Viewbox { Child = Canvas(canvas, [], assetPath), Stretch = Stretch.Uniform, IsHitTestVisible = false };
    }

    /// <summary>PNG of a canvas region at <paramref name="scale"/>; <paramref name="transparent"/> drops the background.</summary>
    public static byte[] Export(MediaCanvas canvas, IEnumerable<MediaCanvas> nested, Func<string, string> assetPath, string format, double scale,
        BoardRect? region = null, bool transparent = false)
    {
        var surface = Canvas(canvas, nested, assetPath);
        if (transparent) surface.Background = Brushes.Transparent;
        var area = region ?? new BoardRect(0, 0, canvas.Width, canvas.Height);
        var host = new Canvas { Width = area.Width, Height = area.Height, ClipToBounds = true, Background = Brushes.Transparent };
        Avalonia.Controls.Canvas.SetLeft(surface, -area.X);
        Avalonia.Controls.Canvas.SetTop(surface, -area.Y);
        host.Children.Add(surface);
        host.Measure(new Size(area.Width, area.Height));
        host.Arrange(new Rect(0, 0, area.Width, area.Height));
        using var bitmap = new RenderTargetBitmap(new PixelSize(Math.Max(1, (int)(area.Width * scale)), Math.Max(1, (int)(area.Height * scale))), new Vector(96 * scale, 96 * scale));
        bitmap.Render(host);
        using var stream = new MemoryStream();
        bitmap.Save(stream);
        return stream.ToArray();
    }

    public static string FileName(string name)
    {
        var cleaned = string.Concat(name.Split(System.IO.Path.GetInvalidFileNameChars())).Trim();
        return cleaned.Length == 0 ? "canvas" : cleaned;
    }
}
