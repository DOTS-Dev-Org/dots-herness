// Copyright (c) 2026 DOTS

using System.Windows;
using System.Windows.Controls;
using DotsHarnessCore;

namespace DotsHarness.Views;

internal sealed class MarketplaceReportWindow : Window
{
    private static readonly (string Reason, string TitleKey)[] Reasons =
    [
        ("malware", "market.report.malware"),
        ("credential_theft", "market.report.credentialTheft"),
        ("data_exfiltration", "market.report.exfiltration"),
        ("deceptive_listing", "market.report.deceptive"),
        ("spam", "market.report.spam"),
        ("copyright", "market.report.copyright"),
        ("other", "market.report.other"),
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
        Title = LocalizationService.Current.Get("market.report.title");
        Width = 520;
        SizeToContent = SizeToContent.Height;
        MinWidth = 440;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.CanResize;

        _reason = new ComboBox { SelectedIndex = 0, Padding = new Thickness(6) };
        foreach (var reason in Reasons)
            _reason.Items.Add(new ComboBoxItem { Content = LocalizationService.Current.Get(reason.TitleKey), Tag = reason.Reason });
        _details = new TextBox
        {
            AcceptsReturn = true,
            MinHeight = 120,
            MaxLength = 5_000,
            TextWrapping = TextWrapping.Wrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        _error = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = System.Windows.Media.Brushes.Firebrick };
        _submit = new Button { Content = LocalizationService.Current.Get("market.report.submit"), Padding = new Thickness(14, 7, 14, 7), MinWidth = 120 };
        _submit.Click += async (_, _) => await SubmitAsync();
        var close = new Button { Content = LocalizationService.Current.Get("common.cancel"), Padding = new Thickness(14, 7, 14, 7), MinWidth = 90 };
        close.Click += (_, _) => DialogResult = false;

        var body = new StackPanel { Margin = new Thickness(22) };
        body.Children.Add(new TextBlock { Text = LocalizationService.Current.Get("market.report.title"), FontSize = 20, FontWeight = FontWeights.SemiBold });
        body.Children.Add(new TextBlock
        {
            Text = $"{entry.Name} · v{entry.Version}",
            FontFamily = new System.Windows.Media.FontFamily("Consolas"),
            Foreground = System.Windows.Media.Brushes.Gray,
            Margin = new Thickness(0, 6, 0, 12),
        });
        body.Children.Add(new TextBlock { Text = LocalizationService.Current.Get("market.report.reason"), FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 4) });
        body.Children.Add(_reason);
        body.Children.Add(new TextBlock { Text = LocalizationService.Current.Get("market.report.details"), FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 10, 0, 4) });
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
