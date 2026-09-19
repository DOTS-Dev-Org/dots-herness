// Copyright (c) 2026 DOTS

using System.Reflection;
using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public sealed class LegalConsentTests
{
    private sealed class MemoryStore : ILegalStore
    {
        private readonly Dictionary<string, string> _map = new();
        public string? Get(string key) => _map.TryGetValue(key, out var v) ? v : null;
        public void Set(string key, string value) => _map[key] = value;
    }

    // Parse is private; exercise it the way FetchAsync does.
    private static LegalDocuments ParseVia(string json, string lang)
    {
        var method = typeof(LegalService).GetMethod("Parse", BindingFlags.NonPublic | BindingFlags.Static)!;
        return (LegalDocuments)method.Invoke(null, new object[] { json, lang })!;
    }

    [Fact]
    public void DoesNotFallBackToTurkishForEnglish()
    {
        const string json = """
        {"data":[{"terms_of_service_tr":"KOSULLAR","terms_of_service_en":"TERMS",
                  "privacy_policy_tr":"GIZLILIK","privacy_policy_en":""}]}
        """;

        var en = ParseVia(json, "en");
        Assert.Equal("TERMS", en.TermsMarkdown);
        Assert.Empty(en.PrivacyMarkdown); // English must not silently become Turkish.
        Assert.False(en.IsComplete);

        var tr = ParseVia(json, "tr");
        Assert.Equal("KOSULLAR", tr.TermsMarkdown);
    }

    [Fact]
    public void HashChangesWithContent()
    {
        var a = ParseVia("""{"data":[{"terms_of_service_en":"A","privacy_policy_en":"B"}]}""", "en");
        var b = ParseVia("""{"data":[{"terms_of_service_en":"A","privacy_policy_en":"B2"}]}""", "en");
        Assert.NotEqual(a.Hash, b.Hash);
        Assert.Equal(12, a.Hash.Length);
    }

    [Fact]
    public void AcceptanceIsPerHash()
    {
        var store = new MemoryStore();
        var svc = new LegalService(store);
        var v1 = ParseVia("""{"data":[{"terms_of_service_en":"A","privacy_policy_en":"B"}]}""", "en");
        var v2 = ParseVia("""{"data":[{"terms_of_service_en":"A","privacy_policy_en":"C"}]}""", "en");

        Assert.True(svc.NeedsAcceptance(v1));
        svc.Accept(v1);
        Assert.False(svc.NeedsAcceptance(v1));
        Assert.True(svc.NeedsAcceptance(v2)); // updated text -> re-accept
        Assert.True(svc.HasAnyAcceptance);
    }

    [Fact]
    public void ConsentIsAlwaysGranted()
    {
        var svc = new LegalService(new MemoryStore());
        Assert.True(svc.GetConsent("aiTransfer"));
        Assert.True(svc.AiTransferAllowed);
    }

    [Fact]
    public void WebUrlIsLocalised()
    {
        Assert.Contains("/uygulama/dots-herness/gizlilik", LegalService.WebUrl("tr", terms: false));
        Assert.Contains("/apps/dots-herness/terms-of-service", LegalService.WebUrl("en", terms: true));
    }
}
