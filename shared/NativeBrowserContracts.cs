// Copyright (c) 2026 DOTS
// Contracts for the native in-app browser shared by Windows (WebView2) and Linux (WebKitGTK).

using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace DotsHarnessCore;

public static class NativeBrowserTools
{
    public const string ToolName = "native_browser";

    public static IReadOnlyList<NativeToolDefinition> Definitions { get; } =
    [
        new(ToolName,
            "Interact directly with the native in-app live browser located in the Right Dock (Microsoft.Web.WebView2 on Windows, WebKitGTK on Linux). Zero overhead (0 MB download, minimal RAM/CPU). Use it to open URLs, preview local web servers, capture pixel-perfect screenshots, evaluate JavaScript, read DOM text, click elements, or type input.",
            new JsonObject
            {
                ["type"] = "object",
                ["properties"] = new JsonObject
                {
                    ["action"] = new JsonObject
                    {
                        ["type"] = "string",
                        ["enum"] = new JsonArray(
                            "open", "navigate", "screenshot", "evaluate_js",
                            "get_content", "click", "type", "reload", "back", "forward"
                        ),
                        ["description"] = "Action to perform on the in-app live browser.",
                    },
                    ["url"] = new JsonObject
                    {
                        ["type"] = "string",
                        ["description"] = "URL to navigate to for 'open' or 'navigate' (e.g. 'http://localhost:3000' or 'https://example.com').",
                    },
                    ["path"] = new JsonObject
                    {
                        ["type"] = "string",
                        ["description"] = "Screenshot destination path relative to workspace (defaults to 'native_browser.png').",
                    },
                    ["script"] = new JsonObject
                    {
                        ["type"] = "string",
                        ["description"] = "JavaScript snippet to evaluate for 'evaluate_js'.",
                    },
                    ["selector"] = new JsonObject
                    {
                        ["type"] = "string",
                        ["description"] = "CSS selector for 'click' or 'type' actions.",
                    },
                    ["text"] = new JsonObject
                    {
                        ["type"] = "string",
                        ["description"] = "Text to enter into the element for 'type' action.",
                    },
                    ["x"] = new JsonObject { ["type"] = "integer", ["description"] = "Optional X coordinate for 'click' action." },
                    ["y"] = new JsonObject { ["type"] = "integer", ["description"] = "Optional Y coordinate for 'click' action." },
                },
                ["required"] = new JsonArray("action"),
            })
    ];
}
