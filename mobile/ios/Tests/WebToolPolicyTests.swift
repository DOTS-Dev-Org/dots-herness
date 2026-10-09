import Foundation
import XCTest
@testable import HerNessMobile

/// The address table is the whole security story for the only two tools that open
/// a socket. Every case here is decided locally: no request leaves, and no name is
/// ever sent to a resolver — the named-host rows are the ones that stop before
/// resolution (blocked suffixes) or that only read the literal syntax.
final class WebToolPolicyTests: XCTestCase {

    // MARK: - Scheme and host shape

    func testSchemesThatAreNotHTTPorHTTPSAreRefused() async {
        for scheme in ["file", "ftp", "gopher", "blob"] {
            guard let url = URL(string: "\(scheme)://example.com/x") else {
                return XCTFail("\(scheme)://example.com/x did not parse")
            }
            await assertRejection(url, .unsupportedScheme(scheme))
        }
    }

    func testHTTPAndHTTPSSchemesAreAcceptedForAPublicLiteral() async throws {
        for scheme in ["http", "https"] {
            try await assertAccepted(try XCTUnwrap(URL(string: "\(scheme)://8.8.8.8/index.html")))
        }
    }

    func testLocalAndInfrastructureNameSuffixesNeverReachTheResolver() async throws {
        for name in [
            "localhost", "api.localhost", "printer.local", "registry.internal",
            "host.localdomain", "router.home.arpa", "docs.test", "vault.localnet", "hidden.onion",
        ] {
            await assertRejection(try XCTUnwrap(URL(string: "http://\(name)/")), .blockedHost(name))
        }
    }

    // MARK: - IPv4

    func testPrivateAndReservedIPv4Blocks() {
        let refused = [
            "0.0.0.0", "0.255.255.255",
            "10.0.0.1", "10.255.255.255",
            "127.0.0.1", "127.8.8.8",
            "100.64.0.1", "100.127.255.255",
            "169.254.169.254", "169.254.1.1",
            "172.16.0.1", "172.24.5.6", "172.31.255.255",
            "192.168.0.1", "192.168.100.2",
            "192.0.0.1", "192.0.0.255",
            "198.0.0.1", "198.0.51.100",
            "198.18.0.1", "198.19.255.255",
            "203.0.113.9",
            "224.0.0.1", "239.255.255.255", "255.255.255.255",
        ]
        for address in refused {
            XCTAssertFalse(WebTools.isPublicIPv4(bytes(address)), "\(address) must stay unreachable")
        }
    }

    /// The addresses either side of each boundary, since a range written one byte
    /// off would block the public internet or leak a private host.
    func testIPv4BoundaryAddressesStayPublic() {
        let allowed = [
            "1.1.1.1", "8.8.8.8", "93.184.216.34",
            "100.63.255.255", "100.128.0.1",
            "169.253.0.1", "169.255.255.255",
            "172.15.255.255", "172.32.0.1",
            "192.0.1.1", "192.0.3.1", "192.169.0.1",
            "198.1.0.1", "198.17.255.255", "198.20.0.1",
            "203.0.112.255", "203.0.114.1",
            "223.255.255.255",
        ]
        for address in allowed {
            XCTAssertTrue(WebTools.isPublicIPv4(bytes(address)), "\(address) is a public address")
        }
    }

    func testIPv4ParsingRejectsAnythingNotFourDecimalOctets() {
        XCTAssertEqual(WebTools.ipv4Bytes("8.8.8.8") ?? [], [8, 8, 8, 8])
        XCTAssertNil(WebTools.ipv4Bytes("8.8.8"))
        XCTAssertNil(WebTools.ipv4Bytes("8.8.8.8.8"))
        XCTAssertNil(WebTools.ipv4Bytes("256.1.1.1"))
        XCTAssertNil(WebTools.ipv4Bytes("example.com"))
        XCTAssertNil(WebTools.ipv4Bytes(""))
        // Leading zeros are the octal-ambiguity case the strict helper exists for;
        // a lone zero is still a plain octet and is rejected later, by the range table.
        XCTAssertNil(WebTools.ipv4BytesStrict("010.0.0.1"))
        XCTAssertNil(WebTools.ipv4BytesStrict("08.8.8.8"))
        XCTAssertEqual(WebTools.ipv4BytesStrict("0.0.0.0") ?? [], [0, 0, 0, 0])
        XCTAssertFalse(WebTools.isPublicIPv4(WebTools.ipv4BytesStrict("0.0.0.0") ?? [1]))
        XCTAssertEqual(WebTools.ipv4BytesStrict("8.8.8.8") ?? [], [8, 8, 8, 8])
    }

