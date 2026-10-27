package com.dots.herness.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.BufferedReader
import java.io.StringReader
import java.net.URI
import java.util.Base64

/** The token and every command cross the LAN, so nothing but HTTPS is accepted. */
class RemoteEndpointTest {
    @Test
    fun onlyHttpsIsAccepted() {
        assertTrue(RemoteEndpoint.isAllowed(URI("https://abc.trycloudflare.com")))
        assertTrue(RemoteEndpoint.isAllowed(URI("https://mac.local:18768")))
        assertFalse(RemoteEndpoint.isAllowed(URI("http://mac.local:18768")))
        assertFalse(RemoteEndpoint.isAllowed(URI("http://192.168.1.20:18768")))
        assertFalse(RemoteEndpoint.isAllowed(URI("https://user@mac.local:18768")))
        assertFalse(RemoteEndpoint.isAllowed(URI("ftp://mac.local")))
    }

    @Test
    fun fingerprintIsLowercaseSha256Hex() {
        val pin = RemotePinning.sha256("desktop".toByteArray())
        assertEquals(64, pin.length)
        assertTrue(RemoteEndpoint.isFingerprint(pin))
        assertFalse(RemoteEndpoint.isFingerprint(pin.uppercase()))
        assertFalse(RemoteEndpoint.isFingerprint(pin.drop(2)))
    }

    /** Produced by CryptoKit (the desktop and iOS code path); the C# tests check the same bytes. */
    @Test
    fun sealedChannelMatchesTheReferenceVectors() {
        val key = RemoteSealed.key("secret")
        val frame = Base64.getDecoder().decode("AQIDBAUGBwgJCgsM2/e9qfr3KS76oXJIHzrpD6fBFZma")
        assertArrayEquals("hello".toByteArray(), RemoteSealed.unseal(key, frame, RemoteSealed.frameAad(ByteArray(12), 1)))
        val nonce = (1..12).map { it.toByte() }.toByteArray()
        val request = RemoteSealed.seal(key, nonce, byteArrayOf(0, 0, 1, 0x8f.toByte(), 0xff.toByte(), 0, 0, 0) + "GET / HTTP/1.1\r\n\r\n".toByteArray(), "device".toByteArray())
        assertEquals("AQIDBAUGBwgJCgsMs5LQSmqEPVAuXvXvLhsxJfIUIJ9mu791xzxrNZODNSY2/uTUfLrjHY0x", Base64.getEncoder().encodeToString(request))
    }

    @Test
    fun sealedInputReadsTheReplyAndRejectsATruncatedOne() {
        val key = RemoteSealed.key("secret")
        val nonce = ByteArray(12) { 7 }
        fun line(chunk: String, counter: Int) = Base64.getEncoder().encodeToString(RemoteSealed.seal(key, ByteArray(12) { counter.toByte() }, chunk.toByteArray(), RemoteSealed.frameAad(nonce, counter)))
        val reply = listOf(line("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"a\"", 0), line(":1}", 1), line("", 2))
        val input = SealedInput(BufferedReader(StringReader(reply.joinToString("\n"))), key, nonce)
        assertEquals(200, input.status())
        assertEquals("{\"a\":1}", String(input.readBytes()))

        val cut = SealedInput(BufferedReader(StringReader(reply.take(2).joinToString("\n"))), key, nonce)
        assertEquals(200, cut.status())
        assertTrue(runCatching { cut.readBytes() }.isFailure)
        val swapped = SealedInput(BufferedReader(StringReader(listOf(reply[1], reply[0]).joinToString("\n"))), key, nonce)
        assertTrue(runCatching { swapped.status() }.isFailure)
    }

    @Test
    fun pairingNeedsTheQrSecret() {
        val secret = "A".repeat(43)
        val fields = mapOf("endpoint" to listOf("https://abc.trycloudflare.com"), "code" to listOf("123456"), "k" to listOf(secret))
        assertNotNull(PairingPayload.fromQuery(fields.keys) { fields[it].orEmpty() })
        assertNull(PairingPayload.fromQuery(fields.keys - "k") { fields[it].orEmpty() })
        assertNull(PairingPayload.fromFields("https://abc.trycloudflare.com", "123456", "short"))
    }
}
