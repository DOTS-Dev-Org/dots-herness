// Copyright (c) 2026 DOTS
// Feedback capture window for a finished assistant or plan message.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
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
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        FlowDirection = model.IsRightToLeft ? System.Windows.FlowDirection.RightToLeft : System.Windows.FlowDirection.LeftToRight;
        SetResourceReference(BackgroundProperty, "PanelBackground");

        var existing = model.CodingBridge.FeedbackFor(message.Id, conversationId);
        var selected = existing?.FeedbackType == type ? existing.Tags : [];

        var panel = new StackPanel { Margin = new Thickness(20) };
        panel.Children.Add(new TextBlock
        {
            Text = model.L(type == FeedbackType.Good ? "feedback.good" : "feedback.bad"),
            FontSize = 16,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 0, 10),
        });
        var wrap = new WrapPanel { Margin = new Thickness(0, 0, 0, 10) };
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
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 90,
            MaxHeight = 150,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            ToolTip = model.L("feedback.commentPlaceholder"),
            Text = existing?.FeedbackType == type ? existing.UserComment : "",
        };
        panel.Children.Add(_comment);
        panel.Children.Add(new TextBlock
        {
            Text = model.L("feedback.disclaimer"),
            FontSize = 11,
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 10, 0, 0),
        });
        _error = new TextBlock
        {
            Foreground = Brushes.IndianRed,
            TextWrapping = TextWrapping.Wrap,
            Visibility = Visibility.Collapsed,
            Margin = new Thickness(0, 8, 0, 0),
        };
        panel.Children.Add(_error);

        var close = new Button { Content = model.L("feedback.close"), Padding = new Thickness(12, 4, 12, 4), IsCancel = true };
        close.Click += (_, _) => Close();
        var send = new Button { Content = model.L("feedback.submit"), Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(8, 0, 0, 0), IsDefault = true };
        send.Click += (_, _) => Submit();
        panel.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 12, 0, 0),
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
                _comment.Text);
            Close();
        }
        catch (FeedbackException error)
        {
            _error.Text = error.Message;
            _error.Visibility = Visibility.Visible;
        }
    }
}
