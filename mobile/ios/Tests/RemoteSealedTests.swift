import CryptoKit
import XCTest
@testable import HerNessMobile

/// The vectors come from CryptoKit (the desktop code path); the C# and Android
/// tests check the same bytes, so all four ends speak one format.
final class RemoteSealedTests: XCTestCase {
    func testOpensTheReferenceFrameOnlyAtItsPosition() throws {
        let key = RemoteSealed.key("secret")
        let frame = "AQIDBAUGBwgJCgsM2/e9qfr3KS76oXJIHzrpD6fBFZma"
        XCTAssertEqual(try RemoteSealed.open(line: frame, key: key, nonce: Data(count: 12), counter: 1), Data("hello".utf8))
        XCTAssertThrowsError(try RemoteSealed.open(line: frame, key: key, nonce: Data(count: 12), counter: 2))
    }

    func testRequestIsSealedForItsDevice() throws {
        let key = RemoteSealed.key("secret")
        let sealed = try RemoteSealed.request(key: key, device: "phone", method: "GET", path: "/v1/control/bootstrap", host: "mac.local:18768", body: nil)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Data("phone".utf8))
        XCTAssertTrue(String(decoding: plain.dropFirst(8), as: UTF8.self).hasPrefix("GET /v1/control/bootstrap HTTP/1.1\r\n"))
        XCTAssertThrowsError(try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Data("other".utf8)))
    }

    func testSecretShape() {
        XCTAssertTrue(RemoteSealed.isSecret(String(repeating: "A", count: 42) + "_"))
        XCTAssertFalse(RemoteSealed.isSecret("short"))
        XCTAssertFalse(RemoteSealed.isSecret(String(repeating: "ğ", count: 43)))
    }
}
