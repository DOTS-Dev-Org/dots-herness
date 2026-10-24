// Copyright (c) 2026 DOTS

using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
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
        Width = 540;
        MinWidth = 440;
        SizeToContent = SizeToContent.Height;
        CanResize = true;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        _reason = new ComboBox { SelectedIndex = 0 };
        foreach (var reason in Reasons)
            _reason.Items.Add(new ComboBoxItem { Content = LocalizationService.Current.Get(reason.TitleKey), Tag = reason.Reason });
        _details = new TextBox
        {
            AcceptsReturn = true,
            MinHeight = 120,
            MaxHeight = 180,
            MaxLength = 5_000,
            TextWrapping = TextWrapping.Wrap,
        };
        _error = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = Brushes.IndianRed };
        _submit = new Button { Content = LocalizationService.Current.Get("market.report.submit"), Padding = new Avalonia.Thickness(14, 7), MinWidth = 120 };
        _submit.Click += async (_, _) => await SubmitAsync();
        var close = new Button { Content = LocalizationService.Current.Get("common.cancel"), Padding = new Avalonia.Thickness(14, 7), MinWidth = 90 };
        close.Click += (_, _) => Close(false);

        var body = new StackPanel { Spacing = 8, Margin = new Avalonia.Thickness(22) };
        body.Children.Add(new TextBlock { Text = LocalizationService.Current.Get("market.report.title"), FontSize = 20, FontWeight = FontWeight.SemiBold });
        body.Children.Add(new TextBlock
        {
            Text = $"{entry.Name} · v{entry.Version}",
            FontFamily = new FontFamily("monospace"),
            Foreground = Brushes.Gray,
            Margin = new Avalonia.Thickness(0, 0, 0, 6),
        });
        body.Children.Add(new TextBlock { Text = LocalizationService.Current.Get("market.report.reason"), FontWeight = FontWeight.SemiBold });
        body.Children.Add(_reason);
        body.Children.Add(new TextBlock { Text = LocalizationService.Current.Get("market.report.details"), FontWeight = FontWeight.SemiBold, Margin = new Avalonia.Thickness(0, 4, 0, 0) });
        body.Children.Add(_details);
        body.Children.Add(_error);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 8, Margin = new Avalonia.Thickness(0, 8, 0, 0) };
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
            await _marketplace.ReportAsync(_entry, reason, _details.Text ?? "");
            try { await _marketplace.RefreshAsync(); await _marketplace.RefreshCommunityAsync(); } catch { }
            Close(true);
        }
        catch (Exception error)
        {
            _error.Text = error.Message;
            _submit.IsEnabled = true;
        }
    }
}
