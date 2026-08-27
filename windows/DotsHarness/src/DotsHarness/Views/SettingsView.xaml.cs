// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using DotsHarnessCore;
using HarnessPluginKit;
using PluginRuntime;

namespace DotsHarness.Views;

public partial class SettingsView : UserControl
{
    private readonly AppModel _model;

    public SettingsView()
    {
        InitializeComponent();
        _model = ((App)Application.Current).Model;
        DataContext = _model;
        Loaded += (_, _) => ShowGeneral();
    }

    public event EventHandler? BackRequested;

    private void OnBack(object sender, RoutedEventArgs e) => BackRequested?.Invoke(this, EventArgs.Empty);

    private void OnTab(object sender, SelectionChangedEventArgs e)
    {
        if (Tabs.SelectedItem is not ListBoxItem item) return;
        switch (item.Tag as string)
        {
            case "providers": ShowProviders(); break;
            case "custom": ShowCustom(); break;
            case "local": ShowLocal(); break;
            case "share": ShowShare(); break;
            case "tasks": ShowTasks(); break;
            case "plugins": ShowPlugins(); break;
            case "prompt": ShowPrompt(); break;
            default: ShowGeneral(); break;
        }
    }

    private void ShowGeneral()
    {
        var panel = new StackPanel();
        panel.Children.Add(Heading("General"));
        panel.Children.Add(Label("Appearance"));
        var appearance = new ComboBox { Margin = new Thickness(0, 0, 0, 12) };
        foreach (var kind in Enum.GetValues<AppModel.AppearanceKind>()) appearance.Items.Add(kind);
        appearance.SelectedItem = _model.Appearance;
        appearance.SelectionChanged += (_, _) =>
        {
            if (appearance.SelectedItem is AppModel.AppearanceKind kind)
            {
                _model.SetAppearance(kind);
                ((App)Application.Current).ApplyAppearance(kind);
            }
        };
        panel.Children.Add(appearance);
        var confirmBeforeExit = new CheckBox
        {
            Content = "Ask before closing",
            IsChecked = _model.ConfirmBeforeExit,
            Margin = new Thickness(0, 0, 0, 12),
        };
        confirmBeforeExit.Click += (_, _) => _model.SetConfirmBeforeExit(confirmBeforeExit.IsChecked == true);
        panel.Children.Add(confirmBeforeExit);
        panel.Children.Add(BoundField("Workspace", _model.WorkspacePath, _model.SetWorkspace));
        if (_model.Bridge.Connection is { } info)
        {
            panel.Children.Add(Readonly("Connected model", $"{info.Provider}/{info.Model}"));
            panel.Children.Add(Readonly("Workspace", info.Workspace));
        }
        panel.Children.Add(Readonly("Support folder", _model.Paths.Root));
        panel.Children.Add(Readonly("User plugins", _model.Paths.Plugins));
        panel.Children.Add(new TextBlock
        {
            Text = "Copyright (c) 2026 DOTS. Derived from DeepSeek Harness — Copyright (c) 2026 DeepSeek. MIT.",
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 12, 0, 12),
        });
        panel.Children.Add(new SlotHost { Slot = WellKnownSlot.SettingsSections, Registry = _model.Host.Slots });
        Body.Content = panel;
    }

    private void ShowProviders()
    {
        var router = _model.Router;
        var panel = new StackPanel();
        panel.Children.Add(HeaderRow("Providers", router.Status, () => _ = router.RefreshAsync()));
        if (router.Error is { } err) panel.Children.Add(ErrorText(err));
        panel.Children.Add(Label("Provider"));
        var picker = new ComboBox { Margin = new Thickness(0, 0, 0, 8), ItemTemplate = ProviderTemplate() };
        foreach (var kind in RouterCatalog.Providers) picker.Items.Add(kind);
        picker.SelectedItem = router.SelectedKind;
        picker.SelectionChanged += (_, _) =>
        {
            if (picker.SelectedItem is RouterProviderKind kind) router.SelectedKind = kind;
            RebuildConnect(panel, router);
        };
        panel.Children.Add(picker);
        panel.Children.Add(new TextBlock
        {
            Text = RouterCatalog.HintFor(router.SelectedKind),
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            Margin = new Thickness(0, 0, 0, 8),
        });
        var connectHost = new StackPanel { Tag = "connect" };
        panel.Children.Add(connectHost);
        FillConnect(connectHost, router);
        panel.Children.Add(Heading("Connected accounts"));
        if (router.Connections.Count == 0)
        {
            panel.Children.Add(new TextBlock
            {
                Text = "No connections yet.",
                Foreground = TryBrush("TextSecondary"),
            });
        }
        foreach (var connection in router.Connections) panel.Children.Add(ConnectionCard(connection, router));
        _ = router.RefreshAsync();
        Body.Content = panel;
    }

    private void RebuildConnect(StackPanel panel, RouterController router)
    {
        var host = panel.Children.OfType<StackPanel>().FirstOrDefault(c => Equals(c.Tag, "connect"));
        if (host is null) return;
        host.Children.Clear();
        FillConnect(host, router);
    }

    private void FillConnect(StackPanel host, RouterController router)
    {
        if (router.SelectedKind.Kind == RouterAuthKind.ApiKey && !string.IsNullOrWhiteSpace(router.SelectedKind.BaseUrl))
        {
            host.Children.Add(BoundField("Name", router.ApiKeyName, v => router.ApiKeyName = v));
            host.Children.Add(BoundField("API key", router.ApiKeyValue, v => router.ApiKeyValue = v, password: true));
        }
        else if (router.SelectedKind.Kind == RouterAuthKind.ApiKey)
        {
            host.Children.Add(new TextBlock
            {
                Text = "Add this provider through Custom API.",
                FontSize = 11,
                Foreground = TryBrush("TextSecondary"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 8),
            });
        }
        else
        {
            host.Children.Add(new TextBlock
            {
                Text = "Complete the provider sign-in in your system browser.",
                FontSize = 11,
                Foreground = TryBrush("TextSecondary"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 8),
            });
        }
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 12) };
        var canConnect = router.SelectedKind.Kind != RouterAuthKind.ApiKey || !string.IsNullOrWhiteSpace(router.SelectedKind.BaseUrl);
        var connect = new Button { Content = "Connect", Padding = new Thickness(12, 4, 12, 4), IsEnabled = router.Reachable && canConnect };
        connect.Click += (_, _) => _ = router.StartConnectAsync();
        row.Children.Add(connect);
        if (router.Flow is not RouterFlow.Idle)
        {
            var cancel = new Button { Content = "Cancel", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 4, 12, 4) };
            cancel.Click += (_, _) => router.CancelFlow();
            row.Children.Add(cancel);
        }
        host.Children.Add(row);
        switch (router.Flow)
        {
            case RouterFlow.Browser browser:
                host.Children.Add(Label("Browser login"));
                host.Children.Add(Readonly("Auth URL", browser.AuthUrl));
                host.Children.Add(BoundField("Paste callback URL", router.CallbackPaste, v => router.CallbackPaste = v));
                var finish = new Button { Content = "Finish login", Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(0, 0, 0, 12) };
                finish.Click += (_, _) => _ = router.FinishBrowserAsync();
                host.Children.Add(finish);
                break;
            case RouterFlow.Device device:
                host.Children.Add(Label("Device login"));
                if (!string.IsNullOrEmpty(device.UserCode))
                {
                    host.Children.Add(new TextBlock { Text = device.UserCode, FontSize = 20, FontFamily = new FontFamily("Consolas"), Margin = new Thickness(0, 0, 0, 6) });
                }
                host.Children.Add(Readonly("Verify", device.VerificationUrl));
                host.Children.Add(new TextBlock { Text = "Waiting for authorization…", Foreground = TryBrush("TextSecondary") });
                break;
        }
    }

    private UIElement ConnectionCard(RouterConnection connection, RouterController router)
    {
        var card = new Border
        {
            BorderBrush = TryBrush("BorderSubtle"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(12),
            Margin = new Thickness(0, 0, 0, 8),
            Background = TryBrush("PanelBackground"),
        };
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock { Text = connection.Name, FontWeight = FontWeights.SemiBold });
        var provider = RouterCatalog.KindFor(connection.Provider);
        var providerLine = new StackPanel { Orientation = Orientation.Horizontal };
        providerLine.Children.Add(ProviderBadge(provider?.Name ?? RouterCatalog.LabelFor(connection.Provider), provider?.LogoKey ?? "generic"));
        providerLine.Children.Add(new TextBlock { Text = RouterCatalog.LabelFor(connection.Provider), FontSize = 11, Foreground = TryBrush("TextSecondary"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) });
        stack.Children.Add(providerLine);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        var active = new CheckBox { Content = "Active", IsChecked = connection.Active, VerticalAlignment = VerticalAlignment.Center };
        active.Click += (_, _) => _ = router.ToggleAsync(connection);
        row.Children.Add(active);
        var test = new Button { Content = "Test", Margin = new Thickness(12, 0, 0, 0), Padding = new Thickness(10, 2, 10, 2) };
        test.Click += (_, _) => _ = router.TestAsync(connection);
        row.Children.Add(test);
        var remove = new Button { Content = "Remove", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 2, 10, 2) };
        remove.Click += (_, _) => _ = router.RemoveAsync(connection);
        row.Children.Add(remove);
        stack.Children.Add(row);
        if (!string.IsNullOrEmpty(connection.Error)) stack.Children.Add(ErrorText(connection.Error));
        card.Child = stack;
        return card;
    }

    private void ShowCustom()
    {
        var router = _model.Router;
        var panel = new StackPanel();
        panel.Children.Add(Heading("Add a custom endpoint"));
        panel.Children.Add(new TextBlock
        {
            Text = "Ollama, LM Studio, vLLM, llama.cpp, or any OpenAI/Anthropic-compatible server.",
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 8),
        });
        panel.Children.Add(BoundField("Name", router.CustomName, v => router.CustomName = v));
        panel.Children.Add(BoundField("Prefix (model id, e.g. local)", router.CustomPrefix, v => router.CustomPrefix = v));
        panel.Children.Add(BoundField("Base URL", router.CustomBaseUrl, v => router.CustomBaseUrl = v));
        panel.Children.Add(BoundField("API key (optional for local)", router.CustomApiKey, v => router.CustomApiKey = v, password: true));
        var kind = new ComboBox { Margin = new Thickness(0, 0, 0, 8) };
        kind.Items.Add(CustomApiKind.OpenaiCompatible);
        kind.Items.Add(CustomApiKind.AnthropicCompatible);
        kind.SelectedItem = router.CustomKind;
        kind.SelectionChanged += (_, _) =>
        {
            if (kind.SelectedItem is CustomApiKind k) router.CustomKind = k;
        };
        panel.Children.Add(Label("API"));
        panel.Children.Add(kind);
        var add = new Button { Content = router.IsEditingCustom ? "Save changes" : "Add custom API", Padding = new Thickness(12, 4, 12, 4), IsEnabled = router.Reachable, Margin = new Thickness(0, 0, 0, 16) };
        add.Click += async (_, _) => { await router.CreateCustomNodeAsync(!router.IsEditingCustom); ShowCustom(); };
        panel.Children.Add(add);
        if (router.IsEditingCustom)
        {
            var cancel = new Button { Content = "Cancel edit", Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(0, 0, 0, 16) };
            cancel.Click += (_, _) => { router.CancelEditNode(); ShowCustom(); };
            panel.Children.Add(cancel);
        }
        panel.Children.Add(Heading("Custom providers"));
        if (router.Nodes.Count == 0)
        {
            panel.Children.Add(new TextBlock
            {
                Text = "None yet.",
                Foreground = TryBrush("TextSecondary"),
            });
        }
        foreach (var node in router.Nodes)
        {
            var card = new Border
            {
                BorderBrush = TryBrush("BorderSubtle"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12),
                Margin = new Thickness(0, 0, 0, 8),
            };
            var stack = new StackPanel();
            stack.Children.Add(new TextBlock { Text = node.Name, FontWeight = FontWeights.SemiBold });
            stack.Children.Add(new TextBlock { Text = $"{node.Prefix} · {node.Type} · {node.BaseUrl}", FontSize = 11, FontFamily = new FontFamily("Consolas"), Foreground = TryBrush("TextSecondary"), TextWrapping = TextWrapping.Wrap });
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
            var connect = new Button { Content = "Connect", Padding = new Thickness(10, 2, 10, 2) };
            connect.Click += (_, _) => _ = router.ConnectExistingNodeAsync(node);
            var test = new Button { Content = "Test", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 2, 10, 2) };
            test.Click += (_, _) => _ = router.TestNodeAsync(node);
            var edit = new Button { Content = "Edit", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 2, 10, 2) };
            edit.Click += (_, _) => { router.BeginEditNode(node); ShowCustom(); };
            var del = new Button { Content = "Delete", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 2, 10, 2) };
            del.Click += (_, _) => _ = router.DeleteNodeAsync(node);
            row.Children.Add(connect);
            row.Children.Add(test);
            row.Children.Add(edit);
            row.Children.Add(del);
            stack.Children.Add(row);
            card.Child = stack;
            panel.Children.Add(card);
        }
        if (router.Error is { } err) panel.Children.Add(ErrorText(err));
        _ = router.RefreshAsync();
        Body.Content = panel;
    }

    private void ShowLocal()
    {
        var local = _model.Local;
        local.RefreshInstalled();
        var panel = new StackPanel();
        panel.Children.Add(HeaderRow("Local models", local.Status, null));
        if (local.Error is { } err) panel.Children.Add(ErrorText(err));
        panel.Children.Add(Readonly("llama-server", local.RuntimeReady ? "Installed" : "Not installed"));
        panel.Children.Add(Readonly("Listen", local.Runtime.ServerUrl.ToString()));
        if (local.Serving && local.RunningModelId is { } running)
        {
            panel.Children.Add(Readonly("Serving", running));
        }
        var runtimeRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 16) };
        var install = new Button { Content = local.RuntimeReady ? "Reinstall runtime" : "Install llama.cpp", Padding = new Thickness(12, 4, 12, 4) };
        install.Click += async (_, _) => { await local.InstallRuntimeAsync(); ShowLocal(); };
        runtimeRow.Children.Add(install);
        if (local.Serving)
        {
            var stop = new Button { Content = "Stop local server", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 4, 12, 4) };
            stop.Click += (_, _) => { local.Stop(); ShowLocal(); };
            runtimeRow.Children.Add(stop);
        }
        panel.Children.Add(runtimeRow);
        if (local.Downloads.TryGetValue("runtime", out var rt) && rt < 1)
        {
            panel.Children.Add(new ProgressBar { Value = rt * 100, Maximum = 100, Height = 8, Margin = new Thickness(0, 0, 0, 12) });
        }
        panel.Children.Add(Heading("Download and run"));
        foreach (var spec in LocalModelCatalog.Models)
        {
            var card = new Border
            {
                BorderBrush = TryBrush("BorderSubtle"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12),
                Margin = new Thickness(0, 0, 0, 8),
            };
            var stack = new StackPanel();
            var title = new DockPanel();
            var name = new StackPanel { Orientation = Orientation.Horizontal };
            name.Children.Add(new TextBlock { Text = spec.Name, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
            if (spec.Reasoning)
            {
                name.Children.Add(new Border
                {
                    Background = new SolidColorBrush(Color.FromArgb(40, 230, 126, 34)),
                    CornerRadius = new CornerRadius(8),
                    Padding = new Thickness(6, 1, 6, 1),
                    Margin = new Thickness(8, 0, 0, 0),
                    Child = new TextBlock { Text = "LRM", FontSize = 10, FontWeight = FontWeights.SemiBold },
                });
            }
            title.Children.Add(name);
            Button action;
            if (local.RunningModelId == spec.Id) action = new Button { Content = "Stop" };
            else if (local.Installed.Contains(spec.Id)) action = new Button { Content = "Start" };
            else action = new Button { Content = "Download" };
            action.Padding = new Thickness(10, 2, 10, 2);
            action.HorizontalAlignment = HorizontalAlignment.Right;
            action.Click += async (_, _) =>
            {
                if (local.RunningModelId == spec.Id) local.Stop();
                else if (local.Installed.Contains(spec.Id)) await local.StartAsync(spec);
                else await local.DownloadAsync(spec);
                ShowLocal();
            };
            title.Children.Add(action);
            stack.Children.Add(title);
            stack.Children.Add(new TextBlock { Text = $"{spec.Family} · {spec.SizeLabel}", FontSize = 11, Foreground = TryBrush("TextSecondary") });
            stack.Children.Add(new TextBlock { Text = spec.Notes, FontSize = 11, Foreground = TryBrush("TextSecondary"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) });
            if (local.Downloads.TryGetValue(spec.Id, out var frac) && frac < 1 && !local.Installed.Contains(spec.Id))
            {
                stack.Children.Add(new ProgressBar { Value = frac * 100, Maximum = 100, Height = 8, Margin = new Thickness(0, 8, 0, 0) });
            }
            if (local.Installed.Contains(spec.Id))
            {
                var disk = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
                disk.Children.Add(new TextBlock
                {
                    Text = $"On disk · {LocalModelCatalog.PrettyBytes(local.Runtime.InstalledBytes(spec))}",
                    FontSize = 10,
                    Foreground = TryBrush("TextSecondary"),
                });
                var del = new Button { Content = "Delete", HorizontalAlignment = HorizontalAlignment.Right, Padding = new Thickness(8, 2, 8, 2) };
                del.Click += (_, _) => { local.Delete(spec); ShowLocal(); };
                disk.Children.Add(del);
                stack.Children.Add(disk);
            }
            card.Child = stack;
            panel.Children.Add(card);
        }
        Body.Content = panel;
    }

    private void ShowShare()
    {
        var router = _model.Router;
        var panel = new StackPanel();
        panel.Children.Add(Heading("Sharing"));
        panel.Children.Add(Readonly("Status", router.Tunnel.Running ? "Running" : router.Tunnel.Enabled ? "Enabled" : "Stopped"));
        if (!string.IsNullOrEmpty(router.Tunnel.ShortId)) panel.Children.Add(Readonly("Short id", router.Tunnel.ShortId));
        if (!string.IsNullOrEmpty(router.Tunnel.ShareUrl)) panel.Children.Add(Readonly("Public URL", router.Tunnel.ShareUrl));
        if (router.Tunnel.Downloading)
        {
            panel.Children.Add(new ProgressBar { Value = router.Tunnel.Progress, Maximum = 100, Height = 8, Margin = new Thickness(0, 0, 0, 8) });
        }
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 12) };
        if (router.Tunnel.Running || router.Tunnel.Enabled)
        {
            var stop = new Button { Content = "Stop sharing", Padding = new Thickness(12, 4, 12, 4) };
            stop.Click += async (_, _) => { await router.DisableTunnelAsync(); ShowShare(); };
            row.Children.Add(stop);
        }
        else
        {
            var share = new Button { Content = "Download and enable sharing", Padding = new Thickness(12, 4, 12, 4), IsEnabled = router.Reachable };
            share.Click += async (_, _) => { await router.EnableTunnelAsync(); ShowShare(); };
            row.Children.Add(share);
        }
        if (!string.IsNullOrEmpty(router.Tunnel.ShareUrl))
        {
            var copy = new Button { Content = "Copy URL", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 4, 12, 4) };
            copy.Click += (_, _) => router.CopyShareUrl();
            row.Children.Add(copy);
        }
        panel.Children.Add(row);
        panel.Children.Add(new TextBlock
        {
            Text = "Enabling sharing starts the loopback gateway and downloads the verified sharing binary once.",
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 16),
        });
        panel.Children.Add(Heading("Give this to a client"));
        var key = router.Keys.FirstOrDefault(k => k.Active) ?? router.Keys.FirstOrDefault();
        var shareEndpoint = (string.IsNullOrEmpty(router.Tunnel.ShareUrl) ? "Enable sharing to create an endpoint" : router.Tunnel.ShareUrl.TrimEnd('/') + "/v1");
        if (key is not null)
        {
            panel.Children.Add(Readonly("Endpoint", shareEndpoint));
            panel.Children.Add(Readonly(key.Name, key.Key.Length > 10 ? key.Key[..10] + "…" : key.Key));
            var copies = new StackPanel { Orientation = Orientation.Horizontal };
            var copyEp = new Button { Content = "Copy endpoint", Padding = new Thickness(12, 4, 12, 4) };
            copyEp.Click += (_, _) => { NativeClipboard.SetText(shareEndpoint); router.Status = "Copied"; };
            var copyKey = new Button { Content = "Copy API key", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 4, 12, 4) };
            copyKey.Click += (_, _) => { NativeClipboard.SetText(key.Key); router.Status = "Copied"; };
            copies.Children.Add(copyEp);
            copies.Children.Add(copyKey);
            panel.Children.Add(copies);
        }
        else
        {
            panel.Children.Add(new TextBlock { Text = "No share key yet.", Margin = new Thickness(0, 0, 0, 8) });
            var create = new Button { Content = "Create key", Padding = new Thickness(12, 4, 12, 4), IsEnabled = router.Reachable };
            create.Click += async (_, _) => { await router.CreateShareKeyAsync(); ShowShare(); };
            panel.Children.Add(create);
        }
        if (router.Error is { } err) panel.Children.Add(ErrorText(err));
        _ = router.RefreshAsync();
        Body.Content = panel;
    }

    private void ShowPlugins()
    {
        var panel = new StackPanel();
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        DockPanel.SetDock(buttons, Dock.Right);
        var reveal = new Button { Content = "Reveal folder", Padding = new Thickness(10, 4, 10, 4) };
        reveal.Click += (_, _) =>
        {
            try { Process.Start(new ProcessStartInfo { FileName = _model.Paths.Plugins, UseShellExecute = true }); }
            catch { /* ignore */ }
        };
        var reload = new Button { Content = "Reload", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
        reload.Click += (_, _) => { _model.Remount(); ShowPlugins(); };
        buttons.Children.Add(reveal);
        buttons.Children.Add(reload);
        header.Children.Add(buttons);
        header.Children.Add(Heading("Plugins"));
        panel.Children.Add(header);
        panel.Children.Add(new TextBlock
        {
            Text = "Drop a folder with plugin.yml into the plugins directory. Manifest plugins work untrusted. Compiled DLLs need Trust.",
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        });
        foreach (var entry in _model.Catalog.Entries)
        {
            var card = new Border
            {
                BorderBrush = TryBrush("BorderSubtle"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12),
                Margin = new Thickness(0, 0, 0, 8),
            };
            var stack = new StackPanel();
            var top = new DockPanel();
            var titles = new StackPanel();
            titles.Children.Add(new TextBlock { Text = entry.Manifest.Name, FontWeight = FontWeights.SemiBold });
            titles.Children.Add(new TextBlock { Text = entry.Manifest.Id, FontSize = 11, FontFamily = new FontFamily("Consolas"), Foreground = TryBrush("TextSecondary") });
            top.Children.Add(titles);
            var enabled = new CheckBox { Content = "Enabled", IsChecked = entry.Enabled, HorizontalAlignment = HorizontalAlignment.Right, IsEnabled = entry.Broken is null };
            enabled.Click += (_, _) =>
            {
                _model.Catalog.SetEnabled(entry.Manifest.Id, enabled.IsChecked == true);
                _model.Remount();
                ShowPlugins();
            };
            top.Children.Add(enabled);
            stack.Children.Add(top);
            var badges = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
            badges.Children.Add(Badge(entry.Kind.ToString().ToLowerInvariant()));
            badges.Children.Add(Badge(entry.Manifest.Plane.ToString().ToLowerInvariant()));
            badges.Children.Add(Badge(entry.Trust.ToString().ToLowerInvariant()));
            badges.Children.Add(new TextBlock
            {
                Text = $"v{entry.Manifest.Version} · ABI {entry.Manifest.Abi}",
                FontSize = 11,
                Foreground = TryBrush("TextSecondary"),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(6, 0, 0, 0),
            });
            stack.Children.Add(badges);
            if (!string.IsNullOrEmpty(entry.Manifest.Description))
            {
                stack.Children.Add(new TextBlock { Text = entry.Manifest.Description, FontSize = 11, Margin = new Thickness(0, 6, 0, 0) });
            }
            if (entry.Broken is { } broken) stack.Children.Add(ErrorText(broken));
            if (entry.Kind == PluginKind.Dylib && entry.Trust != PluginTrust.System)
            {
                var trust = new ComboBox { Width = 160, Margin = new Thickness(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Left };
                trust.Items.Add(PluginTrust.Untrusted);
                trust.Items.Add(PluginTrust.Trusted);
                trust.SelectedItem = entry.Trust;
                trust.SelectionChanged += (_, _) =>
                {
                    if (trust.SelectedItem is PluginTrust t)
                    {
                        _model.Catalog.SetTrust(entry.Manifest.Id, t);
                        _model.Remount();
                        ShowPlugins();
                    }
                };
                stack.Children.Add(trust);
            }
            stack.Children.Add(new SlotHost { Slot = WellKnownSlot.PluginsDetail, Registry = _model.Host.Slots, Margin = new Thickness(0, 8, 0, 0) });
            card.Child = stack;
            panel.Children.Add(card);
        }
        if (_model.Host.Issues.Count > 0)
        {
            panel.Children.Add(Heading("Last mount failed"));
            foreach (var issue in _model.Host.Issues)
            {
                panel.Children.Add(ErrorText($"{issue.RowId}: {issue.Message}"));
            }
        }
        Body.Content = panel;
    }

    private void ShowTasks()
    {
        var scheduler = _model.Scheduler;
        var panel = new StackPanel();
        panel.Children.Add(Heading("Scheduled Tasks"));
        panel.Children.Add(new TextBlock
        {
            Text = "Run a prompt on a cron schedule. Coding or non-coding — \"restart the station\", \"check my mail\".",
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        });

        var daemon = new CheckBox
        {
            Content = "Run tasks while the app is closed (background helper)",
            IsChecked = _model.IsBackgroundDaemonEnabled,
            Margin = new Thickness(0, 0, 0, 16),
        };
        daemon.Click += (_, _) =>
        {
            try { _model.SetBackgroundDaemonEnabled(daemon.IsChecked == true); }
            catch (Exception ex) { MessageBox.Show(ex.Message); daemon.IsChecked = _model.IsBackgroundDaemonEnabled; }
        };
        panel.Children.Add(daemon);

        panel.Children.Add(Heading("New task"));
        var name = new TextBox { Padding = new Thickness(8, 6, 8, 6), Margin = new Thickness(0, 0, 0, 8) };
        var cron = new TextBox { Text = "0 */5 * * *", Padding = new Thickness(8, 6, 8, 6), Margin = new Thickness(0, 0, 0, 4), FontFamily = new FontFamily("Consolas") };
        var cronPreview = new TextBlock { FontSize = 11, Foreground = TryBrush("TextSecondary"), Margin = new Thickness(0, 0, 0, 8) };
        void RefreshPreview()
        {
            var expr = CronExpression.TryParse(cron.Text);
            cronPreview.Text = expr is null
                ? "Invalid cron expression."
                : "Next: " + string.Join(" · ", NextRuns(expr, 3).Select(d => d.LocalDateTime.ToString("g")));
        }
        cron.TextChanged += (_, _) => RefreshPreview();
        RefreshPreview();
        var workspace = new TextBox { Text = _model.WorkspacePath, Padding = new Thickness(8, 6, 8, 6), Margin = new Thickness(0, 0, 0, 8) };
        var prompt = new TextBox { AcceptsReturn = true, MinLines = 3, TextWrapping = TextWrapping.Wrap, Padding = new Thickness(8, 6, 8, 6), Margin = new Thickness(0, 0, 0, 8) };
        var autoApprove = new CheckBox { Content = "Auto-approve command execution (unattended)", Margin = new Thickness(0, 0, 0, 8) };

        panel.Children.Add(Label("Name"));
        panel.Children.Add(name);
        panel.Children.Add(Label("Cron expression"));
        panel.Children.Add(cron);
        panel.Children.Add(cronPreview);
        panel.Children.Add(Label("Workspace"));
        panel.Children.Add(workspace);
        panel.Children.Add(Label("Prompt"));
        panel.Children.Add(prompt);
        panel.Children.Add(autoApprove);

        var add = new Button { Content = "Add task", Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(0, 0, 0, 16) };
        add.Click += (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(name.Text) || string.IsNullOrWhiteSpace(prompt.Text)
                || CronExpression.TryParse(cron.Text) is null || string.IsNullOrWhiteSpace(workspace.Text))
            {
                MessageBox.Show("Name, a valid cron expression, a workspace, and a prompt are required.");
                return;
            }
            scheduler.Upsert(new ScheduledTask
            {
                Name = name.Text.Trim(),
                Cron = cron.Text.Trim(),
                Prompt = prompt.Text.Trim(),
                WorkspacePath = workspace.Text.Trim(),
                AutoApproveCommands = autoApprove.IsChecked == true,
            });
            ShowTasks();
        };
        panel.Children.Add(add);

        panel.Children.Add(Heading("Tasks"));
        if (scheduler.Tasks.Count == 0)
        {
            panel.Children.Add(new TextBlock { Text = "No tasks yet.", Foreground = TryBrush("TextSecondary") });
        }
        foreach (var task in scheduler.Tasks)
        {
            var card = new Border
            {
                BorderBrush = TryBrush("BorderSubtle"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12),
                Margin = new Thickness(0, 0, 0, 8),
            };
            var stack = new StackPanel();
            stack.Children.Add(new TextBlock { Text = task.Name, FontWeight = FontWeights.SemiBold });
            stack.Children.Add(new TextBlock { Text = task.Cron, FontFamily = new FontFamily("Consolas"), FontSize = 11, Foreground = TryBrush("TextSecondary") });
            var next = task.NextRun();
            stack.Children.Add(new TextBlock
            {
                Text = next is { } n ? $"Next: {n.LocalDateTime:g}" : "Invalid cron",
                FontSize = 11,
                Foreground = TryBrush("TextSecondary"),
            });
            stack.Children.Add(new TextBlock
            {
                Text = $"Last: {task.LastState}" + (string.IsNullOrEmpty(task.LastMessage) ? "" : $" — {task.LastMessage}"),
                FontSize = 11,
                Foreground = task.LastState == TaskRunKind.Failed ? Brushes.IndianRed : TryBrush("TextSecondary"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 2, 0, 0),
            });
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
            var enabled = new CheckBox { Content = "Enabled", IsChecked = task.Enabled, VerticalAlignment = VerticalAlignment.Center };
            enabled.Click += (_, _) => { scheduler.SetEnabled(task.Id, enabled.IsChecked == true); };
            row.Children.Add(enabled);
            var run = new Button { Content = "Run now", Margin = new Thickness(12, 0, 0, 0), Padding = new Thickness(10, 2, 10, 2) };
            run.Click += (_, _) => { scheduler.RunNow(task.Id); ShowTasks(); };
            row.Children.Add(run);
            var del = new Button { Content = "Delete", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 2, 10, 2) };
            del.Click += (_, _) => { scheduler.Delete(task.Id); ShowTasks(); };
            row.Children.Add(del);
            stack.Children.Add(row);
            card.Child = stack;
            panel.Children.Add(card);
        }

        Body.Content = panel;
    }

    private static IEnumerable<DateTimeOffset> NextRuns(CronExpression expression, int count)
    {
        var cursor = DateTimeOffset.Now;
        for (var i = 0; i < count; i++)
        {
            var next = expression.NextDate(cursor);
            if (next is not { } value) yield break;
            yield return value;
            cursor = value;
        }
    }

    private void ShowPrompt()
    {
        var text = _model.AssembledSystemPrompt();
        Body.Content = new TextBox
        {
            Text = string.IsNullOrEmpty(text) ? "No prompt sections mounted." : text,
            IsReadOnly = true,
            TextWrapping = TextWrapping.Wrap,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            Foreground = TryBrush("TextPrimary"),
        };
    }

    private static TextBlock Heading(string text) => new()
    {
        Text = text,
        FontSize = 18,
        FontWeight = FontWeights.SemiBold,
        Margin = new Thickness(0, 0, 0, 12),
    };

    private static TextBlock Label(string text) => new()
    {
        Text = text,
        FontSize = 12,
        FontWeight = FontWeights.SemiBold,
        Margin = new Thickness(0, 0, 0, 4),
    };

    private static DataTemplate ProviderTemplate()
    {
        var row = new FrameworkElementFactory(typeof(StackPanel));
        row.SetValue(StackPanel.OrientationProperty, Orientation.Horizontal);
        row.AppendChild(ProviderBadgeTemplate());
        var name = new FrameworkElementFactory(typeof(TextBlock));
        name.SetBinding(TextBlock.TextProperty, new Binding("Name"));
        name.SetValue(TextBlock.VerticalAlignmentProperty, VerticalAlignment.Center);
        name.SetValue(FrameworkElement.MarginProperty, new Thickness(8, 0, 0, 0));
        row.AppendChild(name);
        return new DataTemplate { VisualTree = row };
    }

    private static FrameworkElementFactory ProviderBadgeTemplate()
    {
        var badge = new FrameworkElementFactory(typeof(Border));
        badge.SetValue(Border.WidthProperty, 25d);
        badge.SetValue(Border.HeightProperty, 25d);
        badge.SetValue(Border.CornerRadiusProperty, new CornerRadius(7));
        badge.SetValue(Border.BackgroundProperty, TryBrushStatic("PanelBackground"));
        var text = new FrameworkElementFactory(typeof(TextBlock));
        text.SetBinding(TextBlock.TextProperty, new Binding("LogoKey") { Converter = LogoMarkConverter.Instance });
        text.SetValue(TextBlock.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        text.SetValue(TextBlock.VerticalAlignmentProperty, VerticalAlignment.Center);
        text.SetValue(TextBlock.FontWeightProperty, FontWeights.Bold);
        badge.AppendChild(text);
        return badge;
    }

    private static Border ProviderBadge(string name, string key) => new()
    {
        Width = 25,
        Height = 25,
        CornerRadius = new CornerRadius(7),
        Background = TryBrushStatic("PanelBackground"),
        Child = new TextBlock
        {
            Text = LogoMarkConverter.Mark(name, key),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            FontWeight = FontWeights.Bold,
            FontSize = 10,
        },
    };

    private static Brush? TryBrushStatic(string key) => Application.Current?.TryFindResource(key) as Brush;

    private UIElement HeaderRow(string title, string status, Action? refresh)
    {
        var row = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
        var right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        DockPanel.SetDock(right, Dock.Right);
        right.Children.Add(new TextBlock { Text = status, FontSize = 11, Foreground = TryBrush("TextSecondary"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
        if (refresh is not null)
        {
            var button = new Button { Content = "Refresh", Padding = new Thickness(10, 4, 10, 4) };
            button.Click += (_, _) => refresh();
            right.Children.Add(button);
        }
        row.Children.Add(right);
        row.Children.Add(Heading(title));
        return row;
    }

    private UIElement BoundField(string label, string value, Action<string> set, bool password = false)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
        stack.Children.Add(Label(label));
        if (password)
        {
            var box = new PasswordBox { Padding = new Thickness(8, 6, 8, 6) };
            box.Password = value;
            box.PasswordChanged += (_, _) => set(box.Password);
            stack.Children.Add(box);
        }
        else
        {
            var box = new TextBox { Text = value, Padding = new Thickness(8, 6, 8, 6) };
            box.TextChanged += (_, _) => set(box.Text);
            stack.Children.Add(box);
        }
        return stack;
    }

    private UIElement Readonly(string label, string value)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
        stack.Children.Add(Label(label));
        stack.Children.Add(new TextBox
        {
            Text = value,
            IsReadOnly = true,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            TextWrapping = TextWrapping.Wrap,
            Foreground = TryBrush("TextPrimary"),
        });
        return stack;
    }

    private static TextBlock ErrorText(string text) => new()
    {
        Text = text,
        Foreground = Brushes.IndianRed,
        FontSize = 12,
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, 0, 0, 8),
    };

    private Border Badge(string text) => new()
    {
        Background = new SolidColorBrush(Color.FromArgb(20, 0, 0, 0)),
        CornerRadius = new CornerRadius(8),
        Padding = new Thickness(6, 2, 6, 2),
        Margin = new Thickness(0, 0, 6, 0),
        Child = new TextBlock { Text = text, FontSize = 10, FontWeight = FontWeights.SemiBold },
    };

    private static Brush TryBrush(string key) =>
        Application.Current?.TryFindResource(key) as Brush ?? Brushes.Gray;
}

internal sealed class LogoMarkConverter : IValueConverter
{
    public static readonly LogoMarkConverter Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => Mark("", value as string ?? "");
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;

    public static string Mark(string name, string key)
    {
        var known = key.ToLowerInvariant() switch
        {
            "gpt" => "✳",
            "gemini" => "✦",
            "openai" => "◎",
            "openrouter" => "↗",
            "github" => "GH",
            "iflow" => "iF",
            "minimax" => "MM",
            "cohere" => "Co",
            "siliconflow" => "SF",
            "chutes" => "Ch",
            "generic" => "•",
            _ => "",
        };
        if (!string.IsNullOrEmpty(known)) return known;
        var source = string.IsNullOrWhiteSpace(name) ? key : name;
        var words = source.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return words.Length > 1
            ? string.Concat(words.Take(2).Select(word => word[0])).ToUpperInvariant()
            : source[..Math.Min(2, source.Length)].ToUpperInvariant();
    }
}
