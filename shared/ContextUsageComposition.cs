namespace DotsHarnessCore;

/// <summary>
/// Local token estimates used to explain the latest provider context. The
/// provider's usage count remains the source of truth for the total.
/// </summary>
public sealed record NativeContextUsageComposition(
    int SystemPromptTokens,
    int ConversationTokens,
    int NativeToolDefinitionTokens,
    int McpToolDefinitionTokens)
{
    public int EstimatedTotalTokens => SystemPromptTokens + ConversationTokens
        + NativeToolDefinitionTokens + McpToolDefinitionTokens;

    public static NativeContextUsageComposition Create(
        IReadOnlyList<NativeMessage> messages,
        IReadOnlyList<NativeToolDefinition> tools)
    {
        var systemPrompt = 0;
        var conversation = 0;

        foreach (var message in messages)
        {
            if (string.Equals(message.Role, "system", StringComparison.OrdinalIgnoreCase))
            {
                systemPrompt += ContextCompaction.EstimateTokens(message);
                continue;
            }

            var withoutCalls = message.ToolCalls is { Count: > 0 }
                ? message with { ToolCalls = null }
                : message;
            conversation += ContextCompaction.EstimateTokens(withoutCalls);

            if (message.ToolCalls is not { Count: > 0 } calls) continue;
            var callTokens = Math.Max(0, ContextCompaction.EstimateTokens(message)
                - ContextCompaction.EstimateTokens(withoutCalls));
            conversation += callTokens;
        }

        var nativeTools = tools.Where(tool => !tool.Name.StartsWith("mcp__", StringComparison.Ordinal)).ToArray();
        var mcpTools = tools.Where(tool => tool.Name.StartsWith("mcp__", StringComparison.Ordinal)).ToArray();
        return new NativeContextUsageComposition(
            systemPrompt,
            conversation,
            ContextCompaction.EstimateTokens(nativeTools),
            ContextCompaction.EstimateTokens(mcpTools));
    }
}
