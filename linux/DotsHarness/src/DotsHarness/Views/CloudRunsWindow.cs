// Copyright (c) 2026 DOTS
// Cloud runs: setup, run list and live transcript (parity with the macOS Cloud dock pane).

using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using DotsHarnessCore;

namespace DotsHarness.Views;

public sealed class CloudRunsWindow : Window
{
    private static CloudRunsWindow? _open;
    private readonly AppModel _model;
    private readonly CloudRunService _cloud;
    private readonly TextBlock _repository = new() { FontSize = 16, FontWeight = FontWeight.SemiBold };
    private readonly TextBlock _notice = new() { TextWrapping = TextWrapping.Wrap, Foreground = Brushes.Gray };
    private readonly StackPanel _signIn = new() { Spacing = 8 };
    private readonly Expander _setup = new();
    private readonly TextBox _token = new() { PasswordChar = '•', MinWidth = 260 };
    private readonly TextBlock _tokenHint = new() { TextWrapping = TextWrapping.Wrap, Foreground = Brushes.Gray };
    private readonly TextBox _modelId = new() { MinWidth = 260 };
    private readonly TextBox _prompt = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 70 };
    private readonly Button _start = new();
    private readonly ListBox _runs = new() { Height = 170 };
    private readonly TextBox _transcript = new() { IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Height = 220, FontFamily = new FontFamily("monospace") };
    private readonly StackPanel _runActions = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
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
        _open = new CloudRunsWindow(model);
        if (owner is not null) _open.Show(owner);
        else _open.Show();
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

        var refresh = new Button { Content = model.L("common.refresh"), Padding = new Thickness(10, 4) };
        refresh.Click += async (_, _) => await _cloud.RefreshAsync();
        var header = new DockPanel();
        DockPanel.SetDock(refresh, Dock.Right);
        header.Children.Add(refresh);
        header.Children.Add(new StackPanel
        {
            Children = { _repository, new TextBlock { Text = model.L("cloud.subtitle"), Foreground = Brushes.Gray } },
        });

        foreach (var provider in Enum.GetValues<MarketplaceProvider>())
        {
            var button = new Button { Content = $"{model.L("cloud.signIn")} · {provider}", Padding = new Thickness(10, 4) };
            button.Click += (_, _) =>
            {
                try { model.MarketplaceSession.BeginOAuth(provider); }
                catch (Exception error) { _cloud.Notice = error.Message; }
            };
            _signIn.Children.Add(button);
        }

        _start.Content = model.L("cloud.start");
        _start.Padding = new Thickness(14, 6);
        _start.Click += async (_, _) =>
        {
            var text = _prompt.Text?.Trim() ?? "";
            if (text.Length == 0) return;
            if (await _cloud.StartAsync(text)) _prompt.Text = "";
        };

        _runs.SelectionChanged += async (_, _) =>
        {
            _selectedId = (_runs.SelectedItem as RunItem)?.Run.Id;
            RenderDetails();
            if (_selectedId is { } id) await _cloud.RefreshRunAsync(id);
        };

        Content = new ScrollViewer
        {
            Content = new StackPanel
            {
                Margin = new Thickness(18),
                Spacing = 10,
                Children =
                {
                    header,
                    _notice,
                    _signIn,
                    BuildSetup(),
                    new TextBlock { Text = model.L("cloud.prompt"), FontWeight = FontWeight.SemiBold },
                    _prompt,
                    _start,
                    _runs,
                    _transcript,
                    _runActions,
                },
            },
        };

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

    private Control BuildSetup()
    {
        var install = new Button { Content = _model.L("cloud.setup.install"), Padding = new Thickness(10, 4) };
        install.Click += async (_, _) => await _cloud.InstallWorkflowAsync();
        var secrets = new Button { Content = _model.L("cloud.setup.secrets"), Padding = new Thickness(10, 4) };
        secrets.Click += (_, _) => CloudLinks.Open(_cloud.Repository?.ActionsSecretsUrl);
        var saveToken = new Button { Content = _model.L("common.save"), Padding = new Thickness(10, 4) };
        saveToken.Click += (_, _) =>
        {
            _cloud.SaveGitHubToken(_token.Text);
            _token.Text = "";
        };
        var removeToken = new Button { Content = _model.L("common.remove"), Padding = new Thickness(10, 4) };
        removeToken.Click += (_, _) => _cloud.SaveGitHubToken(null);
        var saveModel = new Button { Content = _model.L("common.save"), Padding = new Thickness(10, 4) };
        saveModel.Click += (_, _) => _model.CloudModel = _modelId.Text ?? "";
        _modelId.Text = _model.CloudModel;
        _modelId.Watermark = _model.L("cloud.setup.model");
        _token.Watermark = _model.L("cloud.setup.token");

        _setup.Header = _model.L("cloud.setup.title");
        _setup.Content = new StackPanel
        {
            Spacing = 8,
            Children =
            {
                new TextBlock { Text = _model.L("cloud.setup.steps"), TextWrapping = TextWrapping.Wrap },
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { install, secrets } },
                _tokenHint,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { _token, saveToken, removeToken } },
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { _modelId, saveModel } },
            },
        };
        _setup.IsExpanded = _cloud.Runs.Count == 0;
        return _setup;
    }

    private void OnCloudChanged(object? sender, PropertyChangedEventArgs e) => Dispatcher.UIThread.Post(Render);

    private void OnEventsChanged(string runId)
    {
        if (runId == _selectedId) Dispatcher.UIThread.Post(RenderDetails);
    }

    private void Render()
    {
        var signedIn = _cloud.IsSignedIn;
        _repository.Text = _cloud.Repository?.FullName ?? _model.L("cloud.noRepository");
        _notice.Text = _cloud.Notice ?? (signedIn ? "" : _model.L("cloud.error.notSignedIn"));
        _notice.IsVisible = _notice.Text.Length > 0;
        _signIn.IsVisible = !signedIn;
        _setup.IsVisible = signedIn;
        _start.IsEnabled = signedIn && !_cloud.Busy && _cloud.Repository is not null;
        _tokenHint.Text = _model.L(_cloud.HasStoredGitHubToken ? "cloud.setup.tokenSaved" : "cloud.setup.tokenHint");

        var items = _cloud.Runs.Select(run => new RunItem(run, Describe(run))).ToList();
        _runs.ItemsSource = items;
        _runs.SelectedItem = items.FirstOrDefault(item => item.Run.Id == _selectedId);
        _runs.IsVisible = signedIn;
        RenderDetails();
    }

    private void RenderDetails()
    {
        var run = _cloud.Runs.FirstOrDefault(item => item.Id == _selectedId);
        _transcript.IsVisible = run is not null;
        _runActions.IsVisible = run is not null;
        _runActions.Children.Clear();
        if (run is null) return;
        var lines = _cloud.Events(run.Id).Select(entry => entry.Text).ToList();
        if (run.Error is { Length: > 0 } error) lines.Add("✕ " + error);
        _transcript.Text = string.Join(Environment.NewLine + Environment.NewLine, lines);
        _transcript.CaretIndex = _transcript.Text.Length;

        if (run.GitHubRunUrl is { } url) _runActions.Children.Add(LinkButton(_model.L("cloud.openRun"), url));
        if (run.ResultBranch is { } branch && GitHubRepository.Parse(run.Repository) is { } repository)
            _runActions.Children.Add(LinkButton(_model.L("cloud.openBranch", branch), repository.BranchUrl(branch)));
        if (run.IsActive)
        {
            var stop = new Button { Content = _model.L("common.stop"), Padding = new Thickness(10, 4), IsEnabled = !run.CancelRequested };
            stop.Click += async (_, _) => await _cloud.CancelAsync(run);
            _runActions.Children.Add(stop);
        }
    }

    private string Describe(CloudRun run)
    {
        var prompt = run.Prompt.ReplaceLineEndings(" ");
        if (prompt.Length > 90) prompt = prompt[..90] + "…";
        return $"{_model.L(run.StatusKey)} · {run.BaseRef} · {run.CreatedAt.ToLocalTime():g}\n{prompt}";
    }

    private static Button LinkButton(string title, string url)
    {
        var button = new Button { Content = title, Padding = new Thickness(10, 4) };
        button.Click += (_, _) => CloudLinks.Open(url);
        return button;
    }

    private sealed record RunItem(CloudRun Run, string Label)
    {
        public override string ToString() => Label;
    }
}
