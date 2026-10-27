// Copyright (c) 2026 DOTS
// Cloud runs: setup, run list and live transcript (parity with the macOS Cloud dock pane).

using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using DotsHarnessCore;

namespace DotsHarness.Views;

public sealed class CloudRunsWindow : Window
{
    private static CloudRunsWindow? _open;
    private readonly AppModel _model;
    private readonly CloudRunService _cloud;
    private readonly TextBlock _repository = new() { FontSize = 16, FontWeight = FontWeights.SemiBold };
    private readonly TextBlock _notice = new() { TextWrapping = TextWrapping.Wrap, Foreground = Brushes.Gray };
    private readonly StackPanel _signIn = new() { Orientation = Orientation.Horizontal };
    private readonly Expander _setup = new();
    private readonly PasswordBox _token = new() { MinWidth = 260, Padding = new Thickness(6, 4, 6, 4) };
    private readonly TextBlock _tokenHint = new() { TextWrapping = TextWrapping.Wrap, Foreground = Brushes.Gray, Margin = new Thickness(0, 8, 0, 4) };
    private readonly TextBox _modelId = new() { MinWidth = 260, Padding = new Thickness(6, 4, 6, 4) };
    private readonly TextBox _prompt = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 70, Padding = new Thickness(6, 4, 6, 4) };
    private readonly Button _start = new() { Padding = new Thickness(14, 6, 14, 6), HorizontalAlignment = HorizontalAlignment.Left };
    private readonly ListBox _runs = new() { Height = 170 };
    private readonly TextBox _transcript = new()
    {
        IsReadOnly = true,
        TextWrapping = TextWrapping.Wrap,
        Height = 220,
        FontFamily = new FontFamily("Consolas"),
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
    };
    private readonly StackPanel _runActions = new() { Orientation = Orientation.Horizontal };
    private string? _selectedId;

    /// Shows the single Cloud runs window, creating it on first use.
    public static void ShowFor(AppModel model, Window? owner)
    {
        if (_open is { } window)
        {
            window.Activate();
            _ = window._cloud.RefreshAsync();
            return;
        }
        _open = new CloudRunsWindow(model) { Owner = owner };
        _open.Show();
    }

    private CloudRunsWindow(AppModel model)
    {
        _model = model;
        _cloud = model.Cloud;
        Title = model.L("cloud.title");
        Width = 620;
        Height = 760;
        MinWidth = 480;
        MinHeight = 520;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var refresh = MakeButton(model.L("common.refresh"), async () => await _cloud.RefreshAsync());
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        DockPanel.SetDock(refresh, Dock.Right);
        header.Children.Add(refresh);
        var titles = new StackPanel();
        titles.Children.Add(_repository);
        titles.Children.Add(new TextBlock { Text = model.L("cloud.subtitle"), Foreground = Brushes.Gray });
        header.Children.Add(titles);

        foreach (var provider in Enum.GetValues<MarketplaceProvider>())
        {
            _signIn.Children.Add(MakeButton($"{model.L("cloud.signIn")} · {provider}", () =>
            {
                try { model.MarketplaceSession.BeginOAuth(provider); }
                catch (Exception error) { _cloud.Notice = error.Message; }
            }));
        }

        _start.Content = model.L("cloud.start");
        _start.Click += async (_, _) =>
        {
            var text = _prompt.Text.Trim();
            if (text.Length == 0) return;
            if (await _cloud.StartAsync(text)) _prompt.Text = "";
        };

        _runs.SelectionChanged += async (_, _) =>
        {
            _selectedId = (_runs.SelectedItem as RunItem)?.Run.Id;
            RenderDetails();
            if (_selectedId is { } id) await _cloud.RefreshRunAsync(id);
        };

        var body = new StackPanel { Margin = new Thickness(18) };
        foreach (var child in new UIElement[]
                 {
                     header,
                     _notice,
                     _signIn,
                     BuildSetup(),
                     new TextBlock { Text = model.L("cloud.prompt"), FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 10, 0, 4) },
                     _prompt,
                     _start,
                     _runs,
                     _transcript,
                     _runActions,
                 })
        {
            if (child is FrameworkElement element && element.Margin == default) element.Margin = new Thickness(0, 0, 0, 8);
            body.Children.Add(child);
        }
        Content = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };

        _cloud.PropertyChanged += OnCloudChanged;
        _cloud.EventsChanged += OnEventsChanged;
        model.MarketplaceSession.PropertyChanged += OnCloudChanged;
        Closed += (_, _) =>
        {
            _cloud.PropertyChanged -= OnCloudChanged;
            _cloud.EventsChanged -= OnEventsChanged;
            model.MarketplaceSession.PropertyChanged -= OnCloudChanged;
            _open = null;
        };
        Render();
        _ = _cloud.RefreshAsync();
    }

    private UIElement BuildSetup()
    {
        _modelId.Text = _model.CloudModel;
        _modelId.ToolTip = _model.L("cloud.setup.model");
        _token.ToolTip = _model.L("cloud.setup.token");

        var actions = Row(
            MakeButton(_model.L("cloud.setup.install"), async () => await _cloud.InstallWorkflowAsync()),
            MakeButton(_model.L("cloud.setup.secrets"), () => CloudLinks.Open(_cloud.Repository?.ActionsSecretsUrl)));
        var token = Row(
            _token,
            MakeButton(_model.L("common.save"), () =>
            {
                _cloud.SaveGitHubToken(_token.Password);
                _token.Clear();
            }),
            MakeButton(_model.L("common.remove"), () => _cloud.SaveGitHubToken(null)));
        var model = Row(_modelId, MakeButton(_model.L("common.save"), () => _model.CloudModel = _modelId.Text));

        var content = new StackPanel { Margin = new Thickness(0, 6, 0, 0) };
        content.Children.Add(new TextBlock { Text = _model.L("cloud.setup.steps"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) });
        content.Children.Add(actions);
        content.Children.Add(_tokenHint);
        content.Children.Add(token);
        content.Children.Add(new TextBlock { Text = _model.L("cloud.setup.model"), Margin = new Thickness(0, 8, 0, 4), Foreground = Brushes.Gray });
        content.Children.Add(model);
        _setup.Header = _model.L("cloud.setup.title");
        _setup.Content = content;
        _setup.IsExpanded = _cloud.Runs.Count == 0;
        return _setup;
    }

    private void OnCloudChanged(object? sender, PropertyChangedEventArgs e) => Dispatcher.BeginInvoke(new Action(Render));

    private void OnEventsChanged(string runId)
    {
        if (runId == _selectedId) Dispatcher.BeginInvoke(new Action(RenderDetails));
    }

    private void Render()
    {
        var signedIn = _cloud.IsSignedIn;
        _repository.Text = _cloud.Repository?.FullName ?? _model.L("cloud.noRepository");
        _notice.Text = _cloud.Notice ?? (signedIn ? "" : _model.L("cloud.error.notSignedIn"));
        _notice.Visibility = _notice.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        _signIn.Visibility = signedIn ? Visibility.Collapsed : Visibility.Visible;
        _setup.Visibility = signedIn ? Visibility.Visible : Visibility.Collapsed;
        _runs.Visibility = signedIn ? Visibility.Visible : Visibility.Collapsed;
        _start.IsEnabled = signedIn && !_cloud.Busy && _cloud.Repository is not null;
        _tokenHint.Text = _model.L(_cloud.HasStoredGitHubToken ? "cloud.setup.tokenSaved" : "cloud.setup.tokenHint");

        var items = _cloud.Runs.Select(run => new RunItem(run, Describe(run))).ToList();
        _runs.ItemsSource = items;
        _runs.SelectedItem = items.FirstOrDefault(item => item.Run.Id == _selectedId);
        RenderDetails();
    }

    private void RenderDetails()
    {
        var run = _cloud.Runs.FirstOrDefault(item => item.Id == _selectedId);
        var visibility = run is null ? Visibility.Collapsed : Visibility.Visible;
        _transcript.Visibility = visibility;
        _runActions.Visibility = visibility;
        _runActions.Children.Clear();
        if (run is null) return;
        var lines = _cloud.Events(run.Id).Select(entry => entry.Text).ToList();
        if (run.Error is { Length: > 0 } error) lines.Add("✕ " + error);
        _transcript.Text = string.Join(Environment.NewLine + Environment.NewLine, lines);
        _transcript.ScrollToEnd();

        if (run.GitHubRunUrl is { } url) _runActions.Children.Add(MakeButton(_model.L("cloud.openRun"), () => CloudLinks.Open(url)));
        if (run.ResultBranch is { } branch && GitHubRepository.Parse(run.Repository) is { } repository)
            _runActions.Children.Add(MakeButton(_model.L("cloud.openBranch", branch), () => CloudLinks.Open(repository.BranchUrl(branch))));
        if (run.IsActive)
        {
            var stop = MakeButton(_model.L("common.stop"), async () => await _cloud.CancelAsync(run));
            stop.IsEnabled = !run.CancelRequested;
            _runActions.Children.Add(stop);
        }
    }

    private string Describe(CloudRun run)
    {
        var prompt = run.Prompt.ReplaceLineEndings(" ");
        if (prompt.Length > 90) prompt = prompt[..90] + "…";
        return $"{_model.L(run.StatusKey)} · {run.BaseRef} · {run.CreatedAt.ToLocalTime():g}\n{prompt}";
    }

    private static Button MakeButton(string title, Action onClick)
    {
        var button = new Button { Content = title, Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(0, 0, 8, 0) };
        button.Click += (_, _) => onClick();
        return button;
    }

    private static StackPanel Row(params UIElement[] children)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var child in children)
        {
            if (child is FrameworkElement element && element.Margin == default) element.Margin = new Thickness(0, 0, 8, 0);
            row.Children.Add(child);
        }
        return row;
    }

    private sealed record RunItem(CloudRun Run, string Label)
    {
        public override string ToString() => Label;
    }
}
