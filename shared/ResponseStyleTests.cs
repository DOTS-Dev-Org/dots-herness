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

    [Fact]
    public void SettingsPreferenceIsRuntimeSourceAndNumericLimitIsOnlyTurnOverride()
    {
        Assert.Equal(AgentResponseStyle.Concise, ResponseStyleResolver.Resolve(AgentResponseStylePreference.Concise, "kısaca").Style);
        Assert.Equal(AgentResponseStyle.Detailed, ResponseStyleResolver.Resolve(AgentResponseStylePreference.Detailed, "kısaca").Style);
        Assert.Equal(AgentResponseStyle.Strict, ResponseStyleResolver.Resolve(AgentResponseStylePreference.Balanced, "en fazla 200 token").Style);
        Assert.Contains("Concise", ResponseStyleResolver.Resolve(AgentResponseStylePreference.Concise, null).Guidance);
    }
}
