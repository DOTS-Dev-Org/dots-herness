package com.dots.herness.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.net.InetAddress

/**
 * The address table is the security boundary of `web_fetch`: a read-only tool that
 * can reach 127.0.0.1 is a write path against whatever the user runs locally. These
 * cases are the ones a bypass would take, so they are checked without any network
 * involved - every refusal here happens before a socket is opened.
 */
class WebToolsPolicyTest {
    private fun v4(text: String): ByteArray? = WebTools.ipv4Bytes(text)

    // MARK: - IPv4

    @Test
    fun `blocks private and reserved IPv4 ranges`() {
        val blocked = listOf(
            "0.0.0.0", "10.0.0.1", "10.255.255.255", "127.0.0.1", "127.8.9.10",
            "100.64.0.1", "100.127.255.255", "169.254.1.1", "172.16.0.1", "172.31.255.255",
            "192.168.1.1", "192.0.0.4", "198.18.0.1", "198.19.0.1", "198.0.0.1",
            "203.0.113.9", "224.0.0.1", "239.10.10.10", "240.0.0.1", "255.255.255.255",
        )
        for (address in blocked) {
            val bytes = v4(address)
            assertNotNull("not parsed as IPv4: $address", bytes)
            assertFalse("$address must be blocked", WebTools.isPublicIPv4(bytes!!))
        }
    }

    @Test
    fun `allows public IPv4 addresses`() {
        for (address in listOf("8.8.8.8", "1.1.1.1", "172.32.0.1", "100.63.0.1", "100.128.0.1", "192.169.1.1", "203.0.114.1")) {
            assertTrue("$address must be allowed", WebTools.isPublicIPv4(v4(address)!!))
        }
    }

    @Test
    fun `does not parse malformed IPv4 as an address`() {
        listOf("8.8.8", "8.8.8.8.8", "256.1.1.1", "example.com", "").forEach { assertNull("$it parsed", v4(it)) }
    }

    /** The platform predicates stop CGNAT and benchmarking ranges: the byte table
     * is what catches them. */
    @Test
    fun `resolved answers are judged by bytes as well as by the platform predicates`() {
        assertFalse(WebTools.isPublicAddress(InetAddress.getByName("100.64.1.2")))
        assertFalse(WebTools.isPublicAddress(InetAddress.getByName("198.18.0.1")))
        assertFalse(WebTools.isPublicAddress(InetAddress.getByName("127.0.0.1")))
        assertFalse(WebTools.isPublicAddress(InetAddress.getByName("192.168.0.1")))
        assertFalse(WebTools.isPublicAddress(InetAddress.getByName("224.0.0.1")))
        assertTrue(WebTools.isPublicAddress(InetAddress.getByName("8.8.8.8")))
    }

    // MARK: - IPv6

    @Test
    fun `blocks loopback and local IPv6`() {
        for (address in listOf("::1", "::", "fe80::1", "fc00::1", "fd12:3456::78", "ff02::1", "100::1", "2001:db8::1")) {
            val bytes = WebTools.ipv6Bytes(address)
            assertNotNull("$address should parse", bytes)
            assertFalse("$address must be blocked", WebTools.isPublicIPv6(bytes!!))
        }
    }

    @Test
    fun `mapped and six-to-four addresses inherit the IPv4 rule`() {
        assertFalse(WebTools.isPublicIPv6(WebTools.ipv6Bytes("::ffff:127.0.0.1")!!))
        assertTrue(WebTools.isPublicIPv6(WebTools.ipv6Bytes("::ffff:8.8.8.8")!!))
        // 2002:7f00:0001:: is 127.0.0.1 in 6to4 form.
        assertFalse(WebTools.isPublicIPv6(WebTools.ipv6Bytes("2002:7f00:1::")!!))
        assertTrue(WebTools.isPublicIPv6(WebTools.ipv6Bytes("2001:4860:4860::8888")!!))
    }

    @Test
    fun `malformed IPv6 text is not parsed as an address`() {
        listOf("example.com", "8.8.8.8", "gggg::1", "1:2:3", "::1::2", "1:2:3:4:5:6:7:8:9").forEach {
            assertNull("$it parsed as IPv6", WebTools.ipv6Bytes(it))
        }
    }

    // MARK: - Names and URLs

    @Test
    fun `local name suffixes are listed`() {
        listOf("localhost", "local", "internal", "localdomain", "home.arpa", "test", "onion").forEach {
            assertTrue("$it missing", WebTools.blockedNameSuffixes.contains(it))
        }
        assertTrue(WebTools.isBlockedName("redis.internal"))
        assertTrue(WebTools.isBlockedName("localhost"))
        assertFalse(WebTools.isBlockedName("interneteam.com"))
    }

