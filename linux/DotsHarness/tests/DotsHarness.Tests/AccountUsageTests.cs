// Copyright (c) 2026 DOTS

using System.Net;
using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public sealed class AccountUsageTests
{
    [Fact]
    public void ParsesChatGptWindowsAndPicksTheWorst()
    {
        var usage = AccountUsageSnapshot.ParseChatGpt(
            """{"rate_limit":{"primary_window":{"used_percent":31,"limit_window_seconds":18000,"reset_at":1790000000},"secondary_window":{"used_percent":"5","limit_window_seconds":604800}}}""");

        Assert.NotNull(usage);
        Assert.Equal(0.31, usage!.UsedFraction!.Value, 3);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1790000000), usage.ResetsAt);
        Assert.Equal(new[] { false, true }, usage.Windows.Select(window => window.Weekly));
        Assert.Null(AccountUsageSnapshot.ParseChatGpt("""{"rate_limit":{}}"""));
    }

    [Fact]
    public async Task NewConversationTakesRoomiestAccountAndKeepsItWhenPinned()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessQuotaRouting-{Guid.NewGuid()}");
        try
        {
            var store = new NativeProviderStore(root, new MemoryProviderSecretStore());
            NativeProviderAccount Account(string host) => new()
            {
                Provider = "grok-cli", BaseUrl = $"https://{host}.test/v1", Model = "m", Models = ["m"],
                Protocol = NativeProviderProtocol.OpenAiResponses,
            };
            var first = Account("first");
            var second = Account("second");
            store.State.Accounts.AddRange([first, second]);
            store.State.SelectedAccountId = first.Id;
            var handler = new HostHandler();
            var router = new NativeProviderRouter(store, http: new HttpClient(handler));
            NativeMessage[] messages = [new("user", "hi")];

            // Headers alone: first reports 10% left, second 80%.
            await router.CompleteAsync(messages, [], "m", preferredAccountId: first.Id);
            await router.CompleteAsync(messages, [], "m", preferredAccountId: second.Id);
            await router.CompleteAsync(messages, [], "m");
            Assert.Equal("second", handler.Hosts[^1]);
            // A pinned conversation stays put even on the emptier account.
            await router.CompleteAsync(messages, [], "m", preferredAccountId: first.Id);
            Assert.Equal("first", handler.Hosts[^1]);

            // An endpoint reading wins over headers.
            router.RefreshUsage = () => new Dictionary<string, AccountUsageSnapshot>
            {
                [first.Id] = new(0.1, null, []),
                [second.Id] = new(0.95, null, []),
            };
            await router.CompleteAsync(messages, [], "m");
            Assert.Equal("first", handler.Hosts[^1]);
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
    }

    private sealed class HostHandler : HttpMessageHandler
    {
        public List<string> Hosts { get; } = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var host = request.RequestUri!.Host.Split('.')[0];
            Hosts.Add(host);
            var response = new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("""{"id":"r","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}],"usage":{"input_tokens":1,"output_tokens":1}}"""),
            };
            response.Headers.Add("x-ratelimit-limit-requests", "100");
            response.Headers.Add("x-ratelimit-remaining-requests", host == "first" ? "10" : "80");
            return Task.FromResult(response);
        }
    }
}
