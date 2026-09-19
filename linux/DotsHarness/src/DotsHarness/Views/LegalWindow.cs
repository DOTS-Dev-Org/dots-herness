// Copyright (c) 2026 DOTS
// First-run legal gate and the reusable "Legal & Privacy" viewer.

using System.Diagnostics;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using DotsHarnessCore;

namespace DotsHarness.Views;

/// When <paramref name="gate"/> is true the window is a modal acceptance gate:
/// it closes with <c>true</c> only after the user accepts, and the caller must
/// shut the app down on <c>false</c>. Otherwise it is a plain viewer opened from
/// Settings.
public sealed class LegalWindow : Window
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
        MinHeight = 260,
    };
    private readonly TextBox _privacyBody = new()
    {
        IsReadOnly = true,
        TextWrapping = TextWrapping.Wrap,
        AcceptsReturn = true,
        BorderThickness = new Thickness(0),
        Background = Brushes.Transparent,
        MinHeight = 260,
    };

    public LegalWindow(AppModel model, bool gate)
        : this(model, gate, showTerms: true)
    {
    }

    public LegalWindow(AppModel model, bool gate, bool showTerms)
    {
        _model = model;
        _gate = gate;
        _showTerms = showTerms;
        Title = model.L("legal.title");
        Width = 640;
        Height = 720;
        CanResize = true;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FlowDirection = model.IsRightToLeft ? FlowDirection.RightToLeft : FlowDirection.LeftToRight;
        Content = Build();
        RenderBody();
    }

    private Control Build()
    {
        var root = new StackPanel { Spacing = 12, Margin = new Thickness(20) };

        root.Children.Add(new TextBlock
        {
            Text = _model.L("legal.gateHeading"),
            FontSize = 18,
            FontWeight = FontWeight.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        root.Children.Add(new TextBlock
        {
            Text = _model.L("legal.gateIntro"),
            TextWrapping = TextWrapping.Wrap,
            Foreground = TryBrush("TextSecondary"),
        });

        if (_model.LegalDocuments is null)
        {
            root.Children.Add(new TextBlock
            {
                Text = _model.L("legal.loadError"),
                TextWrapping = TextWrapping.Wrap,
            });
            var retry = new Button { Content = _model.L("legal.retry") };
            retry.Click += async (_, _) =>
            {
                await _model.LoadLegalAsync();
                Content = Build();
                RenderBody();
            };
            root.Children.Add(retry);
            return new ScrollViewer { Content = root };
        }

        if (_gate)
        {
            root.Children.Add(new TextBlock
            {
                Text = _model.L("legal.termsTab"),
                FontWeight = FontWeight.SemiBold,
            });
            root.Children.Add(new Border
            {
                BorderThickness = new Thickness(1),
                BorderBrush = TryBrush("BorderSubtle"),
                CornerRadius = new CornerRadius(8),
                Child = new ScrollViewer { Content = _body, MaxHeight = 320 },
            });
            AddConsentControls(root);
            root.Children.Add(new TextBlock
            {
                Text = _model.L("legal.privacyTab"),
                FontWeight = FontWeight.SemiBold,
                Margin = new Thickness(0, 8, 0, 0),
            });
            root.Children.Add(new Border
            {
                BorderThickness = new Thickness(1),
                BorderBrush = TryBrush("BorderSubtle"),
                CornerRadius = new CornerRadius(8),
                Child = new ScrollViewer { Content = _privacyBody, MaxHeight = 320 },
            });
        }
        else
        {
            var toggle = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var termsButton = new RadioButton { Content = _model.L("legal.termsTab"), IsChecked = _showTerms, GroupName = "legaldoc" };
            var privacyButton = new RadioButton { Content = _model.L("legal.privacyTab"), IsChecked = !_showTerms, GroupName = "legaldoc" };
            termsButton.IsCheckedChanged += (_, _) => { if (termsButton.IsChecked == true) { _showTerms = true; RenderBody(); } };
            privacyButton.IsCheckedChanged += (_, _) => { if (privacyButton.IsChecked == true) { _showTerms = false; RenderBody(); } };
            toggle.Children.Add(termsButton);
            toggle.Children.Add(privacyButton);
            root.Children.Add(toggle);

            root.Children.Add(new Border
            {
                BorderThickness = new Thickness(1),
                BorderBrush = TryBrush("BorderSubtle"),
                CornerRadius = new CornerRadius(8),
                Child = new ScrollViewer { Content = _body, MaxHeight = 320 },
            });

            var openWeb = new Button { Content = _model.L("legal.openWeb"), Margin = new Thickness(0, 4, 0, 0) };
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
                Foreground = TryBrush("TextSecondary"),
                Margin = new Thickness(0, 8, 0, 0),
            });
            var accept = new Button { Content = _model.L("legal.accept") };
            accept.Click += (_, _) => { _model.AcceptLegal(); Close(true); };
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
            FontWeight = FontWeight.SemiBold,
            Margin = new Thickness(0, 8, 0, 0),
        });
        foreach (var name in LegalService.ConsentKeys)
        {
            root.Children.Add(new TextBlock
            {
                Text = _model.L($"legal.consent.{name}"),
                TextWrapping = TextWrapping.Wrap,
            });
        }
    }

    private string WebLang() =>
        _model.Language == AppLanguage.System
            ? AppLanguages.EffectiveSystemLanguage().Code()
            : _model.Language.Code();

    private static IBrush? TryBrush(string key) => Application.Current?.Resources[key] as IBrush;

    private static void OpenBrowser(string url)
    {
        try { Process.Start(new ProcessStartInfo("xdg-open", url) { UseShellExecute = false }); }
        catch { /* headless or no browser */ }
    }
}
