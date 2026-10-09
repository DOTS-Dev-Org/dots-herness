using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using DotsHarnessCore;

namespace DotsHarness.Views;

public sealed class RemoteWorkLocationWindow : Window
{
    private readonly AppModel _model;
    private readonly ComboBox _hosts = new() { MinWidth = 300 };
    private readonly TextBox _path = new() { MinWidth = 320, Text = "~" };
    private readonly ListBox _folders = new() { Height = 150 };
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, MinHeight = 36 };
    private readonly Button _connect = new();
    private readonly Button _removeHost = new();

    public RemoteWorkLocationWindow(AppModel model)
    {
        _model = model;
        Title = model.L("workLocation.title");
        Width = 540;
        Height = 490;
        MinWidth = 470;
        MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var body = new StackPanel { Margin = new Thickness(18), Spacing = 8 };
        body.Children.Add(new TextBlock
        {
            Text = model.L("workLocation.remoteHosts"),
            FontSize = 18,
            FontWeight = FontWeight.SemiBold,
        });
        var hostRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var add = new Button { Content = model.L("workLocation.addHost"), Padding = new Thickness(10, 5) };
        _removeHost.Content = model.L("settings.sshRemove");
        _removeHost.Padding = new Thickness(10, 5);
        add.Click += OnAddHost;
        _removeHost.Click += OnRemoveHost;
        hostRow.Children.Add(_hosts);
        hostRow.Children.Add(add);
        hostRow.Children.Add(_removeHost);
        body.Children.Add(hostRow);

        body.Children.Add(new TextBlock { Text = model.L("workLocation.remoteFolderPath") });
        var pathRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        pathRow.Children.Add(_path);
        var list = new Button { Content = model.L("workLocation.remoteFolderList"), Padding = new Thickness(10, 5) };
        list.Click += OnListFolders;
        var parent = new Button { Content = model.L("workLocation.remoteFolderUp"), Padding = new Thickness(10, 5) };
        parent.Click += OnParentFolder;
        pathRow.Children.Add(list);
        pathRow.Children.Add(parent);
        body.Children.Add(pathRow);
        _folders.SelectionChanged += (_, _) =>
        {
            if (_folders.SelectedItem is string selected) _path.Text = selected;
        };
        body.Children.Add(_folders);
        body.Children.Add(_status);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 8 };
        var local = new Button { Content = model.L("workLocation.useLocal"), Padding = new Thickness(12, 6) };
        local.Click += (_, _) => { if (_model.SetLocalWorkLocation()) Close(); };
        var cancel = new Button { Content = model.L("archive.cancel"), Padding = new Thickness(12, 6) };
        cancel.Click += (_, _) => Close();
        _connect.Content = model.L("workLocation.connect");
        _connect.Padding = new Thickness(14, 6);
        _connect.Click += OnConnect;
        actions.Children.Add(local);
        actions.Children.Add(cancel);
        actions.Children.Add(_connect);
        body.Children.Add(actions);
        Content = body;

        _hosts.ItemsSource = DisplayHostNames(model.SshHosts);
        _hosts.SelectedItem = model.SshHosts.FirstOrDefault(host => host.Alias.Equals(model.RemoteTarget?.Alias, StringComparison.OrdinalIgnoreCase))?.DisplayName
            ?? model.SshHosts.FirstOrDefault()?.DisplayName;
        _hosts.SelectionChanged += (_, _) => OnHostSelected();
        if (!RemoteSsh.IsAvailable) _status.Text = model.L("ssh.error.unavailable");
        else if (model.SshNotice is { Length: > 0 } notice) _status.Text = notice;
        OnHostSelected();
    }

    private static IReadOnlyList<string> DisplayHostNames(IReadOnlyList<SshHost> hosts) => hosts.Select(host => host.DisplayName).ToArray();

    private SshHost? SelectedHost => _hosts.SelectedItem is string display
        ? _model.SshHosts.FirstOrDefault(host => host.DisplayName == display)
        : null;

    private void OnHostSelected()
    {
        if (SelectedHost is not { } host) return;
        _path.Text = _model.RemoteTarget?.Alias == host.Alias
            ? _model.RemoteTarget.RemotePath
            : _model.RemotePathForHost(host.Alias);
        _removeHost.IsEnabled = host.ManagedByApp;
        _folders.ItemsSource = null;
    }

    private async void OnListFolders(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
    {
        if (SelectedHost is not { } host) return;
        try
        {
            _status.Text = _model.L("ssh.connecting", host.Alias);
            var directory = await RemoteSsh.ResolveDirectoryAsync(host.Alias, string.IsNullOrWhiteSpace(_path.Text) ? "~" : _path.Text.Trim());
            _path.Text = directory;
            _folders.ItemsSource = await RemoteSsh.ListDirectoriesAsync(host.Alias, directory);
            _status.Text = _folders.ItemCount == 0 ? _model.L("workLocation.remoteFolderEmpty") : "";
        }
        catch (Exception error) { _status.Text = error.Message; }
    }

    private async void OnParentFolder(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
    {
        var path = _path.Text?.Trim() ?? "";
        if (path.Length == 0 || path == "/") return;
        var parent = path.TrimEnd('/');
        var slash = parent.LastIndexOf('/');
        _path.Text = slash <= 0 ? "/" : parent[..slash];
        await ListFoldersAtAsync(_path.Text);
    }

    private async Task ListFoldersAtAsync(string? path)
    {
        if (SelectedHost is not { } host || string.IsNullOrWhiteSpace(path)) return;
        try
        {
            var resolved = await RemoteSsh.ResolveDirectoryAsync(host.Alias, path);
            _path.Text = resolved;
            _folders.ItemsSource = await RemoteSsh.ListDirectoriesAsync(host.Alias, resolved);
            _status.Text = _folders.ItemCount == 0 ? _model.L("workLocation.remoteFolderEmpty") : "";
        }
        catch (Exception error) { _status.Text = error.Message; }
    }

    private async void OnConnect(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
    {
        if (SelectedHost is not { } host)
        {
            _status.Text = _model.L("workLocation.noHosts");
            return;
        }
        if (string.IsNullOrWhiteSpace(_path.Text))
        {
            _status.Text = _model.L("ssh.chooseRemoteFolder");
            return;
        }

        _connect.IsEnabled = false;
        try
        {
            _status.Text = _model.L("ssh.connecting", host.Alias);
            var probe = await RemoteSsh.ProbeAsync(host.Alias);
            if (probe.ExitCode != 0 || probe.TimedOut)
            {
                var keys = await RemoteSsh.ScanHostKeysAsync(host);
                if (keys.Count == 0) throw new InvalidOperationException(probe.CombinedOutput.Length > 0 ? probe.CombinedOutput : _model.L("ssh.error.notReachable", host.Alias));
                var fingerprints = string.Join(Environment.NewLine, keys.Select(key => $"{key.KeyType}: {key.Fingerprint}"));
                var accepted = await ConfirmAsync(
                    _model.L("ssh.fingerprintTitle", host.Alias),
                    fingerprints + Environment.NewLine + Environment.NewLine + _model.L("ssh.fingerprintMessage"),
                    _model.L("ssh.trustAndConnect"));
                if (!accepted) return;
                _model.TrustSshHostKeys(host.Alias, keys);
                probe = await RemoteSsh.ProbeAsync(host.Alias);
                if (probe.ExitCode != 0 || probe.TimedOut)
                    throw new InvalidOperationException(probe.CombinedOutput.Length > 0 ? probe.CombinedOutput : _model.L("ssh.error.notReachable", host.Alias));
            }

            await _model.SetRemoteWorkLocationAsync(host.Alias, _path.Text.Trim());
            Close();
        }
        catch (Exception error) { _status.Text = error.Message; }
        finally { _connect.IsEnabled = true; }
    }

    private async Task<bool> ConfirmAsync(string title, string message, string confirm)
    {
        var result = false;
        var dialog = new Window
        {
            Title = title,
            Width = 480,
            MinWidth = 400,
            SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Content = null,
        };
        var body = new StackPanel { Margin = new Thickness(18), Spacing = 12 };
        body.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 8 };
        var cancel = new Button { Content = _model.L("archive.cancel"), Padding = new Thickness(12, 6) };
        cancel.Click += (_, _) => dialog.Close(false);
        var trust = new Button { Content = confirm, Padding = new Thickness(12, 6) };
        trust.Click += (_, _) => { result = true; dialog.Close(true); };
        buttons.Children.Add(cancel);
        buttons.Children.Add(trust);
        body.Children.Add(buttons);
        dialog.Content = body;
        return await dialog.ShowDialog<bool>(this) && result;
    }

    private async void OnAddHost(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
    {
        var dialog = new SshHostEntryWindow(_model);
        var added = await dialog.ShowDialog<bool>(this);
        if (!added || dialog.AddedAlias is not { } alias) return;
        _hosts.ItemsSource = DisplayHostNames(_model.SshHosts);
        _hosts.SelectedItem = _model.SshHosts.FirstOrDefault(host => host.Alias == alias)?.DisplayName;
        OnHostSelected();
    }

    private async void OnRemoveHost(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
    {
        if (SelectedHost is not { ManagedByApp: true } host) return;
        if (!await ConfirmAsync(Title ?? _model.L("workLocation.title"), $"Remove {host.Alias} from ~/.ssh/config?", _model.L("settings.sshRemove"))) return;
        try
        {
            _model.RemoveSshHost(host.Alias);
            _hosts.ItemsSource = DisplayHostNames(_model.SshHosts);
            _hosts.SelectedItem = _model.SshHosts.FirstOrDefault()?.DisplayName;
            OnHostSelected();
        }
        catch (Exception error) { _status.Text = error.Message; }
    }
}

internal sealed class SshHostEntryWindow : Window
{
    private readonly AppModel _model;
    private readonly TextBox _alias = new();
    private readonly TextBox _hostName = new();
    private readonly TextBox _user = new();
    private readonly TextBox _port = new() { Text = "22" };
    private readonly TextBlock _error = new() { TextWrapping = TextWrapping.Wrap };
    public string? AddedAlias { get; private set; }

    public SshHostEntryWindow(AppModel model)
    {
        _model = model;
        Title = model.L("workLocation.addHost");
        Width = 420;
        Height = 370;
        MinWidth = 380;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var body = new StackPanel { Margin = new Thickness(18), Spacing = 4 };
        AddField(body, model.L("settings.sshAlias"), _alias);
        AddField(body, model.L("settings.sshHostName"), _hostName);
        AddField(body, model.L("settings.sshUser"), _user);
        AddField(body, model.L("settings.sshPort"), _port);
        body.Children.Add(new TextBlock
        {
            Text = "Uses the SSH keys configured on this computer. Passwords and private keys are not stored by DotsHarness.",
            TextWrapping = TextWrapping.Wrap,
            Foreground = Brushes.Gray,
            Margin = new Thickness(0, 0, 0, 8),
        });
        body.Children.Add(_error);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 8 };
        var cancel = new Button { Content = model.L("archive.cancel"), Padding = new Thickness(12, 6) };
        cancel.Click += (_, _) => Close(false);
        var save = new Button { Content = model.L("workLocation.addHost"), Padding = new Thickness(12, 6) };
        save.Click += OnSave;
        buttons.Children.Add(cancel);
        buttons.Children.Add(save);
        body.Children.Add(buttons);
        Content = body;
    }

    private static void AddField(Panel panel, string title, TextBox input)
    {
        panel.Children.Add(new TextBlock { Text = title });
        input.Padding = new Thickness(7, 5);
        panel.Children.Add(input);
    }

    private void OnSave(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
    {
        if (!int.TryParse(_port.Text, out var port))
        {
            _error.Text = "Enter a port from 1 to 65535.";
            return;
        }
        try
        {
            AddedAlias = _alias.Text?.Trim();
            _model.AddSshHost(AddedAlias ?? "", _hostName.Text ?? "", _user.Text ?? "", port);
            Close(true);
        }
        catch (Exception error) { _error.Text = error.Message; }
    }
}
