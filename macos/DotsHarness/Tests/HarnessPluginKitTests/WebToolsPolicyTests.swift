// Copyright (c) 2026 DOTS
// web_fetch and web_search policy tests.

import XCTest
import Foundation
import HarnessPluginKit
@testable import DotsHarnessCore

/// The address table is the security boundary of `web_fetch`: a read-only tool
/// that can reach 127.0.0.1 is a write path against whatever the user runs
/// locally. These cases are the ones a bypass would take, so they are checked
/// without any network involved.
final class WebToolsPolicyTests: XCTestCase {
    private func v4(_ text: String) -> [UInt8]? { WebTools.ipv4Bytes(text) }

    // MARK: - IPv4

    func testPrivateAndReservedIPv4RangesAreBlocked() throws {
        let blocked = [
            "0.0.0.0", "10.0.0.1", "10.255.255.255", "127.0.0.1", "127.8.9.10",
            "100.64.0.1", "100.127.255.255", "169.254.1.1", "172.16.0.1", "172.31.255.255",
            "192.168.1.1", "192.0.0.4", "198.18.0.1", "198.19.0.1", "198.0.0.1",
            "203.0.113.9", "224.0.0.1", "239.10.10.10", "240.0.0.1", "255.255.255.255",
        ]
        for address in blocked {
            let bytes = try XCTUnwrap(v4(address), "not parsed as IPv4: \(address)")
            XCTAssertEqual(WebTools.isPublicIPv4(bytes), false, "\(address) must be blocked")
        }
    }

    func testPublicIPv4AddressesAreAllowed() {
        for address in ["8.8.8.8", "1.1.1.1", "172.32.0.1", "100.63.0.1", "100.128.0.1", "192.169.1.1", "203.0.114.1"] {
            let bytes = WebTools.ipv4Bytes(address) ?? []
            XCTAssertEqual(WebTools.isPublicIPv4(bytes), true, "\(address) must be allowed")
        }
    }

    func testMalformedIPv4IsNotParsedAsAnAddress() {
        XCTAssertNil(v4("8.8.8"))
        XCTAssertNil(v4("8.8.8.8.8"))
        XCTAssertNil(v4("256.1.1.1"))
        XCTAssertNil(v4("example.com"))
        XCTAssertNil(v4(""))
    }

    // MARK: - IPv6

    func testLoopbackAndLocalIPv6AreBlocked() {
        for address in ["::1", "::", "fe80::1", "fc00::1", "fd12:3456::78", "ff02::1", "100::1", "2001:db8::1"] {
            let bytes = WebTools.ipv6Bytes(address)
            XCTAssertNotNil(bytes, "\(address) should parse")
            XCTAssertEqual(WebTools.isPublicIPv6(bytes ?? []), false, "\(address) must be blocked")
        }
    }

    func testIPv4MappedAndSixToFourAddressesInheritTheIPv4Rule() {
        XCTAssertEqual(WebTools.isPublicIPv6(WebTools.ipv6Bytes("::ffff:127.0.0.1") ?? []), false)
        XCTAssertEqual(WebTools.isPublicIPv6(WebTools.ipv6Bytes("::ffff:8.8.8.8") ?? []), true)
        // 2002:7f00:0001:: is 127.0.0.1 in 6to4 form.
        XCTAssertEqual(WebTools.isPublicIPv6(WebTools.ipv6Bytes("2002:7f00:1::") ?? []), false)
        XCTAssertEqual(WebTools.isPublicIPv6(WebTools.ipv6Bytes("2001:4860:4860::8888") ?? []), true)
    }

    // MARK: - Names and URLs

    func testLocalHostNameSuffixesAreListed() {
        for suffix in ["localhost", "local", "internal", "onion"] {
            XCTAssertTrue(WebTools.blockedNameSuffixes.contains(suffix), suffix)
        }
    }

    func testIsPublicURLStringCoversSchemeAndAddress() {
        XCTAssertTrue(WebTools.isPublicURLString("https://docs.swift.org/documentation"))
        XCTAssertFalse(WebTools.isPublicURLString("http://127.0.0.1:8080/admin"))
        XCTAssertFalse(WebTools.isPublicURLString("http://169.254.169.254/latest/meta-data/"))
        XCTAssertFalse(WebTools.isPublicURLString("file:///etc/passwd"))
        XCTAssertFalse(WebTools.isPublicURLString("ftp://example.com/pub"))
        XCTAssertFalse(WebTools.isPublicURLString("http://redis.internal:6379"))
        XCTAssertFalse(WebTools.isPublicURLString("not a url"))
    }

