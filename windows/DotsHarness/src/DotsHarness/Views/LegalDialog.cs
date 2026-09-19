// Copyright (c) 2026 DOTS
// First-run legal gate and the reusable "Legal & Privacy" viewer.

using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using DotsHarnessCore;

namespace DotsHarness.Views;

/// When <paramref name="gate"/> is true the dialog is a modal acceptance gate:
/// <see cref="Window.DialogResult"/> is <c>true</c> only after the user accepts.
/// Otherwise it is a plain viewer opened from Settings.
internal sealed class LegalDialog : Window
{
    private readonly AppModel _model;
    private readonly bool _gate;
    private bool _showTerms = true;
    private readonly TextBox _body = new()
    {
        IsReadOnly = true,
        TextWrapping = TextWrapping.Wrap,
        AcceptsReturn = true,
        BorderThickness = new Thickness(0),
        Background = Brushes.Transparent,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        MinHeight = 260,
        MaxHeight = 320,
    };
    private readonly TextBox _privacyBody = new()
    {
        IsReadOnly = true,
        TextWrapping = TextWrapping.Wrap,
        AcceptsReturn = true,
        BorderThickness = new Thickness(0),
        Background = Brushes.Transparent,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        MinHeight = 260,
        MaxHeight = 320,
    };

    public LegalDialog(AppModel model, bool gate)
        : this(model, gate, showTerms: true)
    {
    }

    public LegalDialog(AppModel model, bool gate, bool showTerms)
    {
        _model = model;
        _gate = gate;
        _showTerms = showTerms;
        Title = model.L("legal.title");
        Width = 640;
        Height = 720;
        FlowDirection = model.IsRightToLeft ? FlowDirection.RightToLeft : FlowDirection.LeftToRight;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = (Brush)Application.Current.FindResource("PanelBackground");
        Content = Build();
        RenderBody();
    }

    private UIElement Build()
    {
        var root = new StackPanel { Margin = new Thickness(20) };

        root.Children.Add(new TextBlock
        {
            Text = _model.L("legal.gateHeading"),
            FontSize = 18,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 8),
        });
        root.Children.Add(new TextBlock
        {
            Text = _model.L("legal.gateIntro"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        });

        if (_model.LegalDocuments is null)
        {
            root.Children.Add(new TextBlock { Text = _model.L("legal.loadError"), TextWrapping = TextWrapping.Wrap });
            var retry = new Button { Content = _model.L("legal.retry"), Margin = new Thickness(0, 8, 0, 0), Padding = new Thickness(12, 4, 12, 4), HorizontalAlignment = HorizontalAlignment.Left };
            retry.Click += async (_, _) => { await _model.LoadLegalAsync(); Content = Build(); RenderBody(); };
            root.Children.Add(retry);
            return new ScrollViewer { Content = root };
        }

        if (_gate)
        {
            root.Children.Add(new TextBlock { Text = _model.L("legal.termsTab"), FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 4) });
            root.Children.Add(new Border
            {
                BorderThickness = new Thickness(1),
                BorderBrush = TryBrush("BorderSubtle"),
                CornerRadius = new CornerRadius(8),
                Child = _body,
            });
            AddConsentControls(root);
            root.Children.Add(new TextBlock { Text = _model.L("legal.privacyTab"), FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 12, 0, 4) });
            root.Children.Add(new Border
            {
                BorderThickness = new Thickness(1),
                BorderBrush = TryBrush("BorderSubtle"),
                CornerRadius = new CornerRadius(8),
                Child = _privacyBody,
            });
        }
        else
        {
            var terms = new RadioButton { Content = _model.L("legal.termsTab"), IsChecked = _showTerms, GroupName = "legaldoc", Margin = new Thickness(0, 0, 12, 0) };
            var privacy = new RadioButton { Content = _model.L("legal.privacyTab"), IsChecked = !_showTerms, GroupName = "legaldoc" };
            terms.Checked += (_, _) => { _showTerms = true; RenderBody(); };
            privacy.Checked += (_, _) => { _showTerms = false; RenderBody(); };
            var toggle = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
            toggle.Children.Add(terms);
            toggle.Children.Add(privacy);
            root.Children.Add(toggle);

            root.Children.Add(new Border
            {
                BorderThickness = new Thickness(1),
                BorderBrush = TryBrush("BorderSubtle"),
                CornerRadius = new CornerRadius(8),
                Child = _body,
            });

            var openWeb = new Button { Content = _model.L("legal.openWeb"), Margin = new Thickness(0, 6, 0, 0), Padding = new Thickness(12, 4, 12, 4), HorizontalAlignment = HorizontalAlignment.Left };
            openWeb.Click += (_, _) => OpenBrowser(LegalService.WebUrl(WebLang(), _showTerms).ToString());
            root.Children.Add(openWeb);
            AddConsentControls(root);
        }

        if (_gate)
        {
            root.Children.Add(new TextBlock
            {
                Text = _model.L("legal.acceptHint"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 12, 0, 8),
                Foreground = TryBrush("TextSecondary"),
            });
            var accept = new Button { Content = _model.L("legal.accept"), Padding = new Thickness(14, 6, 14, 6), HorizontalAlignment = HorizontalAlignment.Left };
            accept.Click += (_, _) => { _model.AcceptLegal(); DialogResult = true; Close(); };
            root.Children.Add(accept);
        }

        return new ScrollViewer { Content = root };
    }

    private void RenderBody()
    {
        if (_model.LegalDocuments is not { } docs) return;
        _body.Text = _showTerms ? docs.TermsMarkdown : docs.PrivacyMarkdown;
        _privacyBody.Text = docs.PrivacyMarkdown;
    }

    private void AddConsentControls(StackPanel root)
    {
        root.Children.Add(new TextBlock
        {
            Text = _model.L("legal.consentHeading"),
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 12, 0, 4),
        });
        foreach (var name in LegalService.ConsentKeys)
        {
            root.Children.Add(new TextBlock
            {
                Text = _model.L($"legal.consent.{name}"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 2, 0, 2),
            });
        }
    }

    private string WebLang() =>
        _model.Language == AppLanguage.System
            ? AppLanguages.EffectiveSystemLanguage().Code()
            : _model.Language.Code();

    private static Brush? TryBrush(string key) =>
        Application.Current.TryFindResource(key) as Brush;

    private static void OpenBrowser(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch { /* no browser */ }
    }
}
