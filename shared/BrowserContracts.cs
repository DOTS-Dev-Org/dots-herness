// Copyright (c) 2026 DOTS
// Browser capability contracts shared by the Windows and Linux harnesses.

using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace DotsHarnessCore;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum BrowserBackend
{
    Managed,
    Extension,
    Unknown,
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum BrowserCleanupStatus
{
    NotUsed,
    Closed,
    PendingRecovery,
    Failed,
}

public readonly record struct BrowserScope(
    [property: JsonPropertyName("area")] string Area,
    [property: JsonPropertyName("conversationID")] string ConversationId,
    [property: JsonPropertyName("runID")] string RunId)
{
    public string Key => $"{Area}:{ConversationId}:{RunId}";
}

public sealed record BrowserPage(
    [property: JsonPropertyName("pageID")] string PageId,
    [property: JsonPropertyName("backend")] BrowserBackend Backend,
    [property: JsonPropertyName("url")] string Url,
    [property: JsonPropertyName("scope")] BrowserScope Scope);

public sealed record BrowserRunSummary(
    [property: JsonPropertyName("backend")] BrowserBackend Backend,
    [property: JsonPropertyName("openedPageIDs")] IReadOnlyList<string> OpenedPageIds,
    [property: JsonPropertyName("closedPageIDs")] IReadOnlyList<string> ClosedPageIds,
    [property: JsonPropertyName("cleanupStatus")] BrowserCleanupStatus CleanupStatus,
    [property: JsonPropertyName("diagnosticCode")] string DiagnosticCode)
{
    public static BrowserRunSummary NotUsed(BrowserBackend backend = BrowserBackend.Unknown) =>
        new(backend, Array.Empty<string>(), Array.Empty<string>(), BrowserCleanupStatus.NotUsed, "not_used");
}

public enum AgentCommandSandboxMode
{
    Legacy,
    StrictNoDesktop,
}

public static class BrowserBackendPolicy
{
    public static BrowserBackend ResolveUserRule(string? userText)
    {
        if (string.IsNullOrWhiteSpace(userText)) return BrowserBackend.Unknown;
        var value = userText.Trim().ToLowerInvariant();

        if (ContainsAny(value,
                "mevcut chrome", "chrome profilimi", "chrome oturumumu", "oturum açılmış chrome",
                "oturum acilmis chrome", "current chrome", "existing chrome", "logged-in chrome",
                "logged in chrome", "use my chrome", "use existing chrome", "my chrome profile"))
            return BrowserBackend.Extension;

        if (ContainsAny(value,
                "managed browser", "isolated browser", "clean browser", "temporary browser",
                "izole tarayıcı", "izole tarayici", "temiz tarayıcı", "temiz tarayici",
                "managed chrome", "clean profile", "temiz profil"))
            return BrowserBackend.Managed;

        return BrowserBackend.Unknown;
    }

    public static BrowserBackend ParseConfirmation(string? answer)
    {
        if (string.IsNullOrWhiteSpace(answer)) return BrowserBackend.Unknown;
        var value = answer.Trim().ToLowerInvariant();
        if (ContainsAny(value, "extension", "mevcut chrome", "current chrome", "existing chrome", "chrome profile", "existing chrome profile")
            || ContainsToken(value, "2"))
            return BrowserBackend.Extension;
        if (ContainsAny(value, "managed", "izole", "isolated", "clean", "temiz", "managed isolated browser")
            || ContainsToken(value, "1"))
            return BrowserBackend.Managed;
        return BrowserBackend.Unknown;
    }

    private static bool ContainsAny(string value, params string[] candidates) =>
        candidates.Any(candidate => value.Contains(candidate, StringComparison.Ordinal));

    private static bool ContainsToken(string value, string token) =>
        value.Split([' ', '\t', '\r', '\n', '.', ',', ':', ';', '!', '?', '(', ')', '[', ']', '{', '}', '"', '\'', '-'],
                StringSplitOptions.RemoveEmptyEntries)
            .Any(part => string.Equals(part, token, StringComparison.Ordinal));
}

public static class BrowserTools
{
    public const string OpenName = "browser_open";
    public const string NavigateName = "browser_navigate";
    public const string CloseName = "browser_close";

    public static IReadOnlyList<NativeToolDefinition> Definitions { get; } =
    [
        new(OpenName,
            "Open a URL in the host-managed browser session. The host selects the backend; do not pass a backend.",
            new JsonObject
            {
                ["type"] = "object",
                ["properties"] = new JsonObject
                {
                    ["url"] = new JsonObject { ["type"] = "string", ["description"] = "An http or https URL." },
                },
                ["required"] = new JsonArray("url"),
                ["additionalProperties"] = false,
            }),
        new(NavigateName,
            "Navigate an owned browser page. The pageID must come from browser_open.",
            new JsonObject
            {
                ["type"] = "object",
                ["properties"] = new JsonObject
                {
                    ["pageID"] = new JsonObject { ["type"] = "string" },
                    ["url"] = new JsonObject { ["type"] = "string", ["description"] = "An http or https URL." },
                },
                ["required"] = new JsonArray("pageID", "url"),
                ["additionalProperties"] = false,
            }),
        new(CloseName,
            "Close an owned browser page. Pages are also closed automatically when the run ends.",
            new JsonObject
            {
                ["type"] = "object",
                ["properties"] = new JsonObject
                {
                    ["pageID"] = new JsonObject { ["type"] = "string" },
                },
                ["required"] = new JsonArray("pageID"),
                ["additionalProperties"] = false,
            }),
    ];

    public static NativeToolCall BackendQuestionCall(string callId) => new(
        $"{callId}:browser-backend",
        AskUserTool.Name,
        """{"questions":[{"header":"Browser","question":"Which browser session should this run use?","options":["Managed isolated browser","Existing Chrome profile"]}]}""");
}