    func testLiteralPrivateHostsAreRejectedWithoutResolution() async {
        for string in [
            "http://127.0.0.1/admin", "http://[::1]:9200/", "http://192.168.0.1/",
            "http://localhost:3000/", "http://100.64.1.2/", "gopher://example.com/",
        ] {
            do {
                try await WebTools.requirePublicURL(URL(string: string)!)
                XCTFail("\(string) should have been refused")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty, string)
            }
        }
    }

    // MARK: - Search result parsing

    func testDuckDuckGoRedirectWrapperIsUnwrappedToTheRealHost() {
        let wrapped = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fdocs.rs%2Fserde%2Fserde&rut=abc"
        XCTAssertEqual(WebTools.duckDuckGoTarget(in: wrapped), "https://docs.rs/serde/serde")
        XCTAssertEqual(WebTools.duckDuckGoTarget(in: "https://example.com/a"), "https://example.com/a")
    }

    func testDuckDuckGoHTMLBecomesRankedResults() {
        let html = """
        <div class="result">
          <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fdocs">Example &amp; Docs</a>
          <a class="result__snippet" href="#">A &quot;snippet&quot; with entities.</a>
        </div>
        <div class="result">
          <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=http%3A%2F%2F127.0.0.1%2Fadmin">Local</a>
          <a class="result__snippet" href="#">must be dropped</a>
        </div>
        """
        let results = WebTools.parseDuckDuckGo(html: html, maxResults: 5)
        XCTAssertEqual(results.count, 1, "the loopback result must not be offered back to the agent")
        XCTAssertEqual(results.first?.title, "Example & Docs")
        XCTAssertEqual(results.first?.url, "https://example.com/docs")
        XCTAssertEqual(results.first?.snippet, "A \"snippet\" with entities.")
    }

    // MARK: - HTML reduction

    func testScriptStyleAndChromeNeverReachTheModel() {
        let html = """
        <html><head><title>Guide</title><style>p {color: red}</style></head>
        <body><nav>Home About</nav><script>alert(1)</script>
        <main><h1>Setup</h1><p>Run <code>npm install</code> first.</p></main>
        <footer>Copyright</footer></body></html>
        """
        let text = HTMLText.extract(from: html)
        XCTAssertTrue(text.contains("Setup"), text)
        XCTAssertTrue(text.contains("npm install"), text)
        XCTAssertFalse(text.contains("alert(1)"), text)
        XCTAssertFalse(text.contains("color: red"), text)
        XCTAssertFalse(text.contains("Home About"), text)
        XCTAssertFalse(text.contains("Copyright"), text)
        XCTAssertTrue(text.hasPrefix("# Guide"), text)
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

    func testEntitiesAreDecodedOnceAndAmpersandLast() {
        XCTAssertEqual(WebText.decodeEntities("a &amp;&lt;b&gt; &nbsp;c"), "a &<b>  c")
        XCTAssertEqual(WebText.decodeEntities("&#65;&#x42;"), "AB")
        // A decoded payload must not be decoded again: "&amp;#65;" is the text
        // "&#65;", not "A".
        XCTAssertEqual(WebText.decodeEntities("&amp;#65;"), "&#65;")
    }

    func testListItemsBecomeLines() {
        let text = HTMLText.extract(from: "<ul><li>one</li><li>two</li></ul>")
        XCTAssertTrue(text.contains("- one"), text)
        XCTAssertTrue(text.contains("- two"), text)
    }

    func testRawHTMLExactFormatIsPreservedForHtmlRequests() {
        let html = "<main><p>keep me</p></main>"
        let text = HTMLText.extract(from: html, format: .html)
        XCTAssertTrue(text.contains("<p>"), text)
    }

    // MARK: - Budgets and wiring

    func testLongBodiesAreClippedForTheModel() {
        let long = String(repeating: "x", count: WebTools.maxTextCharacters + 500)
        XCTAssertEqual(WebTools.clippedForModel(long).count, WebTools.maxTextCharacters)
        XCTAssertEqual(WebTools.clippedForModel("short"), "short")
    }

    func testBothWebToolsAreOffered() {
        let names = Set(WebTools.definitions.map(\.name))
        XCTAssertEqual(names, ["web_fetch", "web_search"])
        XCTAssertTrue(WebTools.isWebTool("web_fetch"))
        XCTAssertFalse(WebTools.isWebTool("run_command"))
    }

    func testWebToolsAreReadOnlyInRiskAndPlanMode() {
        XCTAssertEqual(NativeAgentHost.risk("web_fetch"), .readOnly)
        XCTAssertEqual(NativeAgentHost.risk("web_search"), .readOnly)
        XCTAssertFalse(NativeAgentHost.planWithholds("web_fetch"))
    }

    func testMissingArgumentsFailInsteadOfThrowing() async {
        let fetch = await WebTools.execute(AgentToolCall(id: "1", name: "web_fetch", arguments: "{}"))
        XCTAssertTrue(fetch.contains("url is required"), fetch)
        let search = await WebTools.execute(AgentToolCall(id: "2", name: "web_search", arguments: #"{"query":"  "}"#))
        XCTAssertTrue(search.contains("query is required"), search)
        let broken = await WebTools.execute(AgentToolCall(id: "3", name: "web_fetch", arguments: "not json"))
        XCTAssertTrue(broken.contains("invalid JSON"), broken)
    }

    func testSearchWithoutAKeyNeverSilentlyChangesProvider() {
        UserDefaults.standard.set("brave", forKey: "web.search.provider")
        UserDefaults.standard.set("", forKey: "web.search.apiKey")
        defer {
            UserDefaults.standard.removeObject(forKey: "web.search.provider")
            UserDefaults.standard.removeObject(forKey: "web.search.apiKey")
        }
        XCTAssertEqual(WebTools.configuredBackend(), .brave)
    }
}
