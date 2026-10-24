using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
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
    private readonly TextBox _password = new() { PasswordChar = '●' };
    private readonly CheckBox _rememberPassword = new();
    private readonly TextBlock _rememberPasswordHint = new() { TextWrapping = TextWrapping.Wrap, Foreground = Brushes.Gray };
    private readonly StackPanel _form = new();
    private readonly TextBlock _progress = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _fingerprintTitle = new() { TextWrapping = TextWrapping.Wrap, FontWeight = FontWeight.SemiBold };
    private readonly TextBox _fingerprints = new() { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 92 };
    private readonly TextBlock _manual = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBox _publicKey = new() { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 74 };
    private readonly TextBlock _error = new() { TextWrapping = TextWrapping.Wrap, Foreground = Brushes.Firebrick };
    private readonly TextBlock _retryHint = new() { TextWrapping = TextWrapping.Wrap, Foreground = Brushes.Gray };
    private readonly TextBlock _done = new() { TextWrapping = TextWrapping.Wrap };
    private readonly Button _primary = new() { Padding = new Thickness(12, 6), IsDefault = true };
    private readonly Button _copy = new() { Padding = new Thickness(12, 6) };
    private IReadOnlyList<SshHostKey> _scannedKeys = [];
    public string? AddedAlias { get; private set; }
    private Step _step = Step.Form;

    private enum Step { Form, Scanning, Fingerprint, Enrolling, Failed, KeyRejected, Done }

    public SshHostEntryWindow(AppModel model)
    {
        _model = model;
        Title = model.L("workLocation.addHost");
        Width = 420;
        Height = 520;
        MinWidth = 380;
        MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var form = new StackPanel { Spacing = 4 };
        _form.Children.Add(new TextBlock { Text = model.L("settings.sshAlias") });
        ConfigureInput(_alias);
        _form.Children.Add(_alias);
        _form.Children.Add(new TextBlock { Text = model.L("settings.sshHostName") });
        ConfigureInput(_hostName);
        _form.Children.Add(_hostName);
        _form.Children.Add(new TextBlock { Text = model.L("settings.sshUser") });
        ConfigureInput(_user);
        _form.Children.Add(_user);
        _form.Children.Add(new TextBlock { Text = model.L("settings.sshPort") });
        ConfigureInput(_port);
        _form.Children.Add(_port);
        _form.Children.Add(new TextBlock { Text = model.L("settings.sshPassword") });
        ConfigureInput(_password);
        _form.Children.Add(_password);
        _rememberPassword.Content = model.L("settings.sshRememberPassword");
        _form.Children.Add(_rememberPassword);
        _rememberPasswordHint.Text = model.L("settings.sshRememberPassword.hint");
        _form.Children.Add(_rememberPasswordHint);
        ScrollViewer.SetVerticalScrollBarVisibility(_fingerprints, ScrollBarVisibility.Auto);
        ScrollViewer.SetVerticalScrollBarVisibility(_publicKey, ScrollBarVisibility.Auto);

        var body = new StackPanel { Margin = new Thickness(18), Spacing = 8 };
        body.Children.Add(_form);
        body.Children.Add(_progress);
        body.Children.Add(_fingerprintTitle);
        body.Children.Add(_fingerprints);
        body.Children.Add(_manual);
        body.Children.Add(_publicKey);
        body.Children.Add(_error);
        body.Children.Add(_retryHint);
        body.Children.Add(_done);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 8, Margin = new Thickness(0, 8, 0, 0) };
        var cancel = new Button { Content = model.L("archive.cancel"), Padding = new Thickness(12, 6) };
        cancel.Click += (_, _) => { if (_step is not (Step.Scanning or Step.Enrolling)) Close(false); };
        _copy.Content = model.L("ssh.copyPublicKey");
        _copy.Click += (_, _) => CopyPublicKey();
        _primary.Click += async (_, _) => await OnPrimaryAsync();
        buttons.Children.Add(cancel);
        buttons.Children.Add(_copy);
        buttons.Children.Add(_primary);
        body.Children.Add(buttons);
        Content = body;
        RenderStep();
    }

    private static void ConfigureInput(TextBox input)
    {
        input.Padding = new Thickness(7, 5);
    }

    private void RenderStep()
    {
        _form.IsVisible = _step == Step.Form;
        _progress.IsVisible = _step is Step.Scanning or Step.Enrolling;
        _progress.Text = _step == Step.Scanning ? _model.L("ssh.scanning") : _model.L("ssh.enrolling");
        _fingerprintTitle.IsVisible = _step == Step.Fingerprint;
        _fingerprints.IsVisible = _step == Step.Fingerprint;
        _manual.IsVisible = _step == Step.KeyRejected;
        _publicKey.IsVisible = _step == Step.KeyRejected;
        _copy.IsVisible = _step == Step.KeyRejected;
        _error.IsVisible = _step == Step.Failed;
        _retryHint.IsVisible = _step == Step.Failed;
        _done.IsVisible = _step == Step.Done;
        _fingerprintTitle.Text = _model.L("ssh.fingerprintTitle", _hostName.Text?.Trim() ?? "");
        _manual.Text = _model.L("ssh.installKeyManually");
        _done.Text = _model.L("ssh.enrolled.hint");
        _retryHint.Text = _model.L("ssh.retryHint");
        _primary.IsVisible = _step is not (Step.Scanning or Step.Enrolling);
        _primary.Content = _step switch
        {
            Step.Form => _model.L("ssh.continue"),
            Step.Fingerprint => _model.L("ssh.trustAndConnect"),
            Step.Failed or Step.KeyRejected => _model.L("ssh.retry"),
            Step.Done => _model.L("common.done"),
            _ => "",
        };
    }

    private async Task OnPrimaryAsync()
    {
        switch (_step)
        {
            case Step.Form:
                await ScanHostAsync();
                break;
            case Step.Fingerprint:
            case Step.Failed:
            case Step.KeyRejected:
                if (_step == Step.Failed && _scannedKeys.Count == 0) await ScanHostAsync();
                else await AddHostAsync();
                break;
            case Step.Done:
                Close(true);
                break;
        }
    }

    private async Task ScanHostAsync()
    {
        if (!int.TryParse(_port.Text, out var port) || !RemoteSsh.IsValidAlias(_alias.Text?.Trim() ?? "")
            || !RemoteSsh.IsValidHostInput(_hostName.Text?.Trim() ?? "", _user.Text?.Trim() ?? "", port))
        {
            _step = Step.Failed;
            _error.Text = _model.L("ssh.error.invalidInput");
            RenderStep();
            return;
        }
        _step = Step.Scanning;
        RenderStep();
        try
        {
            var host = new SshHost(_alias.Text!.Trim(), _hostName.Text!.Trim(), _user.Text!.Trim(), port);
            _scannedKeys = await RemoteSsh.ScanHostKeysAsync(host);
            if (_scannedKeys.Count == 0) throw new InvalidOperationException(_model.L("ssh.error.notReachable", host.Alias));
            _fingerprints.Text = string.Join(Environment.NewLine, _scannedKeys.Select(key => $"{key.KeyType}: {key.Fingerprint}"))
                + Environment.NewLine + Environment.NewLine + _model.L("ssh.fingerprintMessage");
            _step = Step.Fingerprint;
        }
        catch (Exception error)
        {
            _error.Text = error.Message;
            _step = Step.Failed;
        }
        RenderStep();
    }

    private async Task AddHostAsync()
    {
        if (_scannedKeys.Count == 0 || !int.TryParse(_port.Text, out var port)) return;
        var alias = _alias.Text?.Trim() ?? "";
        var hostName = _hostName.Text?.Trim() ?? "";
        var user = _user.Text?.Trim() ?? "";
        var manualKeyRetry = _step == Step.KeyRejected;
        var password = _password.Text ?? "";
        var rememberPassword = _rememberPassword.IsChecked == true;
        _step = Step.Enrolling;
        RenderStep();
        try
        {
            if (manualKeyRetry)
                await _model.AddSshHostUsingGeneratedKeyAsync(alias, hostName, user, port, _scannedKeys);
            else if (password.Length > 0)
                await _model.EnrollSshHostAsync(alias, hostName, user, port, password, _scannedKeys, rememberPassword: rememberPassword);
            else
                await _model.AddSshHostWithoutPasswordAsync(alias, hostName, user, port, _scannedKeys);
            AddedAlias = alias;
            _password.Text = "";
            _step = Step.Done;
        }
        catch (SshEnrollmentException error) when (error.Failure == SshEnrollmentFailure.PasswordAuthenticationDisabled)
        {
            _password.Text = "";
            _publicKey.Text = SshEnrollment.ReadPublicKey() ?? "";
            _step = Step.KeyRejected;
        }
        catch (Exception error)
        {
            _password.Text = "";
            _error.Text = LocalizedError(error, alias);
            _step = Step.Failed;
        }
        RenderStep();
    }

    private string LocalizedError(Exception error, string alias) => error is SshEnrollmentException enrollment
        ? enrollment.Failure switch
        {
            SshEnrollmentFailure.AuthenticationFailed => _model.L("ssh.error.authFailed", alias),
            SshEnrollmentFailure.HostKeyChanged => _model.L("ssh.error.hostKeyChanged", alias),
            SshEnrollmentFailure.TimedOut => _model.L("ssh.error.notReachable", alias),
            _ => error.Message,
        }
        : error.Message;

    private void CopyPublicKey()
    {
        if (_publicKey.Text?.Length > 0) NativeClipboard.SetText(_publicKey.Text);
    }
}
