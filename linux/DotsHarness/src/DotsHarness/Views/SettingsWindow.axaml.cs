// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Diagnostics;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Media;
using DotsHarnessCore;
using HarnessPluginKit;
using PluginRuntime;

namespace DotsHarness.Views;

public partial class SettingsWindow : Window
{
    private AppModel Model =>
        DataContext as AppModel
        ?? (Application.Current as App)?.Model
        ?? throw new InvalidOperationException("Settings needs an AppModel");

    public SettingsWindow()
    {
        InitializeComponent();
        Opened += (_, _) => ShowGeneral();
    }

    private void OnTab(object? sender, SelectionChangedEventArgs e)
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
        appearance.SelectedItem = Model.Appearance;
        appearance.SelectionChanged += (_, _) =>
        {
            if (appearance.SelectedItem is AppModel.AppearanceKind kind)
            {
                Model.SetAppearance(kind);
                (Application.Current as App)?.ApplyAppearance(kind);
            }
        };
        panel.Children.Add(appearance);
        var confirmBeforeExit = new CheckBox
        {
            Content = "Ask before closing",
            IsChecked = Model.ConfirmBeforeExit,
            Margin = new Thickness(0, 0, 0, 12),
        };
        confirmBeforeExit.IsCheckedChanged += (_, _) => Model.SetConfirmBeforeExit(confirmBeforeExit.IsChecked == true);
        panel.Children.Add(confirmBeforeExit);
        panel.Children.Add(BoundField("Workspace", Model.WorkspacePath, Model.SetWorkspace));
        if (Model.Bridge.Connection is { } info)
        {
            panel.Children.Add(Readonly("Connected model", $"{info.Provider}/{info.Model}"));
            panel.Children.Add(Readonly("Workspace", info.Workspace));
        }
        panel.Children.Add(Readonly("Support folder", Model.Paths.Root));
        panel.Children.Add(Readonly("User plugins", Model.Paths.Plugins));
        panel.Children.Add(new TextBlock
        {
            Text = "Copyright (c) 2026 DOTS. Derived from DeepSeek Harness — Copyright (c) 2026 DeepSeek. MIT.",
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 12, 0, 12),
        });
        panel.Children.Add(new SlotHost { Slot = WellKnownSlot.SettingsSections, Registry = Model.Host.Slots });
        Body.Content = panel;
    }

    private void ShowProviders()
    {
        var router = Model.Router;
        var panel = new StackPanel();
        panel.Children.Add(HeaderRow("Providers", router.Status, () => _ = router.RefreshAsync()));
        if (router.Error is { } err) panel.Children.Add(ErrorText(err));
        panel.Children.Add(Label("Provider"));
        var picker = new ComboBox
        {
            Margin = new Thickness(0, 0, 0, 8),
            ItemTemplate = new FuncDataTemplate<RouterProviderKind>((kind, _) => ProviderLine(kind.Name, kind.LogoKey)),
        };
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
        var connect = new Button { Content = "Connect", Padding = new Thickness(12, 4), IsEnabled = router.Reachable && canConnect };
        connect.Click += (_, _) => _ = router.StartConnectAsync();
        row.Children.Add(connect);
        if (router.Flow is not RouterFlow.Idle)
        {
            var cancel = new Button { Content = "Cancel", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 4) };
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
                var finish = new Button { Content = "Finish login", Padding = new Thickness(12, 4), Margin = new Thickness(0, 0, 0, 12) };
                finish.Click += (_, _) => _ = router.FinishBrowserAsync();
                host.Children.Add(finish);
                break;
            case RouterFlow.Device device:
                host.Children.Add(Label("Device login"));
                if (!string.IsNullOrEmpty(device.UserCode))
                {
                    host.Children.Add(new TextBlock { Text = device.UserCode, FontSize = 20, FontFamily = new FontFamily("monospace"), Margin = new Thickness(0, 0, 0, 6) });
                }
                host.Children.Add(Readonly("Verify", device.VerificationUrl));
                host.Children.Add(new TextBlock { Text = "Waiting for authorization…", Foreground = TryBrush("TextSecondary") });
                break;
        }
    }

    private Control ConnectionCard(RouterConnection connection, RouterController router)
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
        stack.Children.Add(new TextBlock { Text = connection.Name, FontWeight = FontWeight.SemiBold });
        var provider = RouterCatalog.KindFor(connection.Provider);
        stack.Children.Add(ProviderLine(RouterCatalog.LabelFor(connection.Provider), provider?.LogoKey ?? "generic"));
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        var active = new CheckBox { Content = "Active", IsChecked = connection.Active, VerticalAlignment = VerticalAlignment.Center };
        active.IsCheckedChanged += (_, _) => _ = router.ToggleAsync(connection);
        row.Children.Add(active);
        var test = new Button { Content = "Test", Margin = new Thickness(12, 0, 0, 0), Padding = new Thickness(10, 2) };
        test.Click += (_, _) => _ = router.TestAsync(connection);
        row.Children.Add(test);
        var remove = new Button { Content = "Remove", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 2) };
        remove.Click += (_, _) => _ = router.RemoveAsync(connection);
        row.Children.Add(remove);
        stack.Children.Add(row);
        if (!string.IsNullOrEmpty(connection.Error)) stack.Children.Add(ErrorText(connection.Error));
        card.Child = stack;
        return card;
    }

    private void ShowCustom()
    {
        var router = Model.Router;
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
        var add = new Button { Content = router.IsEditingCustom ? "Save changes" : "Add custom API", Padding = new Thickness(12, 4), IsEnabled = router.Reachable, Margin = new Thickness(0, 0, 0, 16) };
        add.Click += async (_, _) => { await router.CreateCustomNodeAsync(!router.IsEditingCustom); ShowCustom(); };
        panel.Children.Add(add);
        if (router.IsEditingCustom)
        {
            var cancel = new Button { Content = "Cancel edit", Padding = new Thickness(12, 4), Margin = new Thickness(0, 0, 0, 16) };
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
            stack.Children.Add(new TextBlock { Text = node.Name, FontWeight = FontWeight.SemiBold });
            stack.Children.Add(new TextBlock { Text = $"{node.Prefix} · {node.Type} · {node.BaseUrl}", FontSize = 11, FontFamily = new FontFamily("monospace"), Foreground = TryBrush("TextSecondary"), TextWrapping = TextWrapping.Wrap });
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
            var connect = new Button { Content = "Connect", Padding = new Thickness(10, 2) };
            connect.Click += (_, _) => _ = router.ConnectExistingNodeAsync(node);
            var test = new Button { Content = "Test", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 2) };
            test.Click += (_, _) => _ = router.TestNodeAsync(node);
            var edit = new Button { Content = "Edit", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 2) };
            edit.Click += (_, _) => { router.BeginEditNode(node); ShowCustom(); };
            var del = new Button { Content = "Delete", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 2) };
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
        var local = Model.Local;
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
        var install = new Button { Content = local.RuntimeReady ? "Reinstall runtime" : "Install llama.cpp", Padding = new Thickness(12, 4) };
        install.Click += async (_, _) => { await local.InstallRuntimeAsync(); ShowLocal(); };
        runtimeRow.Children.Add(install);
        if (local.Serving)
        {
            var stop = new Button { Content = "Stop local server", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 4) };
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
            name.Children.Add(new TextBlock { Text = spec.Name, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center });
            if (spec.Reasoning)
            {
                name.Children.Add(new Border
                {
                    Background = new SolidColorBrush(Color.FromArgb(40, 230, 126, 34)),
                    CornerRadius = new CornerRadius(8),
                    Padding = new Thickness(6, 1),
                    Margin = new Thickness(8, 0, 0, 0),
                    Child = new TextBlock { Text = "LRM", FontSize = 10, FontWeight = FontWeight.SemiBold },
                });
            }
            title.Children.Add(name);
            Button action;
            if (local.RunningModelId == spec.Id) action = new Button { Content = "Stop" };
            else if (local.Installed.Contains(spec.Id)) action = new Button { Content = "Start" };
            else action = new Button { Content = "Download" };
            action.Padding = new Thickness(10, 2);
            action.HorizontalAlignment = HorizontalAlignment.Right;
            action.Click += async (_, _) =>
            {
                if (local.RunningModelId == spec.Id) local.Stop();
                else if (local.Installed.Contains(spec.Id)) await local.StartAsync(spec);
                else await local.DownloadAsync(spec);
                ShowLocal();
            };
            DockPanel.SetDock(action, Dock.Right);
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
                var del = new Button { Content = "Delete", HorizontalAlignment = HorizontalAlignment.Right, Padding = new Thickness(8, 2) };
                del.Click += (_, _) => { local.Delete(spec); ShowLocal(); };
                DockPanel.SetDock(del, Dock.Right);
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
        var router = Model.Router;
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
            var stop = new Button { Content = "Stop sharing", Padding = new Thickness(12, 4) };
            stop.Click += async (_, _) => { await router.DisableTunnelAsync(); ShowShare(); };
            row.Children.Add(stop);
        }
        else
        {
            var share = new Button { Content = "Download and enable sharing", Padding = new Thickness(12, 4), IsEnabled = router.Reachable };
            share.Click += async (_, _) => { await router.EnableTunnelAsync(); ShowShare(); };
            row.Children.Add(share);
        }
        if (!string.IsNullOrEmpty(router.Tunnel.ShareUrl))
        {
            var copy = new Button { Content = "Copy URL", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 4) };
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
        var shareEndpoint = string.IsNullOrEmpty(router.Tunnel.ShareUrl) ? "Enable sharing to create an endpoint" : router.Tunnel.ShareUrl.TrimEnd('/') + "/v1";
        if (key is not null)
        {
            panel.Children.Add(Readonly("Endpoint", shareEndpoint));
            panel.Children.Add(Readonly(key.Name, key.Key.Length > 10 ? key.Key[..10] + "…" : key.Key));
            var copies = new StackPanel { Orientation = Orientation.Horizontal };
            var copyEp = new Button { Content = "Copy endpoint", Padding = new Thickness(12, 4) };
            copyEp.Click += (_, _) => { NativeClipboard.SetText(shareEndpoint); router.Status = "Copied"; };
            var copyKey = new Button { Content = "Copy API key", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 4) };
            copyKey.Click += (_, _) => { NativeClipboard.SetText(key.Key); router.Status = "Copied"; };
            copies.Children.Add(copyEp);
            copies.Children.Add(copyKey);
            panel.Children.Add(copies);
        }
        else
        {
            panel.Children.Add(new TextBlock { Text = "No share key yet.", Margin = new Thickness(0, 0, 0, 8) });
            var create = new Button { Content = "Create key", Padding = new Thickness(12, 4), IsEnabled = router.Reachable };
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
        header.Children.Add(Heading("Plugins"));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var reveal = new Button { Content = "Reveal folder", Padding = new Thickness(10, 4) };
        reveal.Click += (_, _) =>
        {
            try
            {
                Process.Start(new ProcessStartInfo { FileName = "xdg-open", Arguments = Model.Paths.Plugins, UseShellExecute = false });
            }
            catch { /* ignore */ }
        };
        var reload = new Button { Content = "Reload", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 4) };
        reload.Click += (_, _) => { Model.Remount(); ShowPlugins(); };
        buttons.Children.Add(reveal);
        buttons.Children.Add(reload);
        DockPanel.SetDock(buttons, Dock.Right);
        header.Children.Add(buttons);
        panel.Children.Add(header);
        panel.Children.Add(new TextBlock
        {
            Text = "Drop a folder with plugin.yml into the plugins directory. Manifest plugins work untrusted. Compiled assemblies need Trust.",
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        });
        foreach (var entry in Model.Catalog.Entries)
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
            titles.Children.Add(new TextBlock { Text = entry.Manifest.Name, FontWeight = FontWeight.SemiBold });
            titles.Children.Add(new TextBlock { Text = entry.Manifest.Id, FontSize = 11, FontFamily = new FontFamily("monospace"), Foreground = TryBrush("TextSecondary") });
            top.Children.Add(titles);
            var enabled = new CheckBox { Content = "Enabled", IsChecked = entry.Enabled, HorizontalAlignment = HorizontalAlignment.Right, IsEnabled = entry.Broken is null };
            enabled.IsCheckedChanged += (_, _) =>
            {
                Model.Catalog.SetEnabled(entry.Manifest.Id, enabled.IsChecked == true);
                Model.Remount();
                ShowPlugins();
            };
            DockPanel.SetDock(enabled, Dock.Right);
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
                        Model.Catalog.SetTrust(entry.Manifest.Id, t);
                        Model.Remount();
                        ShowPlugins();
                    }
                };
                stack.Children.Add(trust);
            }
            stack.Children.Add(new SlotHost { Slot = WellKnownSlot.PluginsDetail, Registry = Model.Host.Slots, Margin = new Thickness(0, 8, 0, 0) });
            card.Child = stack;
            panel.Children.Add(card);
        }
        if (Model.Host.Issues.Count > 0)
        {
            panel.Children.Add(Heading("Last mount failed"));
            foreach (var issue in Model.Host.Issues)
            {
                panel.Children.Add(ErrorText($"{issue.RowId}: {issue.Message}"));
            }
        }
        Body.Content = panel;
    }

    private void ShowTasks()
    {
        var scheduler = Model.Scheduler;
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

        var status = new TextBlock
        {
            FontSize = 11,
            Foreground = new SolidColorBrush(Colors.IndianRed),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 8),
        };

        var daemon = new CheckBox
        {
            Content = "Run tasks while the app is closed (background helper)",
            IsChecked = Model.IsBackgroundDaemonEnabled,
            Margin = new Thickness(0, 0, 0, 16),
        };
        daemon.IsCheckedChanged += (_, _) =>
        {
            try { Model.SetBackgroundDaemonEnabled(daemon.IsChecked == true); status.Text = ""; }
            catch (Exception ex) { status.Text = ex.Message; daemon.IsChecked = Model.IsBackgroundDaemonEnabled; }
        };
        panel.Children.Add(daemon);

        panel.Children.Add(Heading("New task"));
        var name = new TextBox { Margin = new Thickness(0, 0, 0, 8) };
        var cron = new TextBox { Text = "0 */5 * * *", Margin = new Thickness(0, 0, 0, 4), FontFamily = new FontFamily("monospace") };
        var cronPreview = new TextBlock { FontSize = 11, Foreground = TryBrush("TextSecondary"), Margin = new Thickness(0, 0, 0, 8) };
        void RefreshPreview()
        {
            var expr = CronExpression.TryParse(cron.Text ?? "");
            cronPreview.Text = expr is null
                ? "Invalid cron expression."
                : "Next: " + string.Join(" · ", NextRuns(expr, 3).Select(d => d.LocalDateTime.ToString("g")));
        }
        cron.TextChanged += (_, _) => RefreshPreview();
        RefreshPreview();
        var workspace = new TextBox { Text = Model.WorkspacePath, Margin = new Thickness(0, 0, 0, 8) };
        var prompt = new TextBox { AcceptsReturn = true, Height = 72, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) };
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
        panel.Children.Add(status);

        var add = new Button { Content = "Add task", Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(0, 0, 0, 16) };
        add.Click += (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(name.Text) || string.IsNullOrWhiteSpace(prompt.Text)
                || CronExpression.TryParse(cron.Text ?? "") is null || string.IsNullOrWhiteSpace(workspace.Text))
            {
                status.Text = "Name, a valid cron expression, a workspace, and a prompt are required.";
                return;
            }
            scheduler.Upsert(new ScheduledTask
            {
                Name = name.Text!.Trim(),
                Cron = cron.Text!.Trim(),
                Prompt = prompt.Text!.Trim(),
                WorkspacePath = workspace.Text!.Trim(),
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
            stack.Children.Add(new TextBlock { Text = task.Name, FontWeight = FontWeight.SemiBold });
            stack.Children.Add(new TextBlock { Text = task.Cron, FontFamily = new FontFamily("monospace"), FontSize = 11, Foreground = TryBrush("TextSecondary") });
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
                Foreground = task.LastState == TaskRunKind.Failed ? new SolidColorBrush(Colors.IndianRed) : TryBrush("TextSecondary"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 2, 0, 0),
            });
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
            var enabled = new CheckBox { Content = "Enabled", IsChecked = task.Enabled, VerticalAlignment = VerticalAlignment.Center };
            enabled.IsCheckedChanged += (_, _) => scheduler.SetEnabled(task.Id, enabled.IsChecked == true);
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
        var text = Model.AssembledSystemPrompt();
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
        FontWeight = FontWeight.SemiBold,
        Margin = new Thickness(0, 0, 0, 12),
    };

    private static TextBlock Label(string text) => new()
    {
        Text = text,
        FontSize = 12,
        FontWeight = FontWeight.SemiBold,
        Margin = new Thickness(0, 0, 0, 4),
    };

    private static Control ProviderLine(string name, string key)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(ProviderBadge(name, key));
        row.Children.Add(new TextBlock { Text = name, FontSize = 11, Foreground = TryBrush("TextSecondary"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) });
        return row;
    }

    private static Border ProviderBadge(string name, string key)
    {
        var seed = Math.Abs(key.Aggregate(17, (value, character) => value * 31 + character));
        var color = Color.FromRgb((byte)(80 + seed % 80), (byte)(80 + (seed / 7) % 80), (byte)(100 + (seed / 13) % 80));
        return new Border
        {
            Width = 25,
            Height = 25,
            CornerRadius = new CornerRadius(7),
            Background = new SolidColorBrush(color),
            Child = new TextBlock
            {
                Text = LogoMark(name, key),
                HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center,
                VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
                FontWeight = FontWeight.Bold,
                FontSize = 10,
                Foreground = Brushes.White,
            },
        };
    }

    private static string LogoMark(string name, string key)
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

    private Control HeaderRow(string title, string status, Action? refresh)
    {
        var row = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
        row.Children.Add(Heading(title));
        var right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        right.Children.Add(new TextBlock { Text = status, FontSize = 11, Foreground = TryBrush("TextSecondary"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
        if (refresh is not null)
        {
            var button = new Button { Content = "Refresh", Padding = new Thickness(10, 4) };
            button.Click += (_, _) => refresh();
            right.Children.Add(button);
        }
        DockPanel.SetDock(right, Dock.Right);
        row.Children.Add(right);
        return row;
    }

    private Control BoundField(string label, string value, Action<string> set, bool password = false)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
        stack.Children.Add(Label(label));
        if (password)
        {
            var box = new TextBox { Padding = new Thickness(8, 6), PasswordChar = '•', Text = value };
            box.TextChanged += (_, _) => set(box.Text ?? "");
            stack.Children.Add(box);
        }
        else
        {
            var box = new TextBox { Text = value, Padding = new Thickness(8, 6) };
            box.TextChanged += (_, _) => set(box.Text ?? "");
            stack.Children.Add(box);
        }
        return stack;
    }

    private Control Readonly(string label, string value)
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
        Padding = new Thickness(6, 2),
        Margin = new Thickness(0, 0, 6, 0),
        Child = new TextBlock { Text = text, FontSize = 10, FontWeight = FontWeight.SemiBold },
    };

    private static IBrush TryBrush(string key)
    {
        if (Application.Current?.TryGetResource(key, Application.Current.ActualThemeVariant, out var resource) == true
            && resource is IBrush brush)
        {
            return brush;
        }
        return Brushes.Gray;
    }
}
