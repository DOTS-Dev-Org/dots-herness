using DotsHarnessCore;
using Xunit;

/// <summary>
/// The Codex `/responses` route answers as SSE. These pin the behaviour the
/// macOS client already relies on, since the C# side has no live route to try.
/// </summary>
public sealed class ResponsesStreamTests
{
    private const string TextStream = """
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Hel"}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"lo"}

        event: response.completed
        data: {"type":"response.completed","response":{"output":[],"usage":{"input_tokens":11,"output_tokens":2}}}

        data: [DONE]
        """;

    [Fact]
    public void TextComesFromDeltasAndUsageFromTheTerminalEvent()
    {
        var result = NativeProviderRouter.ParseResponsesStream(TextStream);

        Assert.Equal("Hello", result.Message.Content);
        Assert.Equal(11, result.Usage!.InputTokens);
        Assert.Equal(2, result.Usage!.OutputTokens);
    }

    [Fact]
    public void ToolCallsKeepStreamOrderAndCarryProviderItems()
    {
        const string stream = """
            data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"a","name":"read_file","arguments":"{\"path\":\"x\"}"}}

            data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"b","name":"list_files","arguments":"{}"}}

            data: {"type":"response.completed","response":{"output":[]}}
            """;

        var result = NativeProviderRouter.ParseResponsesStream(stream);

        Assert.Equal(new[] { "a", "b" }, result.Message.ToolCalls!.Select(call => call.Id).ToArray());
        Assert.Equal("read_file", result.Message.ToolCalls![0].Name);
        Assert.Equal("{\"path\":\"x\"}", result.Message.ToolCalls![0].Arguments);
        // Provider items must round-trip so the next turn can replay them.
        Assert.Equal(2, result.Message.ProviderItems!.Count);
    }

    [Fact]
    public void WholeMessageItemIsUsedWhenNoDeltasArrive()
    {
        const string stream = """
            data: {"type":"response.output_item.done","item":{"type":"message","content":[{"type":"output_text","text":"whole"}]}}

            data: {"type":"response.completed","response":{"output":[]}}
            """;

        Assert.Equal("whole", NativeProviderRouter.ParseResponsesStream(stream).Message.Content);
    }

    [Fact]
    public void PlainJsonBodyStillParses()
    {
        const string body = """
            {"output":[{"type":"message","content":[{"type":"output_text","text":"json"}]}]}
            """;

        Assert.Equal("json", NativeProviderRouter.ParseResponsesStream(body).Message.Content);
    }

    [Fact]
    public void StreamErrorEventBecomesAProviderException()
    {
        const string stream = """
            data: {"type":"response.failed","response":{"status":429,"error":{"message":"rate limit reached"}}}
            """;

        var error = Assert.Throws<NativeProviderException>(
            () => NativeProviderRouter.ParseResponsesStream(stream, "codex"));

        Assert.Equal("rate limit reached", error.Message);
        Assert.Equal(429, error.StatusCode);
        Assert.True(error.IsLimit);
        Assert.Equal("codex", error.ProviderName);
    }

    [Fact]
    public void EmptyStreamIsAnError()
    {
        const string stream = """
            data: {"type":"response.completed","response":{"output":[]}}
            """;

        Assert.Throws<NativeProviderException>(() => NativeProviderRouter.ParseResponsesStream(stream));
    }
}
