// Copyright (c) 2026 DOTS
// The address policy and the scraped-text reduction, tested without a socket: every case
// here is a table lookup or a parse, so the suite never asks a name server or a host.

using System.Net;
using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public sealed class NativeWebPolicyTests
{
    private static bool PublicV4(string dotted) =>
        NativeWebTools.IsPublicIPv4(IPAddress.Parse(dotted).GetAddressBytes());

    private static bool PublicV6(string text) => NativeWebTools.IsPublicIPv6(IPAddress.Parse(text).GetAddressBytes());

    [Theory]
    // this network, RFC 1918, loopback
    [InlineData("0.0.0.0", false)]
    [InlineData("0.255.255.255", false)]
    [InlineData("10.0.0.1", false)]
    [InlineData("127.0.0.1", false)]
    [InlineData("127.9.9.9", false)]
    // RFC 6598 CGNAT
    [InlineData("100.64.0.1", false)]
    [InlineData("100.127.255.255", false)]
    [InlineData("100.63.255.255", true)]
    [InlineData("100.128.0.1", true)]
    // link-local
    [InlineData("169.254.1.1", false)]
    [InlineData("169.253.0.1", true)]
    // RFC 1918
    [InlineData("172.16.0.1", false)]
    [InlineData("172.31.255.255", false)]
    [InlineData("172.15.255.255", true)]
    [InlineData("172.32.0.1", true)]
    // RFC 1918 plus the IETF protocol space
    [InlineData("192.168.1.1", false)]
    [InlineData("192.0.0.1", false)]
    [InlineData("192.0.1.1", true)]
    // protocol space and benchmarking
    [InlineData("198.0.0.1", false)]
    [InlineData("198.18.1.1", false)]
    [InlineData("198.19.1.1", false)]
    [InlineData("198.17.255.255", true)]
    [InlineData("198.20.0.1", true)]
    // TEST-NET-3
    [InlineData("203.0.113.5", false)]
    [InlineData("203.0.112.5", true)]
    // multicast, reserved, broadcast
    [InlineData("224.0.0.1", false)]
    [InlineData("239.1.1.1", false)]
    [InlineData("255.255.255.255", false)]
    // Ordinary answers, including the metadata endpoint's neighbours.
    [InlineData("169.254.169.254", false)]
    [InlineData("1.1.1.1", true)]
    [InlineData("8.8.8.8", true)]
    [InlineData("9.9.9.9", true)]
    [InlineData("192.0.2.1", true)]
    public void OnlyPublicIPv4RangesMayBeFetched(string address, bool expected) =>
        Assert.Equal(expected, PublicV4(address));

    [Theory]
    [InlineData("::", false)]
    [InlineData("::1", false)]
    [InlineData("fe80::1", false)]
    [InlineData("febf::1", false)]
    [InlineData("fec0::1", true)]
    [InlineData("fc00::1", false)]
    [InlineData("fd12:3456::1", false)]
    [InlineData("ff02::1", false)]
    [InlineData("2001:db8::1", false)]
    [InlineData("100::1", false)]
    [InlineData("100:3fff::1", false)]
    [InlineData("140::1", true)]
    // 6to4 carries an IPv4 address inside, so it is only public when that one is.
    [InlineData("2002:7f00:1::", false)]
    [InlineData("2002:0a00:0001::", false)]
    [InlineData("2002:0102:0304::", true)]
    // IPv4-mapped is the shape a happy-eyeballs resolver hands back for a v4 host.
    [InlineData("::ffff:127.0.0.1", false)]
    [InlineData("::ffff:10.0.0.1", false)]
    [InlineData("::ffff:0102:0304", true)]
    [InlineData("2606:4700:4700::1111", true)]
    [InlineData("2001:4860:4860::8888", true)]
    public void OnlyPublicIPv6RangesMayBeFetched(string address, bool expected) =>
        Assert.Equal(expected, PublicV6(address));

    [Fact]
    public void AnAddressOfTheWrongLengthIsNeverPublic()
    {
        Assert.False(NativeWebTools.IsPublicIPv4([1, 2, 3]));
        Assert.False(NativeWebTools.IsPublicIPv4([1, 2, 3, 4, 5]));
        Assert.False(NativeWebTools.IsPublicIPv6([0, 1, 2, 3]));
    }

    [Theory]
    [InlineData("8.8.8.8", true)]
    // Read as 10.0.0.1, exactly like the reference does, so it is shaped and private.
    [InlineData("010.0.0.1", true)]
    [InlineData("1.2.3", false)]
    [InlineData("256.1.1.1", false)]
    [InlineData("1.2.3.4.5", false)]
    [InlineData("a.b.c.d", false)]
    [InlineData("", false)]
    public void IPv4LiteralsAreParsedTheWayTheReferenceParsesThem(string host, bool shaped)
    {
        Assert.Equal(shaped, NativeWebTools.IPV4Bytes(host) is not null);
    }

    [Fact]
    public void ALeadingZeroOctetIsTheOneShapeTheStrictParserRefuses()
    {
        Assert.Equal(new byte[] { 10, 0, 0, 1 }, NativeWebTools.IPV4Bytes("010.0.0.1"));
        Assert.Null(NativeWebTools.IPV4BytesStrict("010.0.0.1"));
        Assert.Equal(new byte[] { 10, 0, 0, 1 }, NativeWebTools.IPV4BytesStrict("10.0.0.1"));
    }

    [Theory]
    [InlineData("::1", true)]
    [InlineData("2001:db8::1", true)]
    [InlineData("fe80::1", true)]
    [InlineData("::ffff:127.0.0.1", true)]
    [InlineData("8.8.8.8", false)]
    [InlineData("localhost", false)]
    [InlineData("not:an:address", false)]
    public void IPv6LiteralsOnlyParseAsThemselves(string host, bool parses) =>
        Assert.Equal(parses, NativeWebTools.IPV6Bytes(host) is { Length: 16 });

    [Theory]
    // A read-only tool must never be a way to write to whatever runs on the user's own
    // machine: the admin panel, the metadata endpoint, a Unix socket on localhost.
    [InlineData("http://127.0.0.1:8788/admin", false)]
    [InlineData("http://localhost:3000/", false)]
    [InlineData("http://api.internal/v1", false)]
    [InlineData("http://registry.test/pull", false)]
    [InlineData("http://cache.localdomain/", false)]
    [InlineData("http://hidden.home.arpa/", false)]
    [InlineData("http://onion/", false)]
    [InlineData("http://169.254.169.254/latest/meta-data/", false)]
    [InlineData("http://[::1]/", false)]
    [InlineData("http://[fd00::1]/", false)]
    [InlineData("http://[::ffff:127.0.0.1]/", false)]
    [InlineData("http://010.0.0.1/", false)]
    [InlineData("http://0177.0.0.1/", false)]
    [InlineData("file:///etc/passwd", false)]
    [InlineData("http:///no-host", false)]
    [InlineData("not a url", false)]
    [InlineData("http://example.com/", true)]
    [InlineData("https://8.8.8.8/questions", true)]
    [InlineData("https://sub.domain.example.org/a?b=c#d", true)]
    [InlineData("https://100.64.0.1/", false)]
    public void TheURLGateRejectsEverythingLocal(string url, bool allowed) =>
        Assert.Equal(allowed, NativeWebTools.IsPublicURLString(url));

    [Fact]
    public void EveryBlockedNameSuffixIsBlocked()
    {
        foreach (var suffix in NativeWebTools.BlockedNameSuffixes)
        {
            Assert.False(NativeWebTools.IsPublicURLString($"http://{suffix}/"), suffix);
            Assert.False(NativeWebTools.IsPublicURLString($"http://deep.{suffix}/"), suffix);
        }
        // A substring is not a suffix.
        Assert.True(NativeWebTools.IsPublicURLString("http://atesting.example.com/"));
    }

    [Fact]
    public void BothWebToolsAreNamedAndReadonly()
    {
        Assert.Equal(new[] { "web_fetch", "web_search" }, NativeWebTools.Definitions.Select(tool => tool.Name).ToArray());
        Assert.True(NativeWebTools.IsWebTool("web_fetch"));
        Assert.True(NativeWebTools.IsWebTool("web_search"));
        Assert.False(NativeWebTools.IsWebTool("grep_files"));
        Assert.True(NativeWebTools.IsReadOnly("web_fetch"));
        Assert.True(NativeWebTools.IsReadOnly("web_search"));
        Assert.False(NativeWebTools.IsReadOnly("run_command"));
    }

    [Fact]
    public void TheSearchToolOnlyAsksForAQueryAndACount()
    {
        var schema = NativeWebTools.SearchDefinition.Parameters.AsObject();
        Assert.Equal("query", schema["required"]!.AsArray()[0]!.GetValue<string>());
        Assert.Equal(1, schema["properties"]!.AsObject()["max_results"]!["minimum"]!.GetValue<int>());
        Assert.Equal(10, schema["properties"]!.AsObject()["max_results"]!["maximum"]!.GetValue<int>());
        Assert.False(schema["additionalProperties"]!.AsValue().GetValue<bool>());
    }

    [Fact]
    public void DuckDuckGoResultsAreUnwrappedAndPrivateTargetsAreDropped()
    {
        const string Html = """
            <ol>
              <li><h2><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fdocs&rut=abc">Example &amp; Docs</a></h2></li>
              <a class="result__snippet" href="#">The &mdash; only answer.</a>
              <li><h2><a class="result__a" href="https://duckduckgo.com/l/?uddg=http%3A%2F%2F127.0.0.1%3A8788%2Fadmin">Local</a></h2></li>
              <li><h2><a class="result__a" href="https://other.example.org/page">Plain</a></h2></li>
            </ol>
            """;
        var results = NativeWebTools.ParseDuckDuckGo(Html, 5);
        // The redirect-wrapped local target is dropped, so the agent can never be sent
        // back a link that fetches the user's own machine.
        Assert.Equal(2, results.Count);
        // A scraped title is read as text, so its entities have to resolve: "&amp;"
        // reaching the model would be a title that says "Example &amp; Docs".
        Assert.Equal("Example & Docs", results[0].Title);
        Assert.Equal("https://example.com/docs", results[0].Url);
        Assert.Equal("The \u2014 only answer.", results[0].Snippet);
        Assert.Equal("https://other.example.org/page", results[1].Url);
        Assert.Equal("", results[1].Snippet);
        Assert.Empty(NativeWebTools.ParseDuckDuckGo(Html, 0));
        // The cap counts the links the backend returned, so a dropped private target still
        // spends a slot rather than pulling a further row into the answer.
        var capped = NativeWebTools.ParseDuckDuckGo(Html, 2);
        Assert.Single(capped);
        Assert.Equal("https://example.com/docs", capped[0].Url);
        Assert.Equal("https://example.com/docs", NativeWebTools.ParseDuckDuckGo(Html, 1)[0].Url);
    }

    [Theory]
    [InlineData("//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fx", "https://example.com/x")]
    [InlineData("https://duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com", "https://example.com")]
    [InlineData("https://duckduckgo.com/l/?rut=abc", "https://duckduckgo.com/l/?rut=abc")]
    [InlineData("https://example.com/a", "https://example.com/a")]
    public void TheRedirectTargetIsUnwrapped(string href, string expected) =>
        Assert.Equal(expected, NativeWebTools.DuckDuckGoTarget(href));

    [Fact]
    public void ResultsAreClippedToTheCharacterBudget()
    {
        Assert.Equal(24_000, NativeWebTools.ClippedForModel(new string('a', 30_000)).Length);
        Assert.Equal("short", NativeWebTools.ClippedForModel("short"));
    }

    [Fact]
    public void EntitiesThatSurviveScrapingAreDecodedLastForAmpersand()
    {
        Assert.Equal("<a href=\"x\"> & b", NativeWebTools.WebText.DecodeEntities("&lt;a href=&quot;x&quot;&gt; &amp; b"));
        Assert.Equal("\u2764", NativeWebTools.WebText.DecodeEntities("&#x2764;"));
        Assert.Equal("\u2764", NativeWebTools.WebText.DecodeEntities("&#10084;"));
        // A surrogate half and an out-of-range value stay as written rather than corrupting.
        Assert.Equal("&#xD800;", NativeWebTools.WebText.DecodeEntities("&#xD800;"));
        Assert.Equal("&#x110000;", NativeWebTools.WebText.DecodeEntities("&#x110000;"));
        Assert.Equal("", NativeWebTools.WebText.DecodeEntities("&shy;"));
        // The literal "&" a decode restores must not open a second decode.
        Assert.Equal("&lt;", NativeWebTools.WebText.DecodeEntities("&amp;lt;"));
    }

    [Fact]
    public void BlankLinesCollapseIntoBlankLinesNotLetters()
    {
        // The desktop ported this bug first: a replacement template that read "\n"
        // as an escape put a literal "nn" where a paragraph break belonged.
        Assert.Equal("a\n\nb", NativeWebTools.WebText.Collapse("a\n\n\n\n\nb"));
        var text = NativeWebTools.Html.Extract("<main><p>one</p><p>two</p></main>");
        Assert.DoesNotContain("nn", text);
        Assert.Contains("one", text);
        Assert.Contains("two", text);
    }

    [Fact]
    public void MarkupBecomesTheTextAPageIsActuallyWorthReading()
    {
        const string Page = """
            <html><head><title>Docs &amp; More</title><script>var evil = 1;</script></head>
            <body><nav><a href="/home">Home</a></nav>
            <main><h1>Alpha</h1><p>Text with &mdash; dash and &lt;tags&gt;.</p>
            <ul><li>first</li><li>second</li></ul></main>
            <footer>Copyright</footer></body></html>
            """;
        var text = NativeWebTools.Html.Extract(Page);
        Assert.StartsWith("# Docs &amp; More", text, StringComparison.Ordinal);
        Assert.Contains("Text with \u2014 dash and <tags>.", text, StringComparison.Ordinal);
        Assert.Contains("- first", text, StringComparison.Ordinal);
        Assert.Contains("- second", text, StringComparison.Ordinal);
        Assert.DoesNotContain("evil", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Home", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Copyright", text, StringComparison.Ordinal);
    }

    [Fact]
    public void TheHtmlFormatKeepsTheMarkupTheTextFormatsThrowAway()
    {
        const string Page = """
            <html><head><title>T</title></head><body><h2>Heading</h2><p>Body <b>bold</b></p></body></html>
            """;
        var plain = NativeWebTools.Html.Extract(Page);
        var markdown = NativeWebTools.Html.Extract(Page, NativeWebTools.SearchFormat.Markdown);
        // Block tags are turned into line breaks before the heading pass can relabel them,
        // so markdown and plain text agree here; both keep the prose and drop the tags.
        Assert.Equal(plain, markdown);
        Assert.Contains("Heading", markdown, StringComparison.Ordinal);
        Assert.Contains("Body bold", markdown, StringComparison.Ordinal);
        Assert.DoesNotContain("<b>", markdown, StringComparison.Ordinal);
        var raw = NativeWebTools.Html.Extract(Page, NativeWebTools.SearchFormat.Html);
        Assert.Contains("<b>bold</b>", raw, StringComparison.Ordinal);
        // The body slice is what a caller asked for, so the head is out of it.
        Assert.DoesNotContain("<head>", raw, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AnArgumentTheModelCannotWriteIsAnsweredRatherThanThrown()
    {
        Assert.Equal("Tool error: invalid JSON arguments for web_fetch.",
            await NativeWebTools.ExecuteAsync(new NativeToolCall("c", "web_fetch", "not json")));
        Assert.Equal("Tool error: url is required.",
            await NativeWebTools.ExecuteAsync(new NativeToolCall("c", "web_fetch", "{}")));
        Assert.Equal("Tool error: query is required.",
            await NativeWebTools.ExecuteAsync(new NativeToolCall("c", "web_search", "{\"query\":\"  \"}")));
        Assert.Equal("Tool error: unknown web tool web_nonsense.",
            await NativeWebTools.ExecuteAsync(new NativeToolCall("c", "web_nonsense", "{}")));
    }

    [Fact]
    public async Task APrivateHostIsRefusedBeforeAnythingIsSent()
    {
        // No socket is opened for any of these: the policy runs first and answers.
        foreach (var url in new[] { "http://127.0.0.1:8788/admin", "http://localhost:3000/x", "http://[::1]/" })
        {
            var answer = await NativeWebTools.ExecuteAsync(
                new NativeToolCall("c", NativeWebTools.FetchName, $"{{\"url\":\"{url}\"}}"));
            Assert.StartsWith("web_fetch failed:", answer, StringComparison.Ordinal);
            Assert.Contains("is a local or private address", answer, StringComparison.Ordinal);
        }
        var scheme = await NativeWebTools.ExecuteAsync(
            new NativeToolCall("c", NativeWebTools.FetchName, "{\"url\":\"ftp://example.com/x\"}"));
        Assert.Equal("web_fetch failed: only http and https URLs are allowed, not ftp.", scheme);
    }

    [Fact]
    public void WithoutAKeyTheKeylessBackendAnswers()
    {
        // A machine that has configured the search backend is free to run the tool against
        // brave, so the default is only asserted where nothing is configured: a test must
        // never set a process-wide variable the other tests read.
        if (NativeWebTools.ConfiguredBackendName() is not null || NativeWebTools.SearchAPIKey().Length > 0) return;
        Assert.Equal(NativeWebTools.SearchBackend.DuckDuckGo, NativeWebTools.ConfiguredBackend());
    }
}