    @Test
    fun `public URL string covers scheme and address`() {
        assertTrue(WebTools.isPublicURLString("https://docs.swift.org/documentation"))
        assertFalse(WebTools.isPublicURLString("http://127.0.0.1:8080/admin"))
        assertFalse(WebTools.isPublicURLString("http://169.254.169.254/latest/meta-data/"))
        assertFalse(WebTools.isPublicURLString("file:///etc/passwd"))
        assertFalse(WebTools.isPublicURLString("ftp://example.com/pub"))
        assertFalse(WebTools.isPublicURLString("http://redis.internal:6379"))
        assertFalse(WebTools.isPublicURLString("not a url"))
    }

    /** Each of these must be refused before any request leaves the phone. */
    @Test
    fun `literal private hosts are refused without resolution`() {
        for ((url, expected) in listOf(
            "http://127.0.0.1/admin" to "127.0.0.1 is a local or private address",
            "http://[::1]:9200/" to "::1 is a local or private address",
            "http://192.168.0.1/" to "192.168.0.1 is a local or private address",
            "http://localhost:3000/" to "localhost is a local or private address",
            "http://100.64.1.2/" to "100.64.1.2 is a local or private address",
            "http://169.254.169.254/latest/meta-data/" to "169.254.169.254 is a local or private address",
            "gopher://example.com/" to "only http and https URLs are allowed, not gopher.",
        )) {
            val answer = WebTools.fetch(url, WebTools.SearchFormat.TEXT)
            assertTrue("$url answered: $answer", answer.startsWith("web_fetch failed: ") && answer.contains(expected))
        }
    }

    @Test
    fun `a name that is not a URL says so instead of reaching the network`() {
        assertTrue(WebTools.fetch("not a url", WebTools.SearchFormat.TEXT).contains("not a valid URL"))
        assertTrue(WebTools.fetch("", WebTools.SearchFormat.TEXT).contains("not a valid URL"))
    }

    @Test
    fun `requirePublicURL refuses the scheme before anything else`() {
        listOf("file:///etc/passwd", "ftp://example.com/pub").forEach { text ->
            val answer = WebTools.fetch(text, WebTools.SearchFormat.TEXT)
            assertTrue(text, answer.contains("only http and https URLs are allowed"))
        }
    }

    // MARK: - Search results

    @Test
    fun `duckduckgo redirect wrapper unwraps to the real host`() {
        val wrapped = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fdocs.rs%2Fserde%2Fserde&rut=abc"
        assertEquals("https://docs.rs/serde/serde", WebTools.duckDuckGoTarget(wrapped))
        assertEquals("https://example.com/a", WebTools.duckDuckGoTarget("https://example.com/a"))
    }

    @Test
    fun `duckduckgo HTML becomes ranked results`() {
        val html = """
        <div class="result">
          <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fdocs">Example &amp; Docs</a>
          <a class="result__snippet" href="#">A &quot;snippet&quot; with entities.</a>
        </div>
        <div class="result">
          <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=http%3A%2F%2F127.0.0.1%2Fadmin">Local</a>
          <a class="result__snippet" href="#">must be dropped</a>
        </div>
        """.trimIndent()
        val results = WebTools.parseDuckDuckGo(html, 5)
        assertEquals("the loopback result must not be offered back to the agent", 1, results.size)
        assertEquals("Example & Docs", results.first().title)
        assertEquals("https://example.com/docs", results.first().url)
        assertEquals("A \"snippet\" with entities.", results.first().snippet)
    }

    /**
     * Backends are chosen by configuration, never by silence, and the refusal a
     * keyless `brave` search answers with must name the key rather than quietly
     * swapping providers - and must not echo the header the key would ride in.
     */
    @Test
    fun `a keyless brave search explains what it needs instead of swapping providers`() {
        val refusal = WebToolError.searchNeedsKey("brave").message.orEmpty()
        assertTrue(refusal, refusal.contains("the brave search backend needs an API key"))
        assertTrue(refusal, refusal.contains("HERNESS_SEARCH_KEY"))
        assertTrue(refusal, refusal.contains("duckduckgo"))
        assertFalse(refusal, refusal.contains("X-Subscription-Token"))
        assertEquals(WebTools.SearchBackend.BRAVE, WebTools.SearchBackend.of("brave"))
        assertEquals(WebTools.SearchBackend.DUCKDUCKGO, WebTools.SearchBackend.of("duckduckgo"))
        assertNull(WebTools.SearchBackend.of("something else"))
    }

    // MARK: - HTML reduction

