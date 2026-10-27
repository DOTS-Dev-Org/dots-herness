using Xunit;

namespace DotsHarness.Tests;

public class RouterContextWindowTests
{
    [Theory]
    [InlineData("claude", "claude-haiku-5-5")]
    [InlineData("anthropic", "claude-haiku-5-5")]
    [InlineData("claude", "anthropic/claude-haiku-5-5")]
    public void ClaudeHaiku55UsesDocumentedMillionTokenWindow(string provider, string model)
    {
        Assert.Equal(1_000_000, DotsHarnessCore.RouterCatalog.DocumentedContextWindow(provider, model));
    }

    [Fact]
    public void OtherClaudeModelsDoNotInheritHaiku55ContextWindow()
    {
        Assert.Null(DotsHarnessCore.RouterCatalog.DocumentedContextWindow("claude", "claude-haiku-4-5"));
    }
}