    func testPrivateIPv4LiteralsAreRefusedAsURLs() async throws {
        for address in ["127.0.0.1", "10.1.2.3", "169.254.169.254", "192.168.1.1", "100.64.0.1"] {
            await assertRejection(
                try XCTUnwrap(URL(string: "http://\(address):8788/admin")),
                .blockedHost(address)
            )
        }
    }

    // MARK: - IPv6

    func testPrivateAndReservedIPv6Blocks() throws {
        let refused = [
            // The discard-only block is refused as the whole 100::/10 neighbourhood
            // the mask covers, which is deliberately wider than 100::/64.
            "::", "::1", "fe80::1", "fc00::1", "fd12:3456::78", "ff02::1", "ff00::",
            "2001:db8::1", "100::1", "100:0:0:1::", "100:1::", "103::1",
            "::ffff:127.0.0.1", "::ffff:10.0.0.1", "2002:7f00:1::",
        ]
        for address in refused {
            XCTAssertNotNil(WebTools.ipv6Bytes(address), "\(address) should parse")
            XCTAssertFalse(WebTools.isPublicIPv6(try XCTUnwrap(WebTools.ipv6Bytes(address))), "\(address) must stay unreachable")
        }
    }

    func testGlobalIPv6AddressesStayPublic() throws {
        let allowed = [
            "2606:4700:4700::1111", "2a00:1450:4001:800::200e", "2001:4860:4860::8888",
            "::ffff:8.8.8.8", "2002:0808:0808::", "1400::1",
        ]
        for address in allowed {
            XCTAssertTrue(WebTools.isPublicIPv6(try XCTUnwrap(WebTools.ipv6Bytes(address))), "\(address) is a public address")
        }
    }

    func testBracketedLoopbackURLIsRefused() async throws {
        await assertRejection(
            try XCTUnwrap(URL(string: "http://[::1]:8788/admin")),
            .blockedHost("::1")
        )
    }

    // MARK: - The unresolving string check used on search results

    func testIsPublicURLStringChecksSyntaxAndLiteralsOnly() {
        XCTAssertTrue(WebTools.isPublicURLString("https://example.com/docs"))
        XCTAssertTrue(WebTools.isPublicURLString("http://8.8.8.8/"))
        XCTAssertFalse(WebTools.isPublicURLString("file:///etc/passwd"))
        XCTAssertFalse(WebTools.isPublicURLString("https://localhost:8788/"))
        XCTAssertFalse(WebTools.isPublicURLString("http://169.254.169.254/latest/meta-data/"))
        XCTAssertFalse(WebTools.isPublicURLString("http://100.64.0.1/"))
        XCTAssertFalse(WebTools.isPublicURLString("not a url"))
    }

    // MARK: - Redirects

    func testRedirectLocationIsResolvedAgainstTheCurrentHop() throws {
        let base = try XCTUnwrap(URL(string: "https://example.com/a"))
        XCTAssertEqual(
            response(302, ["Location": "/b"]).flatMap { WebTools.redirectTarget(from: $0, from: base) }?.absoluteString,
            "https://example.com/b"
        )
        XCTAssertEqual(
            response(301, ["Location": "https://other.example/c"]).flatMap { WebTools.redirectTarget(from: $0, from: base) }?.absoluteString,
            "https://other.example/c"
        )
        // A 200 is not a redirect, and an empty Location is not either.
        XCTAssertNil(response(200, ["Location": "/b"]).flatMap { WebTools.redirectTarget(from: $0, from: base) })
        XCTAssertNil(response(302, ["Location": "  "]).flatMap { WebTools.redirectTarget(from: $0, from: base) })
        XCTAssertNil(response(302, [:]).flatMap { WebTools.redirectTarget(from: $0, from: base) })
    }

    func testRedirectBudgetMatchesTheToolLimit() {
        XCTAssertEqual(WebTools.maxRedirects, 5)
        XCTAssertEqual(WebTools.maxResponseBytes, 2_000_000)
        XCTAssertEqual(WebTools.maxTextCharacters, 24_000)
        XCTAssertEqual(Int(WebTools.requestTimeout), 20)
    }

