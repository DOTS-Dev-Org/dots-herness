// Copyright (c) 2026 DOTS
// Tests for application version checking and update state transitions.

import XCTest
@testable import DotsHarnessCore

final class UpdateCheckerTests: XCTestCase {
    func testUpdateInfoDecoding() throws {
        let json = """
        {
            "platform": "macos",
            "current_version": "0.1.0",
            "latest_version": "0.2.0",
            "build_number": 15,
            "min_supported_version": "0.1.0",
            "update_available": true,
            "mandatory": false,
            "release_notes": "Yeni özellikler eklendi",
            "download_url": "https://dots.net.tr/harness/downloads/DotsHarness-0.2.0.dmg",
            "published_at": "2026-09-21T00:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let info = try decoder.decode(UpdateInfo.self, from: json)

        XCTAssertEqual(info.platform, "macos")
        XCTAssertEqual(info.currentVersion, "0.1.0")
        XCTAssertEqual(info.latestVersion, "0.2.0")
        XCTAssertEqual(info.buildNumber, 15)
        XCTAssertTrue(info.updateAvailable)
        XCTAssertFalse(info.mandatory)
        XCTAssertEqual(info.downloadURL, "https://dots.net.tr/harness/downloads/DotsHarness-0.2.0.dmg")
    }

    func testUpdateStateHelpers() {
        let idleState = UpdateState.idle
        XCTAssertFalse(idleState.isChecking)
        XCTAssertFalse(idleState.hasUpdate)

        let checkingState = UpdateState.checking
        XCTAssertTrue(checkingState.isChecking)
        XCTAssertFalse(checkingState.hasUpdate)

        let info = UpdateInfo(
            currentVersion: "0.1.0",
            latestVersion: "0.2.0",
            updateAvailable: true
        )
        let availableState = UpdateState.updateAvailable(info)
        XCTAssertFalse(availableState.isChecking)
        XCTAssertTrue(availableState.hasUpdate)

        let mandatoryState = UpdateState.mandatoryUpdate(info)
        XCTAssertTrue(mandatoryState.hasUpdate)
    }

    @MainActor
    func testUpdateCheckerInitialization() {
        let checker = UpdateChecker()
        XCTAssertEqual(checker.state, .idle)
        XCTAssertFalse(checker.currentVersion.isEmpty)
    }
}
