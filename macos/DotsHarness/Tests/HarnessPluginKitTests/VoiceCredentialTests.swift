import XCTest
@testable import DotsHarnessCore

final class VoiceCredentialTests: XCTestCase {
    func testProviderVaultRoundTripAndRemoval() throws {
        let vault = ProviderVault()
        let id = "voice.test.\(UUID().uuidString)"
        defer { try? vault.remove(id) }

        try vault.set("test-voice-secret", for: id)
        XCTAssertEqual(try vault.get(id), "test-voice-secret")
        try vault.remove(id)
        XCTAssertNil(try vault.get(id))
    }
}