    // MARK: - Clipping and text reduction

    func testClipNoteOnlyAppearsPastTheCharacterBudget() throws {
        let exact = String(repeating: "a", count: WebTools.maxTextCharacters)
        XCTAssertEqual(WebTools.clippedForModel(exact).count, WebTools.maxTextCharacters)
        let longer = exact + "b"
        XCTAssertEqual(WebTools.clippedForModel(longer).count, WebTools.maxTextCharacters)
        let rendered = WebTools.render(
            page: page("https://example.com/x", contentType: "text/plain", bytes: longer.utf8.count),
            body: longer
        )
        XCTAssertTrue(rendered.hasSuffix("[Truncated at 24000 characters. Narrow the URL or ask for a specific section.]"))
        XCTAssertTrue(rendered.hasPrefix("web_fetch: https://example.com/x (text/plain, 24001 bytes)"))
    }

    func testEmptyExtractionBlamesJavaScriptNotTheFetcher() throws {
        let rendered = WebTools.render(
            page: page("https://example.com/spa", contentType: "text/html", bytes: 0),
            body: "   "
        )
        XCTAssertEqual(rendered, "web_fetch: https://example.com/spa returned no readable text. The page is probably rendered by JavaScript.")
    }

    func testHTMLExtractionPrefersTheMainRegionAndDropsChrome() {
        let html = """
            <html><head><title>Guide</title><style>b{color:red}</style></head>
            <body><nav><a href="/">Home</a></nav>
            <main><h1>Install</h1><p>Run <code>make</code> twice.</p></main>
            <aside>Cookie notice</aside><footer>Copyright</footer></body></html>
            """
        let text = HTMLText.extract(from: html)
        XCTAssertTrue(text.hasPrefix("# Guide\n\n"), "title should head the extraction, got: \(text)")
        XCTAssertTrue(text.contains("Run make twice."))
        XCTAssertFalse(text.contains("Cookie notice"))
        XCTAssertFalse(text.contains("Copyright"))
        XCTAssertFalse(text.contains("color:red"))
    }

    func testHTMLFormatKeepsMarkupButCollapsesIt() {
        let html = "<main><p>One   two</p></main>"
        XCTAssertEqual(HTMLText.extract(from: html, format: .html), "<main><p>One two</p></main>")
    }

    // MARK: - Search result plumbing

    func testDuckDuckGoWrapperIsUnwrappedAndPrivateTargetsAreDropped() {
        XCTAssertEqual(
            WebTools.duckDuckGoTarget(in: "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fdocs&rut=abc"),
            "https://example.com/docs"
        )
        XCTAssertEqual(
            WebTools.duckDuckGoTarget(in: "https://duckduckgo.com/l/?uddg=http%3A%2F%2F127.0.0.1%3A8788%2Fadmin"),
            "http://127.0.0.1:8788/admin"
        )
        XCTAssertEqual(WebTools.duckDuckGoTarget(in: "https://example.com/straight"), "https://example.com/straight")
    }

    func testDuckDuckGoParsingNeverSurfacesAPrivateTarget() {
        let html = """
            <div class="result__body"><h2><a class="result__a" href="https://example.com/ok">Example</a></h2>
            <a class="result__snippet" href="#">A &amp; B</a></div>
            <div class="result__body"><h2><a class="result__a" href="http://169.254.169.254/latest/meta-data/">Metadata</a></h2>
            <a class="result__snippet" href="#">steal</a></div>
            <div class="result__body"><h2><a class="result__a" href="https://localhost:8788/x">Local</a></h2></div>
            """
        let results = WebTools.parseDuckDuckGo(html: html, maxResults: 10)
        XCTAssertEqual(results.map(\.url), ["https://example.com/ok"])
        XCTAssertEqual(results.first?.title, "Example")
        XCTAssertEqual(results.first?.snippet, "A & B")
    }

    func testDuckDuckGoTitlesArriveAsTextNotAsMarkup() {
        let html = """
            <div class="result">
              <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fdocs">Example &amp; Docs</a>
              <a class="result__snippet" href="#">A &quot;snippet&quot; with entities.</a>
            </div>
            """
        let result = try? XCTUnwrap(WebTools.parseDuckDuckGo(html: html, maxResults: 5).first)
        XCTAssertEqual(result?.title, "Example & Docs")
        XCTAssertEqual(result?.snippet, "A \"snippet\" with entities.")
    }