    @Test
    fun `script style and chrome never reach the model`() {
        val html = """
        <html><head><title>Guide</title><style>p {color: red}</style></head>
        <body><nav>Home About</nav><script>alert(1)</script>
        <main><h1>Setup</h1><p>Run <code>npm install</code> first.</p></main>
        <footer>Copyright</footer></body></html>
        """.trimIndent()
        val text = HTMLText.extract(html)
        assertTrue(text, text.contains("Setup"))
        assertTrue(text, text.contains("npm install"))
        assertFalse(text, text.contains("alert(1)"))
        assertFalse(text, text.contains("color: red"))
        assertFalse(text, text.contains("Home About"))
        assertFalse(text, text.contains("Copyright"))
        assertTrue(text, text.startsWith("# Guide"))
    }

    @Test
    fun `entities are decoded once and the ampersand last`() {
        assertEquals("a &<b>  c", WebText.decodeEntities("a &amp;&lt;b&gt; &nbsp;c"))
        assertEquals("AB", WebText.decodeEntities("&#65;&#x42;"))
        // A decoded payload must not be decoded again: "&amp;#65;" is the text
        // "&#65;", not "A".
        assertEquals("&#65;", WebText.decodeEntities("&amp;#65;"))
    }

    @Test
    fun `blank lines collapse into blank lines not letters`() {
        // The desktop ported this bug first: a regex replacement template that read
        // "\n" as an escape put a literal "nn" where a paragraph break belonged.
        assertEquals("a\n\nb", WebText.collapse("a\n\n\n\n\nb"))
        val text = HTMLText.extract("<main><p>one</p><p>two</p></main>")
        assertFalse(text.contains("nn"))
        assertTrue(text.contains("one"))
        assertTrue(text.contains("two"))
    }

    @Test
    fun `list items become lines`() {
        val text = HTMLText.extract("<ul><li>one</li><li>two</li></ul>")
        assertTrue(text, text.contains("- one"))
        assertTrue(text, text.contains("- two"))
    }

    @Test
    fun `the html format keeps the markup`() {
        val text = HTMLText.extract("<main><p>keep me</p></main>", WebTools.SearchFormat.HTML)
        assertTrue(text, text.contains("<p>"))
    }

    /**
     * The markdown format still reduces to plain lines, because the block rule
     * turns an opening heading tag into a newline before the heading rule can see
     * it - the same order the desktop reducer uses.
     */
    @Test
    fun `the markdown format keeps the line structure and no markup`() {
        val text = HTMLText.extract("<main><h2>Section</h2><p>body</p></main>", WebTools.SearchFormat.MARKDOWN)
        assertTrue(text, text.contains("Section"))
        assertTrue(text, text.contains("body"))
        assertFalse(text, text.contains("<"))
    }

    // MARK: - Budgets and wiring

    @Test
    fun `long bodies are clipped for the model`() {
        val long = "x".repeat(WebTools.MAX_TEXT_CHARACTERS + 500)
        assertEquals(WebTools.MAX_TEXT_CHARACTERS, WebTools.clippedForModel(long).length)
        assertEquals("short", WebTools.clippedForModel("short"))
    }

    /** The cap has to bite during the read, not after the buffer is full. */
    @Test
    fun `the size cap stops a body that streams past it`() {
        val limit = WebTools.MAX_RESPONSE_BYTES
        assertEquals(limit, WebTools.readCapped(ByteArrayInputStream(ByteArray(limit)), "https://example.com/ok").size)
        val failure = runCatching {
            WebTools.readCapped(ByteArrayInputStream(ByteArray(limit + 1)), "https://example.com/big")
        }.exceptionOrNull()
        assertTrue(failure is WebToolError)
        assertEquals("https://example.com/big is larger than the 2000 KB limit.", failure?.message)
    }

    @Test
    fun `both web tools are offered`() {
        val specs = WebTools.specs()
        assertEquals(setOf("web_fetch", "web_search"), specs.map { it.name }.toSet())
        assertTrue(WebTools.isWebTool("web_fetch"))
        assertFalse(WebTools.isWebTool("run_command"))
        specs.forEach { assertTrue(it.name + " needs a schema", it.schema.length() > 0) }
    }

    @Test
    fun `the fetch limits are the desktop ones`() {
        assertEquals(2_000_000, WebTools.MAX_RESPONSE_BYTES)
        assertEquals(24_000, WebTools.MAX_TEXT_CHARACTERS)
        assertEquals(20_000, WebTools.REQUEST_TIMEOUT_MILLIS)
        assertEquals(5, WebTools.MAX_REDIRECTS)
        assertEquals(10, WebTools.SEARCH_RESULT_CAP)
    }
}
