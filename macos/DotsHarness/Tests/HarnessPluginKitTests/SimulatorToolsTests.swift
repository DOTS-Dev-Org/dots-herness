// Copyright (c) 2026 DOTS

import XCTest
@testable import DotsHarnessCore

final class SimulatorToolsTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dots-sim-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRuntimeIdentifierBecomesReadableName() {
        XCTAssertEqual(SimulatorService.prettyRuntime("com.apple.CoreSimulator.SimRuntime.iOS-26-5"), "iOS 26.5")
        XCTAssertEqual(SimulatorService.prettyRuntime("com.apple.CoreSimulator.SimRuntime.watchOS-26-5"), "watchOS 26.5")
        XCTAssertEqual(SimulatorService.prettyRuntime("iOS"), "iOS")
    }

    func testDisplayAspectRatioUsesTheConnectedMainScreen() {
        let output = """
        Creatable Screen Properties:
            (101) CarPlay:
                Pixel Size: {720, 480}
        Connected Screens:
            (1) LCD:
                Pixel Size: {1206, 2622}
        """
        XCTAssertEqual(
            SimulatorService.parseDisplayAspectRatio(from: output)!,
            1206.0 / 2622.0,
            accuracy: 0.000001
        )
    }

    func testSimulatorToolIsExposedToTheAgent() {
        XCTAssertTrue(WorkspaceTools.definitions.contains { $0.name == "ios_simulator" })
    }

    func testMissingActionIsReported() throws {
        let result = SimulatorTools.execute([:], workspace: try workspace())
        XCTAssertEqual(result, AppCopy.text("simulator.tool.missingAction"))
    }

    func testUnknownActionIsReported() throws {
        let result = SimulatorTools.execute(["action": "explode"], workspace: try workspace())
        XCTAssertTrue(result.contains("explode"))
    }

    func testLaunchRequiresBundleIdentifier() throws {
        let result = SimulatorTools.execute(["action": "launch"], workspace: try workspace())
        XCTAssertEqual(result, AppCopy.text("simulator.tool.missingBundleID"))
    }

    func testScreenshotCannotEscapeTheWorkspace() throws {
        let root = try workspace()
        let result = SimulatorTools.execute(
            ["action": "screenshot", "path": "../escaped.png"],
            workspace: root
        )
        XCTAssertTrue(result.contains("../escaped.png"), result)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.deletingLastPathComponent().appendingPathComponent("escaped.png").path
        ))
    }

    /// Live check: skipped on machines without Xcode or a booted device.
    func testScreenshotCapturesBootedDevice() throws {
        let devices = (try? SimulatorService.devices()) ?? []
        try XCTSkipIf(devices.first(where: \.isBooted) == nil, "No booted simulator device.")
        let root = try workspace()
        let result = SimulatorTools.execute(["action": "screenshot", "path": "shot.png"], workspace: root)
        let file = root.appendingPathComponent("shot.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), result)
        let data = try Data(contentsOf: file)
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "Not a PNG payload.")
    }
}
