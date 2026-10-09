// Copyright (c) 2026 DOTS

import XCTest
@testable import DotsHarnessCore

final class AndroidEmulatorToolsTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dots-android-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAndroidEmulatorToolIsExposedToTheAgent() {
        XCTAssertTrue(WorkspaceTools.definitions.contains { $0.name == "android_emulator" })
        XCTAssertEqual(AndroidEmulatorTools.definitions.first?.name, "android_emulator")
    }

    func testRiskClassification() {
        XCTAssertEqual(NativeAgentHost.risk("android_emulator"), .sideEffect)
        XCTAssertTrue(NativeAgentHost.requiresApproval(mode: .ask, toolName: "android_emulator"))
        XCTAssertTrue(NativeAgentHost.requiresApproval(mode: .safe, toolName: "android_emulator"))
        XCTAssertFalse(NativeAgentHost.requiresApproval(mode: .full, toolName: "android_emulator"))
    }

    func testMissingActionIsReported() throws {
        let result = AndroidEmulatorTools.execute([:], workspace: try workspace())
        XCTAssertEqual(result, "Missing action.")
    }

    func testUnknownActionIsReported() throws {
        let result = AndroidEmulatorTools.execute(["action": "dance"], workspace: try workspace())
        XCTAssertTrue(result.contains("dance"))
    }

    func testLaunchRequiresComponent() throws {
        let result = AndroidEmulatorTools.execute(["action": "launch", "device": "emulator-5554"], workspace: try workspace())
        XCTAssertTrue(result.contains("component"))
    }

    func testTapRequiresCoordinates() throws {
        let result = AndroidEmulatorTools.execute(["action": "tap", "device": "emulator-5554"], workspace: try workspace())
        XCTAssertTrue(result.contains("coordinate"))
    }

    func testTextRequiresText() throws {
        let result = AndroidEmulatorTools.execute(["action": "text", "device": "emulator-5554"], workspace: try workspace())
        XCTAssertTrue(result.contains("Missing text"))
    }

    func testSwipeRequiresCoordinates() throws {
        let result = AndroidEmulatorTools.execute(["action": "swipe", "device": "emulator-5554"], workspace: try workspace())
        XCTAssertTrue(result.contains("swipe"))
    }

    func testScreenshotCannotEscapeWorkspace() throws {
        let root = try workspace()
        let result = AndroidEmulatorTools.execute(
            ["action": "screenshot", "device": "emulator-5554", "path": "../escaped_android.png"],
            workspace: root
        )
        XCTAssertTrue(result.contains("../escaped_android.png"), result)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.deletingLastPathComponent().appendingPathComponent("escaped_android.png").path
        ))
        try? FileManager.default.removeItem(at: root)
    }
}
