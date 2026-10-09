// Copyright (c) 2026 DOTS
// Local feedback sheet for completed assistant and plan messages.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using DotsHarnessCore;

namespace DotsHarness.Views;

internal sealed class FeedbackDialog : Window
{
    private readonly FeedbackType _type;
    private readonly Func<FeedbackSubmission, string?> _submit;
    private readonly IReadOnlyList<(FeedbackOption Option, CheckBox CheckBox)> _options;
    private readonly TextBox _comment;
    private readonly TextBlock _error;

    public FeedbackDialog(FeedbackType type, FeedbackRecord? existing, Func<FeedbackSubmission, string?> submit)
    {
        _type = type;
        _submit = submit;
        var restore = existing?.Type == type;
        var selected = restore ? existing!.Tags.ToHashSet(StringComparer.Ordinal) : new HashSet<string>(StringComparer.Ordinal);

        Title = LocalizationService.Current.Get("feedback.title");
        Width = 560;
        MinWidth = 500;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;

        var root = new StackPanel { Margin = new Thickness(20) };
        root.Children.Add(new TextBlock
        {
            Text = Title,
            FontSize = 20,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 0, 14),
        });

        var checks = new List<(FeedbackOption, CheckBox)>();
        var wrap = new WrapPanel { Orientation = Orientation.Horizontal };
        foreach (var option in FeedbackCatalog.For(type))
        {
            var checkbox = new CheckBox
            {
                Content = LocalizationService.Current.Get(option.TitleKey),
                IsChecked = selected.Contains(option.Id),
                Margin = new Thickness(0, 2, 18, 8),
                MinWidth = 220,
                VerticalContentAlignment = VerticalAlignment.Center,
            };
            checks.Add((option, checkbox));
            wrap.Children.Add(checkbox);
        }
        _options = checks;
        root.Children.Add(new ScrollViewer
        {
            Content = wrap,
            MaxHeight = 220,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Margin = new Thickness(0, 0, 0, 10),
        });

        _comment = new TextBox
        {
            Text = restore ? existing!.UserComment : "",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 92,
            MaxHeight = 150,
            MaxLength = FeedbackStore.MaxCommentCharacters,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            ToolTip = LocalizationService.Current.Get("feedback.commentPlaceholder"),
            Margin = new Thickness(0, 0, 0, 8),
        };
        root.Children.Add(_comment);
        root.Children.Add(new TextBlock
        {
            Text = LocalizationService.Current.Get("feedback.disclaimer"),
            Foreground = SystemColors.GrayTextBrush,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 6),
        });
        _error = new TextBlock { Foreground = Brushes.IndianRed, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) };
        root.Children.Add(_error);

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        var cancel = new Button
        {
            Content = LocalizationService.Current.Get("settings.cancel"),
            IsCancel = true,
            MinWidth = 86,
            Margin = new Thickness(0, 0, 8, 0),
            Padding = new Thickness(12, 6, 12, 6),
        };
        var save = new Button
        {
            Content = LocalizationService.Current.Get("feedback.submit"),
            IsDefault = true,
            MinWidth = 96,
            Padding = new Thickness(12, 6, 12, 6),
        };
        save.Click += (_, _) => Submit();
        actions.Children.Add(cancel);
        actions.Children.Add(save);
        root.Children.Add(actions);
        Content = root;
    }

    private void Submit()
    {
        var submission = new FeedbackSubmission(
            _type,
            _options.Where(item => item.CheckBox.IsChecked == true).Select(item => item.Option.Id).ToList(),
            _comment.Text.Trim());
        if (_submit(submission) is { Length: > 0 } errorKey)
        {
            _error.Text = LocalizationService.Current.Get(errorKey);
            return;
        }
        DialogResult = true;
    }
}
