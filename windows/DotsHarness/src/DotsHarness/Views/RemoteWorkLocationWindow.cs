using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using DotsHarnessCore;

namespace DotsHarness.Views;

public sealed class RemoteWorkLocationWindow : Window
{
    private readonly AppModel _model;
    private readonly ComboBox _hosts = new() { MinWidth = 300, DisplayMemberPath = nameof(SshHost.DisplayName) };
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
        ResizeMode = ResizeMode.CanResize;

        var body = new StackPanel { Margin = new Thickness(18) };
        body.Children.Add(new TextBlock
        {
            Text = model.L("workLocation.remoteHosts"),
            FontSize = 18,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 0, 10),
        });

        var hostRow = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, 12) };
        var hostActions = new StackPanel { Orientation = Orientation.Horizontal };
        var add = new Button { Content = model.L("workLocation.addHost"), Padding = new Thickness(10, 5, 10, 5), Margin = new Thickness(8, 0, 0, 0) };
        _removeHost.Content = model.L("settings.sshRemove");
        _removeHost.Padding = new Thickness(10, 5, 10, 5);
        _removeHost.Margin = new Thickness(8, 0, 0, 0);
        add.Click += OnAddHost;
        _removeHost.Click += OnRemoveHost;
        hostActions.Children.Add(add);
        hostActions.Children.Add(_removeHost);
        DockPanel.SetDock(hostActions, Dock.Right);
        hostRow.Children.Add(hostActions);
        hostRow.Children.Add(_hosts);
        body.Children.Add(hostRow);

        var pathRow = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, 8) };
        var list = new Button { Content = model.L("workLocation.remoteFolderList"), Padding = new Thickness(10, 5, 10, 5), Margin = new Thickness(8, 0, 0, 0) };
        list.Click += OnListFolders;
        DockPanel.SetDock(list, Dock.Right);
        pathRow.Children.Add(list);
        pathRow.Children.Add(new TextBlock
        {
            Text = model.L("workLocation.remoteFolderPath"),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 10, 0),
        });
        pathRow.Children.Add(_path);
        body.Children.Add(pathRow);

        var folderRow = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, 12) };
        var parent = new Button { Content = model.L("workLocation.remoteFolderUp"), Padding = new Thickness(10, 5, 10, 5), Margin = new Thickness(8, 0, 0, 0) };
        parent.Click += OnParentFolder;
        DockPanel.SetDock(parent, Dock.Right);
        folderRow.Children.Add(parent);
        _folders.MouseDoubleClick += OnFolderDoubleClick;
        folderRow.Children.Add(_folders);
        body.Children.Add(folderRow);
        body.Children.Add(_status);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        var local = new Button { Content = model.L("workLocation.useLocal"), Padding = new Thickness(12, 6, 12, 6), Margin = new Thickness(0, 0, 8, 0) };
        local.Click += (_, _) => { if (_model.SetLocalWorkLocation()) Close(); };
        var cancel = new Button { Content = model.L("archive.cancel"), Padding = new Thickness(12, 6, 12, 6), Margin = new Thickness(0, 0, 8, 0) };
        cancel.Click += (_, _) => Close();
        _connect.Content = model.L("workLocation.connect");
        _connect.Padding = new Thickness(14, 6, 14, 6);
        _connect.IsDefault = true;
        _connect.Click += OnConnect;
        actions.Children.Add(local);
        actions.Children.Add(cancel);
        actions.Children.Add(_connect);
        body.Children.Add(actions);
        Content = body;

        _hosts.SelectionChanged += (_, _) => OnHostSelected();
        RefreshHosts(model.IsRemoteWorkLocation ? model.RemoteTarget?.Alias : null);
        if (!RemoteSsh.IsAvailable) _status.Text = model.L("ssh.error.unavailable");
        else if (model.SshNotice is { Length: > 0 } notice) _status.Text = notice;
    }

    private void RefreshHosts(string? selectedAlias)
    {
        _hosts.ItemsSource = null;
        _hosts.ItemsSource = _model.SshHosts;
        var selected = _model.SshHosts.FirstOrDefault(host => host.Alias.Equals(selectedAlias, StringComparison.OrdinalIgnoreCase));
        _hosts.SelectedItem = selected ?? _model.SshHosts.FirstOrDefault();
        _removeHost.IsEnabled = (_hosts.SelectedItem as SshHost)?.ManagedByApp == true;
    }

    private void OnHostSelected()
    {
        if (_hosts.SelectedItem is not SshHost host) return;
        _path.Text = _model.RemoteTarget?.Alias == host.Alias
            ? _model.RemoteTarget.RemotePath
            : _model.RemotePathForHost(host.Alias);
        _removeHost.IsEnabled = host.ManagedByApp;
        _folders.ItemsSource = null;
    }

    private async void OnListFolders(object sender, RoutedEventArgs e)
    {
        if (_hosts.SelectedItem is not SshHost host) return;
        try
        {
            _status.Text = _model.L("ssh.connecting", host.Alias);
            var directory = await RemoteSsh.ResolveDirectoryAsync(host.Alias, string.IsNullOrWhiteSpace(_path.Text) ? "~" : _path.Text.Trim());
            _path.Text = directory;
            _folders.ItemsSource = await RemoteSsh.ListDirectoriesAsync(host.Alias, directory);
            _status.Text = _folders.Items.Count == 0 ? _model.L("workLocation.remoteFolderEmpty") : "";
        }
        catch (Exception error) { _status.Text = error.Message; }
    }

    private async void OnFolderDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (_folders.SelectedItem is not string path) return;
        _path.Text = path;
        await ListFoldersAsync(path);
    }

    private async void OnParentFolder(object sender, RoutedEventArgs e)
    {
        var path = _path.Text.Trim();
        if (string.IsNullOrWhiteSpace(path) || path == "/") return;
        var parent = path.TrimEnd('/');
        var slash = parent.LastIndexOf('/');
        _path.Text = slash <= 0 ? "/" : parent[..slash];
        await ListFoldersAsync(_path.Text);
    }

    private async Task ListFoldersAsync(string path)
    {
        if (_hosts.SelectedItem is not SshHost host) return;
        try
        {
            var resolved = await RemoteSsh.ResolveDirectoryAsync(host.Alias, path);
            _path.Text = resolved;
            _folders.ItemsSource = await RemoteSsh.ListDirectoriesAsync(host.Alias, resolved);
            _status.Text = _folders.Items.Count == 0 ? _model.L("workLocation.remoteFolderEmpty") : "";
        }
        catch (Exception error) { _status.Text = error.Message; }
    }

    private async void OnConnect(object sender, RoutedEventArgs e)
    {
        if (_hosts.SelectedItem is not SshHost host)
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
                var prompt = fingerprints + Environment.NewLine + Environment.NewLine + _model.L("ssh.fingerprintMessage");
                if (MessageBox.Show(this, prompt, _model.L("ssh.fingerprintTitle", host.Alias), MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) != MessageBoxResult.Yes)
                    return;
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

    private void OnAddHost(object sender, RoutedEventArgs e)
    {
        var dialog = new SshHostEntryWindow(_model) { Owner = this };
        if (dialog.ShowDialog() == true) RefreshHosts(dialog.AddedAlias);
    }

    private void OnRemoveHost(object sender, RoutedEventArgs e)
    {
        if (_hosts.SelectedItem is not SshHost { ManagedByApp: true } host) return;
        if (MessageBox.Show(this, $"Remove {host.Alias} from ~/.ssh/config?", Title, MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        try
        {
            _model.RemoveSshHost(host.Alias);
            RefreshHosts(null);
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
        Height = 345;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var fields = new StackPanel { Margin = new Thickness(18) };
        AddField(fields, model.L("settings.sshAlias"), _alias);
        AddField(fields, model.L("settings.sshHostName"), _hostName);
        AddField(fields, model.L("settings.sshUser"), _user);
        AddField(fields, model.L("settings.sshPort"), _port);
        fields.Children.Add(new TextBlock
        {
            Text = "Uses the SSH keys configured on this computer. Passwords and private keys are not stored by DotsHarness.",
            TextWrapping = TextWrapping.Wrap,
            Foreground = System.Windows.Media.Brushes.Gray,
            Margin = new Thickness(0, 2, 0, 8),
        });
        fields.Children.Add(_error);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = model.L("archive.cancel"), Padding = new Thickness(12, 6, 12, 6), Margin = new Thickness(0, 0, 8, 0) };
        cancel.Click += (_, _) => DialogResult = false;
        var save = new Button { Content = model.L("workLocation.addHost"), Padding = new Thickness(12, 6, 12, 6), IsDefault = true };
        save.Click += OnSave;
        buttons.Children.Add(cancel);
        buttons.Children.Add(save);
        fields.Children.Add(buttons);
        Content = fields;
    }

    private static void AddField(Panel panel, string title, TextBox input)
    {
        panel.Children.Add(new TextBlock { Text = title, Margin = new Thickness(0, 0, 0, 3) });
        input.Padding = new Thickness(7, 5, 7, 5);
        input.Margin = new Thickness(0, 0, 0, 8);
        panel.Children.Add(input);
    }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(_port.Text, out var port))
        {
            _error.Text = "Enter a port from 1 to 65535.";
            return;
        }
        try
        {
            AddedAlias = _alias.Text.Trim();
            _model.AddSshHost(AddedAlias, _hostName.Text, _user.Text, port);
            DialogResult = true;
        }
        catch (Exception error) { _error.Text = error.Message; }
    }
}
