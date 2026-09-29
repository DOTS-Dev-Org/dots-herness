// Copyright (c) 2026 DOTS
// Feedback capture window for a finished assistant or plan message.

using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using DotsHarnessCore;

namespace DotsHarness.Views;

public sealed class FeedbackDialog : Window
{
    private readonly AppModel _model;
    private readonly string _conversationId;
    private readonly string _messageId;
    private readonly FeedbackType _type;
    private readonly List<(string Tag, CheckBox Box)> _tags = new();
    private readonly TextBox _comment;
    private readonly TextBlock _error;

    public FeedbackDialog(AppModel model, string conversationId, ChatMessage message, FeedbackType type)
    {
        _model = model;
        _conversationId = conversationId;
        _messageId = message.Id;
        _type = type;
        Title = model.L("feedback.title");
        Width = 460;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        CanResize = false;
        FlowDirection = model.IsRightToLeft ? Avalonia.Media.FlowDirection.RightToLeft : Avalonia.Media.FlowDirection.LeftToRight;

        var existing = model.CodingBridge.FeedbackFor(message.Id, conversationId);
        var selected = existing?.FeedbackType == type ? existing.Tags : [];

        var panel = new StackPanel { Margin = new Thickness(20), Spacing = 10 };
        panel.Children.Add(new TextBlock
        {
            Text = model.L(type == FeedbackType.Good ? "feedback.good" : "feedback.bad"),
            FontSize = 16,
            FontWeight = Avalonia.Media.FontWeight.SemiBold,
        });
        var wrap = new WrapPanel();
        foreach (var tag in FeedbackTags.For(type))
        {
            var box = new CheckBox
            {
                Content = model.L(FeedbackTags.TitleKey(tag)),
                IsChecked = selected.Contains(tag),
                Margin = new Thickness(0, 0, 12, 4),
            };
            _tags.Add((tag, box));
            wrap.Children.Add(box);
        }
        panel.Children.Add(wrap);
        _comment = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = Avalonia.Media.TextWrapping.Wrap,
            MinHeight = 90,
            MaxHeight = 150,
            Watermark = model.L("feedback.commentPlaceholder"),
            Text = existing?.FeedbackType == type ? existing.UserComment : "",
        };
        panel.Children.Add(_comment);
        panel.Children.Add(new TextBlock
        {
            Text = model.L("feedback.disclaimer"),
            FontSize = 11,
            Opacity = 0.7,
            TextWrapping = Avalonia.Media.TextWrapping.Wrap,
        });
        _error = new TextBlock { Foreground = Avalonia.Media.Brushes.IndianRed, TextWrapping = Avalonia.Media.TextWrapping.Wrap, IsVisible = false };
        panel.Children.Add(_error);

        var close = new Button { Content = model.L("feedback.close"), Padding = new Thickness(12, 4) };
        close.Click += (_, _) => Close();
        var send = new Button { Content = model.L("feedback.submit"), Padding = new Thickness(12, 4), Margin = new Thickness(8, 0, 0, 0) };
        send.Click += (_, _) => Submit();
        panel.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Children = { close, send },
        });
        Content = panel;
    }

    private void Submit()
    {
        try
        {
            _model.CodingBridge.SubmitFeedback(
                _conversationId, _messageId, _type,
                _tags.Where(t => t.Box.IsChecked == true).Select(t => t.Tag).ToList(),
                _comment.Text ?? "");
            Close();
        }
        catch (FeedbackException error)
        {
            _error.Text = error.Message;
            _error.IsVisible = true;
        }
    }
}
