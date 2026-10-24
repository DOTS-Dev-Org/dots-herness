// Copyright (c) 2026 DOTS

using System.ComponentModel;
using System.IO;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using DotsHarnessCore;

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
        Title = LocalizationService.Current.Get("market.publish.title");
        Width = 680;
        Height = 760;
        MinWidth = 560;
        MinHeight = 600;
        CanResize = true;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        _folderLabel = new TextBlock
        {
            Text = LocalizationService.Current.Get("market.publish.noFolder"),
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = Brushes.Gray,
        };
        var browse = new Button { Content = LocalizationService.Current.Get("market.publish.chooseFolder"), Padding = new Avalonia.Thickness(10, 5) };
        browse.Click += async (_, _) => await ChooseFolderAsync();
        var folderRow = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), Margin = new Avalonia.Thickness(0, 4, 0, 8) };
        folderRow.Children.Add(_folderLabel);
        Grid.SetColumn(browse, 1);
        folderRow.Children.Add(browse);

        _version = new TextBox { Text = "1.0.0" };
        _license = new TextBox { Text = "MIT" };
        _visibility = new ComboBox { SelectedIndex = 0 };
        _visibility.Items.Add(new ComboBoxItem { Content = LocalizationService.Current.Get("market.publish.public"), Tag = "public" });
        _visibility.Items.Add(new ComboBoxItem { Content = LocalizationService.Current.Get("market.publish.private"), Tag = "private" });
        _targetChecks = MarketplaceTarget.DefaultTargets.Select(target => new CheckBox
        {
            Content = target.Title,
            Tag = target,
            IsChecked = true,
            Margin = new Avalonia.Thickness(0, 2, 12, 2),
        }).ToArray();
        foreach (var check in _targetChecks) check.IsCheckedChanged += (_, _) => UpdatePublishEnabled();

        _irPreview = PreviewText();
        _sourcePreview = PreviewText();
        _status = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = Brushes.Gray };
        _error = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = Brushes.IndianRed };
        _publish = new Button { Content = LocalizationService.Current.Get("market.publish.submit"), Padding = new Avalonia.Thickness(14, 7), IsEnabled = false, MinWidth = 100 };
        _publish.Click += async (_, _) => await PublishAsync();
        var cancel = new Button { Content = LocalizationService.Current.Get("common.cancel"), Padding = new Avalonia.Thickness(14, 7), MinWidth = 90 };
        cancel.Click += (_, _) => Close(false);

        var body = new StackPanel { Spacing = 8, Margin = new Avalonia.Thickness(22) };
        body.Children.Add(new TextBlock { Text = LocalizationService.Current.Get("market.publish.title"), FontSize = 21, FontWeight = FontWeight.SemiBold });
        body.Children.Add(new TextBlock
        {
            Text = LocalizationService.Current.Get("market.publish.hint"),
            TextWrapping = TextWrapping.Wrap,
            Foreground = Brushes.Gray,
            Margin = new Avalonia.Thickness(0, 0, 0, 4),
        });
        body.Children.Add(folderRow);
        body.Children.Add(PreviewSection(LocalizationService.Current.Get("market.publish.irPreview"), _irPreview));
        body.Children.Add(PreviewSection(LocalizationService.Current.Get("market.publish.sourcePreview"), _sourcePreview));
        body.Children.Add(Field(LocalizationService.Current.Get("market.publish.version"), _version));
        body.Children.Add(Field(LocalizationService.Current.Get("market.publish.license"), _license));
        body.Children.Add(Field(LocalizationService.Current.Get("market.publish.visibility"), _visibility));
        body.Children.Add(new TextBlock { Text = LocalizationService.Current.Get("market.publish.targets"), FontWeight = FontWeight.SemiBold, Margin = new Avalonia.Thickness(0, 6, 0, 0) });
        var targetPanel = new WrapPanel();
        foreach (var check in _targetChecks) targetPanel.Children.Add(check);
        body.Children.Add(targetPanel);
        body.Children.Add(_status);
        body.Children.Add(_error);
        body.Children.Add(new TextBlock
        {
            Text = LocalizationService.Current.Get("market.publish.footer"),
            TextWrapping = TextWrapping.Wrap,
            Foreground = Brushes.Gray,
            Margin = new Avalonia.Thickness(0, 4, 0, 4),
        });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 8 };
        actions.Children.Add(cancel);
        actions.Children.Add(_publish);
        body.Children.Add(actions);
        Content = new ScrollViewer { Content = body, VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto };

        PropertyChangedEventHandler statusHandler = (_, e) =>
        {
            if (e.PropertyName is nameof(MarketplacePublisher.IsPublishing) or nameof(MarketplacePublisher.Status))
                Avalonia.Threading.Dispatcher.UIThread.Post(() =>
                {
                    _status.Text = _publisher.Status ?? string.Empty;
                    UpdatePublishEnabled();
                });
        };
        _publisher.PropertyChanged += statusHandler;
        Closed += (_, _) => _publisher.PropertyChanged -= statusHandler;
    }

    private async Task ChooseFolderAsync()
    {
        if (!StorageProvider.CanPickFolder)
        {
            _error.Text = LocalizationService.Current.Get("market.publish.folderPickerUnavailable");
            return;
        }

        try
        {
            var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions
            {
                Title = LocalizationService.Current.Get("market.publish.chooseFolder"),
                AllowMultiple = false,
            });
            var selected = folders.FirstOrDefault();
            if (selected is null) return;
            if (!selected.Path.IsFile)
            {
                _error.Text = LocalizationService.Current.Get("market.publish.localFolderRequired");
                return;
            }
            _folder = selected.Path.LocalPath;
            _folderLabel.Text = _folder;
            _error.Text = string.Empty;
            LoadPreviews(_folder);
            UpdatePublishEnabled();
        }
        catch (Exception error) { _error.Text = error.Message; }
    }

    private void LoadPreviews(string folder)
    {
        _irPreview.Text = ReadPreview(Path.Combine(folder, "plugin.ir.json"), 12_000) ?? string.Empty;
        var sourceRoot = Path.Combine(folder, "source");
        if (!Directory.Exists(sourceRoot))
        {
            _sourcePreview.Text = string.Empty;
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
        _sourcePreview.Text = previews.Count == 0 ? string.Empty : string.Join("\n\n", previews);
    }

    private async Task PublishAsync()
    {
        if (string.IsNullOrWhiteSpace(_folder)) return;
        _error.Text = string.Empty;
        UpdatePublishEnabled(forceDisabled: true);
        try
        {
            var visibility = (_visibility.SelectedItem as ComboBoxItem)?.Tag as string ?? "public";
            var targets = _targetChecks.Where(check => check.IsChecked == true)
                .Select(check => (MarketplaceTarget)check.Tag!).ToArray();
            await _publisher.PublishAsync(new MarketplacePublishDraft(
                _folder,
                _license.Text ?? "",
                _version.Text ?? "",
                visibility,
                targets));
            Close(true);
        }
        catch (Exception error)
        {
            _error.Text = error.Message;
            UpdatePublishEnabled();
        }
    }

    private void UpdatePublishEnabled(bool forceDisabled = false) =>
        _publish.IsEnabled = !forceDisabled && !string.IsNullOrWhiteSpace(_folder)
            && !_publisher.IsPublishing && _targetChecks.Any(check => check.IsChecked == true);

    private static Control Field(string title, Control editor)
    {
        var stack = new StackPanel { Spacing = 3, Margin = new Avalonia.Thickness(0, 3) };
        stack.Children.Add(new TextBlock { Text = title, FontWeight = FontWeight.SemiBold });
        stack.Children.Add(editor);
        return stack;
    }

    private static Control PreviewSection(string title, TextBlock preview)
    {
        var scroll = new ScrollViewer { MaxHeight = 115, VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto };
        preview.FontFamily = new FontFamily("monospace");
        preview.FontSize = 11;
        preview.TextWrapping = TextWrapping.Wrap;
        scroll.Content = preview;
        return new Expander { Header = title, IsExpanded = false, Content = scroll };
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
