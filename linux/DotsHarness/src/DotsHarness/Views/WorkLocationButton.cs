// Copyright (c) 2026 DOTS
// "Work in" picker: this computer or a folder on an SSH host. Mirrors the macOS
// composer's work-location selector.

using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using DotsHarnessCore;

namespace DotsHarness.Views;

public sealed class WorkLocationButton : Button
{
    private readonly Flyout _flyout = new() { Placement = PlacementMode.TopEdgeAlignedLeft };
    private AppModel? _model;
    private SSHEnrollment.HostKeyScan? _scan;
    private SSHEnrollmentFlow.Request? _pending;

    public WorkLocationButton()
    {
        Padding = new Thickness(10, 4);
        Flyout = _flyout;
        _flyout.Opening += (_, _) => _flyout.Content = BuildMenu();
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
        if (e.PropertyName is nameof(AppModel.WorkLocation) or nameof(AppModel.Language) or nameof(AppModel.ActiveSandbox))
            Dispatcher.UIThread.Post(Refresh);
    }

    private void Refresh()
    {
        var remote = _model?.RemoteTarget;
        Content = _model?.ActiveSandbox is { } sandbox
            ? "🌿 " + sandbox.Name
            : "🖥 " + (remote is null ? L("workLocation.local") : remote.Alias);
        ToolTip.SetTip(this, L("workLocation.title"));
    }

    private Control BuildMenu()
    {
        var panel = new StackPanel { Spacing = 6, MinWidth = 300 };
        if (_model is null) return panel;

        panel.Children.Add(new TextBlock { Text = L("workLocation.title"), FontWeight = FontWeight.SemiBold });
        var local = new Button { Content = L("workLocation.local"), HorizontalAlignment = HorizontalAlignment.Stretch };
        local.Click += (_, _) => { _flyout.Hide(); _model.SetLocalWorkLocation(); };
        panel.Children.Add(local);

        panel.Children.Add(new TextBlock { Text = L("workLocation.remoteHosts"), FontSize = 11, Margin = new Thickness(0, 6, 0, 0) });
        _model.SshHosts.Reload();
        if (_model.SshHosts.Hosts.Count == 0)
            panel.Children.Add(new TextBlock { Text = L("workLocation.noHosts"), FontSize = 11, Opacity = 0.7 });

        var status = new TextBlock { FontSize = 11, TextWrapping = TextWrapping.Wrap };
        var folder = new TextBox { Watermark = L("workLocation.remoteFolderPath"), Text = "~" };
        foreach (var host in _model.SshHosts.Hosts)
        {
            var row = new Button
            {
                Content = $"{host.Alias}  ·  {host.DisplayDestination}",
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
            };
            var alias = host.Alias;
            row.Click += (_, _) =>
            {
                var record = _model.SshHosts.RecordFor(alias);
                folder.Tag = alias;
                folder.Text = record.LastRemotePath ?? "~";
                status.Text = alias;
            };
            panel.Children.Add(row);
        }

        var use = new Button { Content = L("workLocation.remoteFolderUse") };
        use.Click += async (_, _) =>
        {
            if (folder.Tag is not string alias) return;
            status.Text = L("ssh.connecting", alias);
            try
            {
                await SSHRunner.ProbeAsync(alias);
                await _model.SetRemoteWorkspaceAsync(alias, folder.Text ?? "~");
                _flyout.Hide();
            }
            catch (SSHException error) { status.Text = error.Message; }
        };
        panel.Children.Add(folder);
        panel.Children.Add(use);
        panel.Children.Add(status);
        panel.Children.Add(BuildSandbox(status));
        panel.Children.Add(BuildAddHost(status));
        return panel;
    }

    private void Rebuild() => _flyout.Content = BuildMenu();

