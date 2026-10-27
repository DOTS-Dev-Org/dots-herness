// Copyright (c) 2026 DOTS
// Chat message body. Prose wraps; fenced blocks stay unwrapped so box diagrams
// keep their columns, and each block gets a copy button in its header.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Navigation;
using System.Windows.Media;
using System.Windows.Threading;
using DotsHarnessCore;
using Path = System.Windows.Shapes.Path;

namespace DotsHarness.Views;

public sealed class MarkdownBody : StackPanel
{
    // Material "content_copy" and "check" paths, drawn as Path geometry.
    private static readonly Geometry CopyIcon = Geometry.Parse(
        "M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z");
    private static readonly Geometry CheckIcon = Geometry.Parse("M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z");

    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(MarkdownBody), new PropertyMetadata(null, (d, _) => ((MarkdownBody)d).Rebuild()));

    public static readonly DependencyProperty TextAlignmentProperty = DependencyProperty.Register(
        nameof(TextAlignment), typeof(System.Windows.TextAlignment), typeof(MarkdownBody),
        new PropertyMetadata(System.Windows.TextAlignment.Left, (d, _) => ((MarkdownBody)d).Rebuild()));

    public string? Text
    {
        get => (string?)GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }

    public System.Windows.TextAlignment TextAlignment
    {
        get => (System.Windows.TextAlignment)GetValue(TextAlignmentProperty);
        set => SetValue(TextAlignmentProperty, value);
    }

    private void Rebuild()
    {
        Children.Clear();
        foreach (var segment in MarkdownSegments.Split(Text))
        {
            if (segment.IsCode)
            {
                Children.Add(segment.Language switch
                {
                    "diagram" => Diagram(new DiagramSpec(segment.Text)),
                    "flow" => Flow(MarkdownDiagrams.Flow(segment.Text)),
                    "chart" when MarkdownDiagrams.Chart(segment.Text) is { Count: > 0 } bars => Chart(bars),
                    "table" => Table(MarkdownSegments.Table(segment.Text)),
                    _ => CodeBlock(segment.Text),
                });
                continue;
            }

            var prose = new TextBlock { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment };
            foreach (var part in MarkdownSegments.ParseInlineLinks(segment.Text))
            {
                if (part.Link is not { } uri)
                {
                    prose.Inlines.Add(new Run(part.Text));
                    continue;
                }

                var hyperlink = new Hyperlink(new Run(part.Text)) { NavigateUri = uri };
                hyperlink.RequestNavigate += (_, args) =>
                {
                    if (args.Uri.Scheme is "http" or "https")
                    {
                        if (Window.GetWindow(this) is DotsHarness.MainWindow window)
                        {
                            window.ShowBrowserPanel(args.Uri.AbsoluteUri);
                        }
                        else
                        {
                            try { Process.Start(new ProcessStartInfo(args.Uri.AbsoluteUri) { UseShellExecute = true }); }
                            catch (Exception) { }
                        }
                    }
                    args.Handled = true;
                };
                ToolTipService.SetToolTip(hyperlink, LinkPreview(part.Text, uri));
                ToolTipService.SetInitialShowDelay(hyperlink, 350);
                ToolTipService.SetShowDuration(hyperlink, 30_000);
                prose.Inlines.Add(hyperlink);
            }
            Children.Add(prose);
        }
    }

    private static UIElement LinkPreview(string title, Uri uri)
    {
        var domain = new TextBlock
        {
            Text = uri.Host,
            FontSize = 11,
            Foreground = Brushes.Gray,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var address = new TextBlock
        {
            Text = uri.AbsoluteUri,
            FontSize = 11,
            Foreground = Brushes.Gray,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 420,
        };
        return new Border
        {
            Padding = new Thickness(12, 9, 12, 9),
            CornerRadius = new CornerRadius(8),
            Background = SystemColors.ControlBrush,
            Child = new StackPanel
            {
                Children =
                {
                    new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, MaxWidth = 420 },
                    domain,
                    address,
                },
            },
        };
    }

    private UIElement CodeBlock(string source)
    {
        var icon = new Path { Data = CopyIcon, Width = 14, Height = 14, Stretch = Stretch.Uniform, Fill = Brushes.Gray };
        var copy = new Button
        {
            Content = icon,
            Padding = new Thickness(4),
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            ToolTip = LocalizationService.Current.Get("conversation.copy"),
        };
        copy.Click += (_, _) =>
        {
            TryCopy(source);
            icon.Data = CheckIcon;
            var reset = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
            reset.Tick += (_, _) =>
            {
                icon.Data = CopyIcon;
                reset.Stop();
            };
            reset.Start();
        };

        var header = new DockPanel { LastChildFill = false, Margin = new Thickness(8, 4, 8, 0) };
        DockPanel.SetDock(copy, Dock.Right);
        header.Children.Add(copy);

        var code = new TextBlock
        {
            Text = source,
            FontFamily = new FontFamily("Consolas"),
            TextWrapping = TextWrapping.NoWrap,
            Margin = new Thickness(10, 0, 10, 8),
        };

        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(24, 128, 128, 128)),
            CornerRadius = new CornerRadius(6),
            Child = new StackPanel
            {
                Children =
                {
                    header,
                    new ScrollViewer { HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, Content = code },
                },
            },
        };
    }

    private static SolidColorBrush Tint((byte R, byte G, byte B) c, byte alpha = 255) =>
        new(Color.FromArgb(alpha, c.R, c.G, c.B));

    // No foreground means the theme's text color is inherited.
    private static TextBlock Label(string text, double size, Brush? foreground = null, bool bold = false)
    {
        var label = new TextBlock
        {
            Text = text.Replace("`", ""),
            FontSize = size,
            FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
            TextWrapping = TextWrapping.Wrap,
        };
        if (foreground is not null) label.Foreground = foreground;
        return label;
    }

    // Layers top to bottom with an arrow between them; one color per group, legend at the end.
    private static UIElement Diagram(DiagramSpec spec)
    {
        var stack = new StackPanel();
        for (var i = 0; i < spec.Layers.Count; i++)
        {
            var layer = spec.Layers[i];
            if (i > 0)
                stack.Children.Add(new TextBlock { Text = "↓", Foreground = Brushes.Gray, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 2, 0, 2) });
            if (layer.Caption is { } caption)
                stack.Children.Add(Label(caption, 11, Brushes.Gray));
            var row = new System.Windows.Controls.Primitives.UniformGrid { Rows = 1, Columns = layer.Nodes.Count };
            if (layer.Nodes.Count == 1) row.MaxWidth = 360;
            foreach (var node in layer.Nodes)
            {
                var color = spec.Color(node.Group);
                var box = new StackPanel();
                var title = Label(node.Title, 13, bold: true);
                title.TextAlignment = TextAlignment.Center;
                box.Children.Add(title);
                if (node.Note.Length > 0)
                {
                    var note = Label(node.Note, 11, Tint(color));
                    note.TextAlignment = TextAlignment.Center;
                    box.Children.Add(note);
                }
                row.Children.Add(new Border
                {
                    Background = Tint(color, 36),
                    BorderBrush = Tint(color, 115),
                    BorderThickness = new Thickness(1),
                    CornerRadius = new CornerRadius(8),
                    Padding = new Thickness(10, 8, 10, 8),
                    Margin = new Thickness(4),
                    Child = box,
                });
            }
            stack.Children.Add(row);
        }
        if (spec.Legend.Count > 0)
        {
            var legend = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 0) };
            foreach (var (group, text) in spec.Legend)
            {
                var item = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 2, 8, 2) };
                item.Children.Add(new Border { Width = 12, Height = 12, CornerRadius = new CornerRadius(3), Background = Tint(spec.Color(group), 128), Margin = new Thickness(0, 0, 6, 0) });
                item.Children.Add(Label(text, 11, Brushes.Gray));
                legend.Children.Add(item);
            }
            stack.Children.Add(legend);
        }
        return new Border
        {
            BorderBrush = new SolidColorBrush(Color.FromArgb(40, 128, 128, 128)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(8),
            Child = stack,
        };
    }

    // Numbered rows with an optional colored status badge on the right.
    private static UIElement Flow(IReadOnlyList<FlowStep> steps)
    {
        var stack = new StackPanel();
        foreach (var step in steps)
        {
            var row = new DockPanel { Margin = new Thickness(0, 6, 0, 6), LastChildFill = true };
            var number = Label(step.Number.ToString(), 13, Brushes.Gray);
            number.Width = 22;
            DockPanel.SetDock(number, Dock.Left);
            row.Children.Add(number);
            if (step.Badge is { } badge)
            {
                var pill = new Border
                {
                    Background = Tint(badge.Color, 38),
                    CornerRadius = new CornerRadius(10),
                    Padding = new Thickness(8, 2, 8, 2),
                    VerticalAlignment = VerticalAlignment.Top,
                    Margin = new Thickness(8, 0, 0, 0),
                    Child = Label(badge.Label, 11, Tint(badge.Color), bold: true),
                };
                DockPanel.SetDock(pill, Dock.Right);
                row.Children.Add(pill);
            }
            var text = new StackPanel();
            text.Children.Add(Label(step.Title, 13, bold: true));
            if (step.Note.Length > 0) text.Children.Add(Label(step.Note, 13, Brushes.Gray));
            row.Children.Add(text);
            stack.Children.Add(row);
            if (!step.IsLast)
                stack.Children.Add(new Border { Height = 1, Background = new SolidColorBrush(Color.FromArgb(40, 128, 128, 128)), Margin = new Thickness(22, 0, 0, 0) });
        }
        return stack;
    }

    // Equal-width columns so long cells wrap instead of widening the bubble.
    private static UIElement Table(MarkdownTable table)
    {
        var line = new SolidColorBrush(Color.FromArgb(40, 128, 128, 128));
        var rows = new List<IReadOnlyList<string>> { table.Header };
        rows.AddRange(table.Rows);
        var grid = new Grid();
        for (var c = 0; c < table.Header.Count; c++)
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var r = 0; r < rows.Count; r++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            for (var c = 0; c < table.Header.Count; c++)
            {
                var label = Label(c < rows[r].Count ? rows[r][c].Replace("**", "") : "", 13, bold: r == 0);
                label.TextAlignment = (c < table.Alignments.Count ? table.Alignments[c] : MarkdownTableAlignment.Left) switch
                {
                    MarkdownTableAlignment.Center => TextAlignment.Center,
                    MarkdownTableAlignment.Right => TextAlignment.Right,
                    _ => TextAlignment.Left,
                };
                var cell = new Border
                {
                    Padding = new Thickness(10, 6, 10, 6),
                    BorderBrush = line,
                    BorderThickness = new Thickness(c > 0 ? 1 : 0, 0, 0, r < rows.Count - 1 ? 1 : 0),
                    Background = r == 0 ? new SolidColorBrush(Color.FromArgb(24, 128, 128, 128)) : Brushes.Transparent,
                    Child = label,
                };
                Grid.SetRow(cell, r);
                Grid.SetColumn(cell, c);
                grid.Children.Add(cell);
            }
        }
        return new Border
        {
            BorderBrush = line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            ClipToBounds = true,
            Child = grid,
        };
    }

    private static UIElement Chart(IReadOnlyList<ChartBar> bars)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(140) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        for (var i = 0; i < bars.Count; i++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var label = Label(bars[i].Label, 13);
            label.TextWrapping = TextWrapping.NoWrap;
            label.TextTrimming = TextTrimming.CharacterEllipsis;
            var bar = new ProgressBar { Maximum = 1, Value = bars[i].Fraction, Height = 6, Margin = new Thickness(8, 0, 8, 0) };
            var value = Label(bars[i].Text, 13, Brushes.Gray);
            foreach (var (cell, column) in new (FrameworkElement, int)[] { (label, 0), (bar, 1), (value, 2) })
            {
                cell.Margin = new Thickness(cell.Margin.Left, 3, cell.Margin.Right, 3);
                cell.VerticalAlignment = VerticalAlignment.Center;
                Grid.SetRow(cell, i);
                Grid.SetColumn(cell, column);
                grid.Children.Add(cell);
            }
        }
        return grid;
    }

    private static void TryCopy(string text)
    {
        try
        {
            Clipboard.SetText(text);
        }
        catch (COMException)
        {
            // The clipboard can be held by another process; the copy simply does not happen.
        }
    }
}
