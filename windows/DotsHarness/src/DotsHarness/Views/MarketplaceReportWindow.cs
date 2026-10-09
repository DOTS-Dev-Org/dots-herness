// Copyright (c) 2026 DOTS

using System.Windows;
using System.Windows.Controls;
using DotsHarnessCore;

namespace DotsHarness.Views;

internal sealed class MarketplaceReportWindow : Window
{
    private static readonly (string Reason, string Title)[] Reasons =
    [
        ("malware", "Malware or harmful behavior"),
        ("credential_theft", "Credential theft"),
        ("data_exfiltration", "Data exfiltration"),
        ("deceptive_listing", "Deceptive listing or impersonation"),
        ("spam", "Spam or empty wrapper"),
        ("copyright", "Copyright or license violation"),
        ("other", "Other"),
    ];

    private readonly NativeMarketplaceClient _marketplace;
    private readonly NativeMarketplaceEntry _entry;
    private readonly ComboBox _reason;
    private readonly TextBox _details;
    private readonly TextBlock _error;
    private readonly Button _submit;

    public MarketplaceReportWindow(NativeMarketplaceClient marketplace, NativeMarketplaceEntry entry)
    {
        _marketplace = marketplace;
        _entry = entry;
        Title = "Report Marketplace plugin";
        Width = 520;
        SizeToContent = SizeToContent.Height;
        MinWidth = 440;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.CanResize;

        _reason = new ComboBox { SelectedIndex = 0, Padding = new Thickness(6) };
        foreach (var reason in Reasons)
            _reason.Items.Add(new ComboBoxItem { Content = reason.Title, Tag = reason.Reason });
        _details = new TextBox
        {
            AcceptsReturn = true,
            MinHeight = 120,
            MaxLength = 5_000,
            TextWrapping = TextWrapping.Wrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        _error = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = System.Windows.Media.Brushes.Firebrick };
        _submit = new Button { Content = "Submit report", Padding = new Thickness(14, 7, 14, 7), MinWidth = 120 };
        _submit.Click += async (_, _) => await SubmitAsync();
        var close = new Button { Content = "Cancel", Padding = new Thickness(14, 7, 14, 7), MinWidth = 90 };
        close.Click += (_, _) => DialogResult = false;

        var body = new StackPanel { Margin = new Thickness(22) };
        body.Children.Add(new TextBlock { Text = "Report a plugin", FontSize = 20, FontWeight = FontWeights.SemiBold });
        body.Children.Add(new TextBlock
        {
            Text = $"{entry.Name} · v{entry.Version}",
            FontFamily = new System.Windows.Media.FontFamily("Consolas"),
            Foreground = System.Windows.Media.Brushes.Gray,
            Margin = new Thickness(0, 6, 0, 12),
        });
        body.Children.Add(new TextBlock { Text = "Reason", FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 4) });
        body.Children.Add(_reason);
        body.Children.Add(new TextBlock { Text = "Details (optional, up to 5,000 characters)", FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 10, 0, 4) });
        body.Children.Add(_details);
        body.Children.Add(_error);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        actions.Children.Add(close);
        actions.Children.Add(_submit);
        body.Children.Add(actions);
        Content = body;
    }

    private async Task SubmitAsync()
    {
        _error.Text = string.Empty;
        _submit.IsEnabled = false;
        try
        {
            var reason = (_reason.SelectedItem as ComboBoxItem)?.Tag as string ?? "other";
            await _marketplace.ReportAsync(_entry, reason, _details.Text);
            try { await _marketplace.RefreshAsync(); await _marketplace.RefreshCommunityAsync(); } catch { }
            DialogResult = true;
        }
        catch (Exception error)
        {
            _error.Text = error.Message;
            _submit.IsEnabled = true;
        }
    }
}
