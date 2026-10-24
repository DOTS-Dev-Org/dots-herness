using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public sealed class ResponseStyleTests
{
    [Theory]
    [InlineData("Kısaca ver", AgentResponseStyle.Concise)]
    [InlineData("Özetle ve az token kullan", AgentResponseStyle.Concise)]
    [InlineData("Use fewer tokens", AgentResponseStyle.Concise)]
    [InlineData("Caveman gibi, çok kısa", AgentResponseStyle.Ultra)]
    public void DetectsShortResponseRequests(string prompt, AgentResponseStyle expected)
    {
        Assert.Equal(expected, ResponseStyleDetector.Detect(prompt).Style);
    }

    [Theory]
    [InlineData("Kısa cevap verme, detaylı anlat")]
    [InlineData("Do not be brief; explain in detail")]
    public void DetailRequestDisablesShortMode(string prompt)
    {
        Assert.Equal(AgentResponseStyle.Standard, ResponseStyleDetector.Detect(prompt).Style);
    }

    [Fact]
    public void NumericTokenLimitIsStrict()
    {
        var decision = ResponseStyleDetector.Detect("En fazla 200 token kullan");

        Assert.Equal(AgentResponseStyle.Strict, decision.Style);
        Assert.Equal(200, decision.MaxOutputTokens);
        Assert.True(decision.IsHardLimit);
    }

    [Fact]
    public void NumericWordLimitIsStrict()
    {
        var decision = ResponseStyleDetector.Detect("100 kelimeyi geçme");

        Assert.Equal(AgentResponseStyle.Strict, decision.Style);
        Assert.Equal(100, decision.MaxWords);
    }

    [Fact]
    public void StrictLimitExposesAProviderCapWithoutExpansion()
    {
        var decision = ResponseStyleDetector.Detect("En fazla 200 token kullan");

        Assert.True(decision.IsHardLimit);
        Assert.Equal(200, decision.ProviderOutputTokenCap);
        Assert.Contains("Do not exceed 200 output tokens", decision.Guidance);
        Assert.Contains("say what is missing", decision.Guidance);
        Assert.DoesNotContain("shortest complete", decision.Guidance);
    }

    [Theory]
    [InlineData("Başlığı 5 kelime yap")]
    [InlineData("Add 2 words to the commit message")]
    [InlineData("Add a 512 token limit to the prompt builder")]
    [InlineData("Bu isteğin maliyeti 3 token")]
    [InlineData("Set the max_tokens limit to 512 tokens")]
    public void BareCountsInTaskRequestsAreNotLimits(string prompt)
    {
        Assert.Null(ResponseStyleDetector.DetectLimit(prompt));
        Assert.Equal(AgentResponseStyle.Standard, ResponseStyleDetector.Detect(prompt).Style);
    }

    [Theory]
    [InlineData("200 token ile sınırla", 200, null)]
    [InlineData("Keep it under 50 words", null, 50)]
    [InlineData("max 80 words", null, 80)]
    public void CountsWithALimitCueStillApply(string prompt, int? tokens, int? words)
    {
        var decision = ResponseStyleDetector.DetectLimit(prompt);

        Assert.NotNull(decision);
        Assert.Equal(tokens, decision.Value.MaxOutputTokens);
        Assert.Equal(words, decision.Value.MaxWords);
    }

    [Fact]
    public void WordLimitsStayInThePromptWithoutProviderCap()
    {
        var words = ResponseStyleDetector.Detect("100 kelimeyi geçme");

        Assert.Equal(100, words.MaxWords);
        Assert.Null(words.ProviderOutputTokenCap);
        Assert.Equal(200, ResponseStyleDetector.Detect("En fazla 200 token kullan").ProviderOutputTokenCap);
    }

    [Fact]
    public void DarkCockpitKeepsRequestedResultsAndRequiredProgress()
    {
        var guidance = new ResponseStyleDecision(AgentResponseStyle.Ultra).Guidance;

        Assert.Contains("including passing checks", guidance);
        Assert.Contains("requested result", guidance);
        Assert.Contains("progress updates", guidance);
        Assert.Contains("optional diagram", guidance);
        Assert.DoesNotContain("never narrate", guidance);
    }

    [Fact]
    public void SettingsPreferenceIsRuntimeSourceAndNumericLimitIsOnlyTurnOverride()
    {
        Assert.Equal(AgentResponseStyle.Concise, ResponseStyleResolver.Resolve(AgentResponseStylePreference.Concise, "kısaca").Style);
        Assert.Equal(AgentResponseStyle.Detailed, ResponseStyleResolver.Resolve(AgentResponseStylePreference.Detailed, "kısaca").Style);
        Assert.Equal(AgentResponseStyle.Strict, ResponseStyleResolver.Resolve(AgentResponseStylePreference.Balanced, "en fazla 200 token").Style);
        Assert.Contains("Concise", ResponseStyleResolver.Resolve(AgentResponseStylePreference.Concise, null).Guidance);
    }
}