    func testEntitiesAreDecodedOnceAndAmpersandLast() {
        XCTAssertEqual(WebText.decodeEntities("a &amp;&lt;b&gt; &nbsp;c"), "a &<b>  c")
        XCTAssertEqual(WebText.decodeEntities("&#65;&#x42;"), "AB")
        // A decoded payload must not be decoded again: "&amp;#65;" is the text
        // "&#65;", not "A".
        XCTAssertEqual(WebText.decodeEntities("&amp;#65;"), "&#65;")
    }

    func testBlankLineCollapseKeepsNewlinesAsNewlines() {
        // A live MDN page came back with literal "nn" in place of every collapsed
        // blank run, because the ICU replacement template read "\n" as an escape.
        XCTAssertEqual(WebText.collapse("a\n\n\n\n\nb"), "a\n\nb")
        let text = HTMLText.extract(from: "<main><p>one</p><p>two</p></main>")
        XCTAssertFalse(text.contains("nn"), text)
        XCTAssertTrue(text.contains("one"), text)
        XCTAssertTrue(text.contains("two"), text)
    }

    func testSearchResultRenderingIsStable() async {
        let rendered = WebTools.renderResults(query: "swift glob", results: [
            WebTools.SearchResult(title: "Docs", url: "https://example.com/docs", snippet: "Patterns"),
        ])
        XCTAssertEqual(rendered, """
            web_search: swift glob
            1. Docs
               https://example.com/docs
               Patterns

            Use web_fetch to read a result you need in full.
            """)
    }

    /// With no key configured the tool must still answer through the keyless
    /// backend rather than falling silent.
    func testKeylessDefaultIsDuckDuckGo() throws {
        guard WebTools.searchAPIKey().isEmpty, WebTools.configuredBackendName() == nil else {
            throw XCTSkip("A search key is configured in this environment")
        }
        XCTAssertEqual(WebTools.configuredBackend(), .duckduckgo)
    }

    func testBraveBackendWithoutAKeyExplainsItself() async {
        let error = WebToolError.searchNeedsKey(backend: "brave")
        XCTAssertTrue(error.errorDescription?.contains("needs an API key") == true)
        XCTAssertTrue(error.errorDescription?.contains("duckduckgo") == true)
    }

    // MARK: - Registration surface

    func testWebToolsAreNamedAsTheDesktopNamesThem() throws {
        XCTAssertEqual(WebTools.specs.map(\.name), ["web_fetch", "web_search"])
        XCTAssertTrue(WebTools.isWebTool(WebTools.fetchName))
        XCTAssertTrue(WebTools.isWebTool(WebTools.searchName))
        XCTAssertFalse(WebTools.isWebTool("read_file"))
        for spec in WebTools.specs {
            let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: spec.schemaData) as? [String: Any])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            XCTAssertNotNil(schema["properties"])
        }
    }

    // MARK: - Helpers

    private func page(_ absolute: String, contentType: String, bytes: Int) -> WebTools.FetchedPage {
        WebTools.FetchedPage(
            url: URL(string: absolute)!,
            statusCode: 200,
            contentType: contentType,
            body: Data(repeating: 0x61, count: bytes)
        )
    }

    private func bytes(_ host: String) -> [UInt8] {
        WebTools.ipv4Bytes(host) ?? []
    }

    private func response(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse? {
        HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
    }

    private func assertAccepted(_ url: URL, file: StaticString = #file, line: UInt = #line) async {
        do {
            try await WebTools.requirePublicURL(url)
        } catch {
            XCTFail("\(url.absoluteString) should be allowed: \(error)", file: file, line: line)
        }
    }

    private func assertRejection(_ url: URL, _ expected: WebToolError, file: StaticString = #file, line: UInt = #line) async {
        do {
            try await WebTools.requirePublicURL(url)
            XCTFail("\(url.absoluteString) should have been refused", file: file, line: line)
        } catch let error as WebToolError {
            XCTAssertEqual(error, expected, "wrong refusal for \(url.absoluteString)", file: file, line: line)
        } catch {
            XCTFail("\(url.absoluteString) threw a non-tool error: \(error)", file: file, line: line)
        }
    }
}
