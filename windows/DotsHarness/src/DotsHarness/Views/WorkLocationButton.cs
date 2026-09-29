// Copyright (c) 2026 DOTS
// "Work in" picker: this computer or a folder on an SSH host. Mirrors the macOS
// composer's work-location selector.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using DotsHarnessCore;

namespace DotsHarness.Views;

public sealed class WorkLocationButton : Button
{
    private readonly Popup _popup = new() { StaysOpen = false, AllowsTransparency = true, Placement = PlacementMode.Top };
    private AppModel? _model;
    private SSHEnrollment.HostKeyScan? _scan;
    private SSHEnrollmentFlow.Request? _pending;

    public WorkLocationButton()
    {
        Padding = new Thickness(10, 4, 10, 4);
        _popup.PlacementTarget = this;
        Click += (_, _) =>
        {
            _popup.Child = new Border
            {
                Padding = new Thickness(12),
                BorderThickness = new Thickness(1),
                BorderBrush = (System.Windows.Media.Brush)FindResource("BorderSubtle"),
                Background = (System.Windows.Media.Brush)FindResource("PanelBackground"),
                Child = BuildMenu(),
            };
            _popup.IsOpen = true;
        };
    }

    public AppModel? Model
    {
        get => _model;
        set
        {
            if (ReferenceEquals(_model, value)) return;
            if (_model is not null) _model.PropertyChanged -= OnModelChanged;
            _model = value;
            if (_model is not null) _model.PropertyChanged += OnModelChanged;
            Refresh();
        }
    }

    private static string L(string key, params object?[] args) => LocalizationService.Current.Get(key, args);

    private void OnModelChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppModel.WorkLocation) or nameof(AppModel.Language))
            Dispatcher.BeginInvoke(Refresh);
    }

    private void Refresh()
    {
        var remote = _model?.RemoteTarget;
        Content = "🖥 " + (remote is null ? L("workLocation.local") : remote.Alias);
        ToolTip = L("workLocation.title");
    }

    private UIElement BuildMenu()
    {
        var panel = new StackPanel { MinWidth = 300 };
        void Add(UIElement element, double top = 6)
        {
            if (element is FrameworkElement fe) fe.Margin = new Thickness(0, top, 0, 0);
            panel.Children.Add(element);
        }
        if (_model is null) return panel;

        Add(new TextBlock { Text = L("workLocation.title"), FontWeight = FontWeights.SemiBold }, 0);
        var local = new Button { Content = L("workLocation.local") };
        local.Click += (_, _) => { _popup.IsOpen = false; _model.SetLocalWorkLocation(); };
        Add(local);

        Add(new TextBlock { Text = L("workLocation.remoteHosts"), FontSize = 11 }, 10);
        _model.SshHosts.Reload();
        if (_model.SshHosts.Hosts.Count == 0)
            Add(new TextBlock { Text = L("workLocation.noHosts"), FontSize = 11, Opacity = 0.7 }, 2);

        var status = new TextBlock { FontSize = 11, TextWrapping = TextWrapping.Wrap };
        var folder = new TextBox { Text = "~", ToolTip = L("workLocation.remoteFolderPath") };
        foreach (var host in _model.SshHosts.Hosts)
        {
            var row = new Button { Content = $"{host.Alias}  ·  {host.DisplayDestination}", HorizontalContentAlignment = HorizontalAlignment.Left };
            var alias = host.Alias;
            row.Click += (_, _) =>
            {
                folder.Tag = alias;
                folder.Text = _model.SshHosts.RecordFor(alias).LastRemotePath ?? "~";
                status.Text = alias;
            };
            Add(row, 2);
        }

        var use = new Button { Content = L("workLocation.remoteFolderUse") };
        use.Click += async (_, _) =>
        {
            if (folder.Tag is not string alias) return;
            status.Text = L("ssh.connecting", alias);
            try
            {
                await SSHRunner.ProbeAsync(alias);
                await _model.SetRemoteWorkspaceAsync(alias, folder.Text);
                _popup.IsOpen = false;
            }
            catch (SSHException error) { status.Text = error.Message; }
        };
        Add(folder, 8);
        Add(use);
        Add(status);
        Add(BuildAddHost(status), 10);
        return panel;
    }

    private UIElement BuildAddHost(TextBlock status)
    {
        var expander = new Expander { Header = L("workLocation.addHost") };
        var form = new StackPanel();
        TextBox Field(string key, string text = "") => new() { Text = text, ToolTip = L(key), Margin = new Thickness(0, 4, 0, 0) };
        var alias = Field("ssh.field.alias");
        var host = Field("ssh.field.host");
        var user = Field("ssh.field.user");
        var port = Field("ssh.field.port", "22");
        var password = new PasswordBox { ToolTip = L("ssh.field.password"), Margin = new Thickness(0, 4, 0, 0) };
        var fingerprint = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 11, Visibility = Visibility.Collapsed };
        var connect = new Button { Content = L("ssh.trustAndConnect"), Visibility = Visibility.Collapsed };
        var next = new Button { Content = L("workLocation.addHost"), Margin = new Thickness(0, 4, 0, 0) };

        next.Click += async (_, _) =>
        {
            try
            {
                _pending = new SSHEnrollmentFlow.Request(
                    alias.Text.Trim(), host.Text.Trim(), user.Text.Trim(),
                    int.TryParse(port.Text, out var parsed) ? parsed : 22);
                status.Text = L("ssh.scanning");
                _scan = await SSHEnrollmentFlow.ScanAsync(_pending);
                fingerprint.Text = L("ssh.fingerprintTitle", _pending.HostName) + "\n"
                    + string.Join("\n", _scan.Fingerprints) + "\n" + L("ssh.fingerprintMessage");
                fingerprint.Visibility = Visibility.Visible;
                connect.Visibility = Visibility.Visible;
                status.Text = "";
            }
            catch (SSHException error) { status.Text = error.Message; }
        };
        connect.Click += async (_, _) =>
        {
            if (_pending is null || _scan is null || _model is null) return;
            try
            {
                status.Text = L("ssh.enrolling");
                await SSHEnrollmentFlow.CompleteAsync(_model.SshHosts, _pending, _scan, password.Password);
                password.Clear();
                status.Text = L("ssh.enrolled", _pending.Alias);
                _scan = null;
                connect.Visibility = Visibility.Collapsed;
                fingerprint.Visibility = Visibility.Collapsed;
            }
            catch (SSHException error) { status.Text = error.Message + "\n" + L("ssh.retryHint"); }
        };
        foreach (var element in new UIElement[] { alias, host, user, port, password, next, fingerprint, connect })
            form.Children.Add(element);
        expander.Content = form;
        return expander;
    }
}