    private Control BuildSandbox(TextBlock status)
    {
        var panel = new StackPanel { Spacing = 4, Margin = new Thickness(0, 6, 0, 0) };
        if (_model is null) return panel;
        panel.Children.Add(new TextBlock { Text = L("sandbox.title"), FontSize = 11 });

        Button Action(string key, Func<Task> run)
        {
            var button = new Button { Content = L(key), HorizontalAlignment = HorizontalAlignment.Stretch };
            button.Click += async (_, _) =>
            {
                await run();
                Rebuild();
            };
            return button;
        }

        if (_model.ActiveSandbox is not { } sandbox)
        {
            var name = new TextBox { Watermark = L("sandbox.namePlaceholder") };
            panel.Children.Add(name);
            panel.Children.Add(Action("sandbox.start", () => _model.EnterSandboxAsync(name.Text ?? "")));
        }
        else
        {
            panel.Children.Add(new TextBlock { Text = L("sandbox.active", sandbox.Name), FontSize = 11 });
            if (_model.SandboxConflict is { } conflict)
            {
                panel.Children.Add(new TextBlock
                {
                    Text = L("sandbox.conflictTitle", string.Join(", ", conflict.Files)),
                    TextWrapping = TextWrapping.Wrap,
                    FontSize = 11,
                });
                panel.Children.Add(Action("sandbox.prepare", _model.PrepareSandboxResolutionAsync));
                panel.Children.Add(Action("sandbox.preview", _model.PreviewSandboxResolutionAsync));
                if (_model.SandboxResolutionPreview is { } preview)
                {
                    panel.Children.Add(new TextBox
                    {
                        Text = (preview.UnresolvedFiles.Count > 0 ? "! " + string.Join(", ", preview.UnresolvedFiles) + "\n\n" : "") + preview.Diff,
                        IsReadOnly = true,
                        MaxHeight = 200,
                        FontFamily = new FontFamily("monospace"),
                        FontSize = 11,
                    });
                    var approve = Action("sandbox.apply", _model.ApplySandboxResolutionAsync);
                    approve.IsEnabled = preview.UnresolvedFiles.Count == 0;
                    panel.Children.Add(approve);
                }
                panel.Children.Add(Action("sandbox.cancel", _model.CancelSandboxResolutionAsync));
            }
            else
            {
                panel.Children.Add(Action("sandbox.merge", () => _model.ExitSandboxAsync(merge: true)));
            }
            panel.Children.Add(Action("sandbox.discard", () => _model.ExitSandboxAsync(merge: false)));
        }
        if (!string.IsNullOrEmpty(_model.SandboxNotice))
            panel.Children.Add(new TextBlock { Text = _model.SandboxNotice, TextWrapping = TextWrapping.Wrap, FontSize = 11, Opacity = 0.8 });
        return panel;
    }

    private Control BuildAddHost(TextBlock status)
    {
        var expander = new Expander { Header = L("workLocation.addHost") };
        var form = new StackPanel { Spacing = 4 };
        TextBox Field(string key, string text = "") => new() { Watermark = L(key), Text = text };
        var alias = Field("ssh.field.alias");
        var host = Field("ssh.field.host");
        var user = Field("ssh.field.user");
        var port = Field("ssh.field.port", "22");
        var password = new TextBox { Watermark = L("ssh.field.password"), PasswordChar = '•' };
        var fingerprint = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 11, IsVisible = false };
        var connect = new Button { Content = L("ssh.trustAndConnect"), IsVisible = false };
        var next = new Button { Content = L("workLocation.addHost") };

        next.Click += async (_, _) =>
        {
            try
            {
                _pending = new SSHEnrollmentFlow.Request(
                    alias.Text?.Trim() ?? "", host.Text?.Trim() ?? "", user.Text?.Trim() ?? "",
                    int.TryParse(port.Text, out var parsed) ? parsed : 22);
                status.Text = L("ssh.scanning");
                _scan = await SSHEnrollmentFlow.ScanAsync(_pending);
                fingerprint.Text = L("ssh.fingerprintTitle", _pending.HostName) + "\n"
                    + string.Join("\n", _scan.Fingerprints) + "\n" + L("ssh.fingerprintMessage");
                fingerprint.IsVisible = true;
                connect.IsVisible = true;
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
                await SSHEnrollmentFlow.CompleteAsync(_model.SshHosts, _pending, _scan, password.Text);
                password.Text = "";
                status.Text = L("ssh.enrolled", _pending.Alias);
                _scan = null;
                connect.IsVisible = false;
                fingerprint.IsVisible = false;
            }
            catch (SSHException error) { status.Text = error.Message + "\n" + L("ssh.retryHint"); }
        };
        foreach (var control in new Control[] { alias, host, user, port, password, next, fingerprint, connect })
            form.Children.Add(control);
        expander.Content = form;
        return expander;
    }
}
