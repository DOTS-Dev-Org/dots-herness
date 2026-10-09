// Copyright (c) 2026 DOTS

using System.IO;
using System.Windows;
using System.Windows.Controls;
using DotsHarnessCore;
using Microsoft.Win32;

namespace DotsHarness.Views;

internal sealed class MarketplacePublishWindow : Window
{
    private readonly MarketplacePublisher _publisher;
    private readonly TextBlock _folderLabel;
    private readonly TextBox _version;
    private readonly TextBox _license;
    private readonly ComboBox _visibility;
    private readonly CheckBox[] _targetChecks;
    private readonly TextBlock _status;
    private readonly TextBlock _error;
    private readonly Button _publish;
    private readonly TextBlock _irPreview;
    private readonly TextBlock _sourcePreview;
    private string? _folder;

    public MarketplacePublishWindow(MarketplacePublisher publisher)
    {
        _publisher = publisher;
        Title = "Publish native plugin";
        Width = 660;
        Height = 760;
        MinWidth = 560;
        MinHeight = 600;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.CanResize;

        _folderLabel = new TextBlock
        {
            Text = "No plugin folder selected",
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = System.Windows.Media.Brushes.Gray,
        };
        var browse = new Button { Content = "Choose folder…", Padding = new Thickness(10, 5, 10, 5), Margin = new Thickness(8, 0, 0, 0) };
        browse.Click += (_, _) => ChooseFolder();
        var folderRow = new DockPanel { Margin = new Thickness(0, 4, 0, 8) };
        DockPanel.SetDock(browse, Dock.Right);
        folderRow.Children.Add(browse);
        folderRow.Children.Add(_folderLabel);

        _version = new TextBox { Text = "1.0.0", Padding = new Thickness(7, 5, 7, 5) };
        _license = new TextBox { Text = "MIT", Padding = new Thickness(7, 5, 7, 5) };
        _visibility = new ComboBox { Padding = new Thickness(5), SelectedIndex = 0 };
        _visibility.Items.Add(new ComboBoxItem { Content = "Public — source package is listed", Tag = "public" });
        _visibility.Items.Add(new ComboBoxItem { Content = "Private — only you and CI can access source", Tag = "private" });
        _targetChecks = MarketplaceTarget.DefaultTargets.Select(target => new CheckBox
        {
            Content = target.Title,
            Tag = target,
            IsChecked = true,
            Margin = new Thickness(0, 2, 12, 2),
        }).ToArray();
        foreach (var check in _targetChecks)
        {
            check.Checked += (_, _) => UpdatePublishEnabled();
            check.Unchecked += (_, _) => UpdatePublishEnabled();
        }

        _irPreview = PreviewText();
        _sourcePreview = PreviewText();
        _status = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = System.Windows.Media.Brushes.Gray };
        _error = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = System.Windows.Media.Brushes.Firebrick };
        _publish = new Button { Content = "Publish", Padding = new Thickness(14, 7, 14, 7), IsEnabled = false, MinWidth = 100 };
        _publish.Click += async (_, _) => await PublishAsync();
        var cancel = new Button { Content = "Cancel", Padding = new Thickness(14, 7, 14, 7), MinWidth = 90 };
        cancel.Click += (_, _) => DialogResult = false;

        var body = new StackPanel { Margin = new Thickness(22) };
        body.Children.Add(new TextBlock { Text = "Publish a native plugin", FontSize = 21, FontWeight = FontWeights.SemiBold });
        body.Children.Add(new TextBlock
        {
            Text = "The folder must contain plugin.yml, plugin.ir.json, and a non-empty license file. JavaScript and declarative runtimes are not accepted; platform builds are produced by CI.",
            TextWrapping = TextWrapping.Wrap,
            Foreground = System.Windows.Media.Brushes.Gray,
            Margin = new Thickness(0, 6, 0, 12),
        });
        body.Children.Add(folderRow);
        body.Children.Add(PreviewSection("plugin.ir.json preview", _irPreview));
        body.Children.Add(PreviewSection("Native source preview", _sourcePreview));
        body.Children.Add(Field("Version (SemVer)", _version));
        body.Children.Add(Field("SPDX license (for example MIT)", _license));
        body.Children.Add(Field("Source visibility", _visibility));
        body.Children.Add(new TextBlock { Text = "Platform targets", FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 8, 0, 3) });
        var targetPanel = new WrapPanel();
        foreach (var check in _targetChecks) targetPanel.Children.Add(check);
        body.Children.Add(targetPanel);
        body.Children.Add(_status);
        body.Children.Add(_error);
        body.Children.Add(new TextBlock
        {
            Text = "After publishing, the Marketplace classifies category, scope, and risk. The plugin remains unlisted until native builds and human review are complete.",
            TextWrapping = TextWrapping.Wrap,
            Foreground = System.Windows.Media.Brushes.Gray,
            Margin = new Thickness(0, 8, 0, 10),
        });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        actions.Children.Add(cancel);
        actions.Children.Add(_publish);
        body.Children.Add(actions);

        Content = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        _publisher.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(MarketplacePublisher.IsPublishing) or nameof(MarketplacePublisher.Status))
                Dispatcher.Invoke(() =>
                {
                    _status.Text = _publisher.Status ?? string.Empty;
                    UpdatePublishEnabled();
                });
        };
    }

    private void ChooseFolder()
    {
        var picker = new OpenFolderDialog { Title = "Choose native plugin folder", Multiselect = false };
        if (picker.ShowDialog(this) != true) return;
        _folder = picker.FolderName;
        _folderLabel.Text = _folder;
        _error.Text = string.Empty;
        LoadPreviews(_folder);
        UpdatePublishEnabled();
    }

    private void LoadPreviews(string folder)
    {
        _irPreview.Text = ReadPreview(Path.Combine(folder, "plugin.ir.json"), 12_000) ?? "No plugin.ir.json preview available.";
        var sourceRoot = Path.Combine(folder, "source");
        if (!Directory.Exists(sourceRoot))
        {
            _sourcePreview.Text = "No native source preview available.";
            return;
        }

        var previews = new List<string>();
        foreach (var path in Directory.EnumerateFiles(sourceRoot, "*", SearchOption.AllDirectories)
                     .Where(path => Path.GetExtension(path).ToLowerInvariant() is ".swift" or ".cs" or ".xaml")
                     .Order(StringComparer.Ordinal).Take(2))
        {
            var relative = Path.GetRelativePath(folder, path);
            var contents = ReadPreview(path, 4_000);
            if (contents is not null) previews.Add($"// {relative}\n{contents}");
        }
        _sourcePreview.Text = previews.Count == 0 ? "No native source preview available." : string.Join("\n\n", previews);
    }

    private async Task PublishAsync()
    {
        if (string.IsNullOrWhiteSpace(_folder)) return;
        _error.Text = string.Empty;
        _publish.IsEnabled = false;
        try
        {
            var visibility = (_visibility.SelectedItem as ComboBoxItem)?.Tag as string ?? "public";
            var targets = _targetChecks.Where(check => check.IsChecked == true)
                .Select(check => (MarketplaceTarget)check.Tag!).ToArray();
            await _publisher.PublishAsync(new MarketplacePublishDraft(
                _folder,
                _license.Text,
                _version.Text,
                visibility,
                targets));
            DialogResult = true;
        }
        catch (Exception error)
        {
            _error.Text = error.Message;
            UpdatePublishEnabled();
        }
    }

    private void UpdatePublishEnabled() =>
        _publish.IsEnabled = !string.IsNullOrWhiteSpace(_folder)
            && !_publisher.IsPublishing && _targetChecks.Any(check => check.IsChecked == true);

    private static UIElement Field(string title, Control editor)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 5, 0, 3) };
        stack.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 3) });
        stack.Children.Add(editor);
        return stack;
    }

    private static Control PreviewSection(string title, TextBlock preview)
    {
        var group = new Expander { Header = title, IsExpanded = false, Margin = new Thickness(0, 2, 0, 4) };
        var scroll = new ScrollViewer { MaxHeight = 115, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        preview.FontFamily = new System.Windows.Media.FontFamily("Consolas");
        preview.FontSize = 11;
        preview.TextWrapping = TextWrapping.Wrap;
        scroll.Content = preview;
        group.Content = scroll;
        return group;
    }

    private static TextBlock PreviewText() => new() { TextWrapping = TextWrapping.Wrap };

    private static string? ReadPreview(string path, int maxChars)
    {
        try
        {
            if (!File.Exists(path)) return null;
            using var reader = new StreamReader(path);
            var buffer = new char[maxChars];
            var count = reader.ReadBlock(buffer, 0, buffer.Length);
            var text = new string(buffer, 0, count);
            return reader.Peek() >= 0 ? text + "\n…" : text;
        }
        catch { return null; }
    }
}
