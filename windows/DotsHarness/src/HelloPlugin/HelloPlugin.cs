// Copyright (c) 2026 DOTS
// Example third-party C# plugin. Users copy this pattern.
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using HarnessPluginKit;

namespace HelloPlugin;

public sealed class HelloPlugin : IDefaultPlugin
{
    public static readonly PluginManifest StaticManifest = new(
        Id: "com.example.hello",
        Name: "Hello",
        Version: "0.1.0",
        Plane: PluginPlane.Session,
        Inject: new[] { "prompt", "slots" },
        Description: "Example user plugin: a prompt section and a composer chip.");

    public PluginManifest Manifest => StaticManifest;

    public void Apply(IPluginContext ctx)
    {
        ctx.Prompt.Section(
            "hello:note",
            40,
            "The Hello example plugin is mounted. Greet the user by name if they offer one.");
        ctx.Slots.Inject(
            WellKnownSlot.ComposerAccessory,
            "hello-chip",
            10,
            "Hello",
            () => new Border
            {
                CornerRadius = new CornerRadius(10),
                Background = new SolidColorBrush(Color.FromArgb(30, 0, 0, 0)),
                Padding = new Thickness(8, 4, 8, 4),
                Child = new TextBlock
                {
                    Text = "Hello plugin",
                    FontSize = 11,
                    FontWeight = FontWeights.SemiBold,
                },
            });
    }
}
