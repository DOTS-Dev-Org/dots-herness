using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public sealed class LocalizationTests
{
    [Fact]
    public void SupportedLanguageMetadataIsComplete()
    {
        Assert.Equal(30, AppLanguages.Supported.Count);
        Assert.Equal(30, AppLanguages.Supported.Select(language => language.Code()).Distinct(StringComparer.Ordinal).Count());
        Assert.Equal(
            new[] { AppLanguage.Arabic, AppLanguage.Urdu, AppLanguage.Persian },
            AppLanguages.Supported.Where(language => language.IsRightToLeft()).ToArray());
        Assert.Equal("zh-CN", AppLanguage.SimplifiedChinese.CultureName());
    }

    [Fact]
    public void ResourceFallbackAndFormattingWorkForEveryLanguage()
    {
        var localization = new LocalizationService();
        foreach (var language in AppLanguages.Supported)
        {
            localization.SetLanguage(language);
            Assert.NotEqual("settings.language", localization.Get("settings.language"));
            Assert.Contains("value", localization.Get("conversation.error", "value"));
        }
    }

    [Fact]
    public void LanguageCodesRoundTrip()
    {
        foreach (var language in AppLanguages.All)
        {
            Assert.True(AppLanguages.TryParse(language.Code(), out var parsed));
            Assert.Equal(language, parsed);
        }
    }
}
