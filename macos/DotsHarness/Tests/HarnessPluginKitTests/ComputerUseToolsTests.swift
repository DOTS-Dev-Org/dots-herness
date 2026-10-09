// Copyright (c) 2026 DOTS

import XCTest
import AppKit
import HarnessPluginKit
import PluginRuntime
@testable import DotsHarnessCore

final class ComputerUseToolsTests: XCTestCase {
    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsComputerUseTests-\(UUID().uuidString)", isDirectory: true)
        return SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins", isDirectory: true),
            presets: root.appendingPathComponent("presets", isDirectory: true),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models", isDirectory: true),
            runtime: root.appendingPathComponent("runtime", isDirectory: true)
        )
    }

    func testComputerUseDefinitionProperties() {
        XCTAssertEqual(ComputerUseTools.toolName, "computer_use")
        guard let def = ComputerUseTools.definitions.first else {
            return XCTFail("Missing computer_use definition")
        }
        XCTAssertEqual(def.name, "computer_use")
        XCTAssertFalse(def.description.isEmpty)
        guard case let .object(parameters) = def.parameters,
              case let .object(properties) = parameters["properties"] else {
            return XCTFail("computer_use parameters are not an object")
        }
        XCTAssertNotNil(properties["action"])
        XCTAssertNotNil(properties["x"])
        XCTAssertNotNil(properties["y"])
        XCTAssertNotNil(properties["text"])
    }

    func testComputerUseRiskClassificationIsSideEffect() {
        XCTAssertEqual(NativeAgentHost.risk("computer_use"), .sideEffect)
        XCTAssertTrue(NativeAgentHost.requiresApproval(mode: .ask, toolName: "computer_use"))
        XCTAssertTrue(NativeAgentHost.requiresApproval(mode: .safe, toolName: "computer_use"))
        XCTAssertFalse(NativeAgentHost.requiresApproval(mode: .full, toolName: "computer_use"))
    }

    @MainActor
    func testComputerUseIsOnlyExposedWhenEnabled() {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let host = NativeAgentHost(paths: paths, endpoint: AgentEndpointController())
        host.setComputerUseEnabled(false)
        XCTAssertFalse(host.agentTools(workspace: nil).defs.contains { $0.name == "computer_use" })

        host.setComputerUseEnabled(true)
        XCTAssertTrue(host.agentTools(workspace: nil).defs.contains { $0.name == "computer_use" })

        host.setComputerUseEnabled(false)
        XCTAssertFalse(host.agentTools(workspace: nil).defs.contains { $0.name == "computer_use" })

        let bridge = AgentBridge(paths: paths, endpoint: AgentEndpointController())
        bridge.setComputerUseEnabled(true)
        XCTAssertTrue(bridge.isComputerUseEnabled)
        bridge.setComputerUseEnabled(false)
        XCTAssertFalse(bridge.isComputerUseEnabled)
    }

    @MainActor
    func testMissingActionIsReported() async throws {
        let result = try await ComputerUseService.execute(arguments: [:], workspace: nil)
        XCTAssertEqual(result, "Missing or invalid action for computer_use.")
    }

    @MainActor
    func testUnknownActionIsReported() async throws {
        let result = try await ComputerUseService.execute(arguments: ["action": "dance"], workspace: nil)
        XCTAssertEqual(result, "Missing or invalid action for computer_use.")
    }

    @MainActor
    func testPermissionsStatusStruct() {
        let permissions = ComputerUseService.permissions()
        _ = permissions.screenRecording
        _ = permissions.accessibility
        _ = permissions.isFullyAuthorized
    }

    @MainActor
    func testScreenshotIsAnImmutableImageWithCoordinateMetadataForEveryProvider() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8,
            bytesPerRow: 48, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemGreen.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let first = try ComputerUseService.screenshotResult(image: image, frame: CGRect(x: -120, y: 42, width: 12, height: 8))
        let second = try ComputerUseService.screenshotResult(image: image, frame: .zero)
        let attachment = try XCTUnwrap(first.attachment)
        defer {
            try? FileManager.default.removeItem(atPath: attachment.path)
            if let path = second.attachment?.path { try? FileManager.default.removeItem(atPath: path) }
        }
        XCTAssertNotEqual(attachment.path, second.attachment?.path)
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.snapshotPath, attachment.path)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.text.utf8)) as? [String: Any])
        XCTAssertEqual((metadata["screen_frame"] as? [String: Double])?["x"], -120)
        XCTAssertEqual((metadata["image_size"] as? [String: Int])?["width"], 12)
        let base64 = try Data(contentsOf: URL(fileURLWithPath: attachment.path)).base64EncodedString()
        let toolMessage = AgentMessage(role: .tool, content: first.text, name: ComputerUseTools.toolName,
            toolCallID: "capture", attachments: [attachment])
        for api in [RouterAPIKind.openAICompatible, .chatGPT, .anthropic, .geminiCLI] {
            let client = NativeAgentClient(configuration: AgentConfiguration(baseURL: "https://example.test", model: "vision", api: api.rawValue))
            let body = client.makeBody(messages: [toolMessage], tools: [], cachePolicy: AgentCachePolicy())
            let wire = String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes]), as: UTF8.self)
            XCTAssertTrue(wire.contains(base64), "Screenshot bytes missing for \(api.rawValue)")
        }
    }

    @MainActor
    func testScreenshotExportStaysInsideWorkspaceAndNeverOverwritesSourceFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try ComputerUseService.exportDestination(nil, workspace: root))
        XCTAssertThrowsError(try ComputerUseService.exportDestination("../outside.png", workspace: root))
        XCTAssertThrowsError(try ComputerUseService.exportDestination("/tmp/outside.png", workspace: root))
        XCTAssertThrowsError(try ComputerUseService.exportDestination("source.swift", workspace: root))
        XCTAssertThrowsError(try ComputerUseService.exportDestination("capture.png", workspace: nil))
        let existing = root.appendingPathComponent("existing.png")
        try Data("existing source".utf8).write(to: existing)
        XCTAssertThrowsError(try ComputerUseService.exportDestination("existing.png", workspace: root))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: root.deletingLastPathComponent().path)
        XCTAssertThrowsError(try ComputerUseService.exportDestination("escape/outside.png", workspace: root))
        XCTAssertEqual(try ComputerUseService.exportDestination("captures/new.png", workspace: root)?.path,
            root.appendingPathComponent("captures/new.png").resolvingSymlinksInPath().path)
    }

    @MainActor
    func testDesktopGuidanceTracksSettingAndPlanModeBlocksControl() {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let host = NativeAgentHost(paths: paths, endpoint: AgentEndpointController())
        XCTAssertTrue(host.systemPromptSections(workspace: nil).contains { $0.tag == "desktop_control" && $0.text.contains("disabled") })
        host.setComputerUseEnabled(true)
        XCTAssertTrue(host.systemPromptSections(workspace: nil).contains { $0.tag == "desktop_control" && $0.text.contains("list_windows") })
        XCTAssertTrue(NativeAgentHost.planWithholds(ComputerUseTools.toolName))
    }

    /// Opt-in smoke test; only the disposable fixture app receives input.
    @MainActor
    func testLiveDesktopCaptureInputAndAppLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["HERNESS_COMPUTER_USE_LIVE"] == "1" else {
            throw XCTSkip("Opt-in desktop fixture smoke test.")
        }
        guard ComputerUseService.permissions().isFullyAuthorized else {
            throw XCTSkip("Screen Recording and Accessibility permissions are unavailable to the test process.")
        }
        let app = "com.dots.herness.computeruse.fixture"
        let appPath = try XCTUnwrap(ProcessInfo.processInfo.environment["HERNESS_FIXTURE_APP"])
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == app }) {
            let stopped = try await ComputerUseService.execute(arguments: ["action": "quit_app", "app": app], workspace: nil)
            XCTAssertTrue(stopped.contains("Quit "), stopped)
        }
        _ = try await ComputerUseService.execute(arguments: ["action": "launch_app", "app": appPath], workspace: nil)
        var target: [String: Any]?
        for _ in 0..<20 {
            let listing = try await ComputerUseService.executeWithResult(arguments: ["action": "list_windows"], workspace: nil)
            let listingJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listing.text.utf8)) as? [String: Any])
            let candidates = (listingJSON["windows"] as? [[String: Any]] ?? []).filter {
                $0["bundle_id"] as? String == app && $0["title"] as? String == "HerNess Görsel Kontrol Testi"
            }
            target = candidates.max { lhs, rhs in
                let a = lhs["screen_frame"] as? [String: Double] ?? [:]
                let b = rhs["screen_frame"] as? [String: Double] ?? [:]
                return (a["width"] ?? 0) * (a["height"] ?? 0) < (b["width"] ?? 0) * (b["height"] ?? 0)
            }
            if target != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let windowID = try XCTUnwrap(target?["window_id"] as? String, "The newly launched fixture must expose a discoverable window.")
        _ = try await ComputerUseService.execute(arguments: ["action": "focus_app", "window_id": windowID], workspace: nil)
        let before = try await ComputerUseService.executeWithResult(arguments: ["action": "screenshot", "window_id": windowID], workspace: nil)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(before.text.utf8)) as? [String: Any])
        let frame = try XCTUnwrap(metadata["screen_frame"] as? [String: Double])
        XCTAssertGreaterThanOrEqual(frame["width"] ?? 0, 540)
        XCTAssertGreaterThanOrEqual(frame["height"] ?? 0, 340)
        // Coordinates observed in the fixture's fresh screenshot (window-local points).
        let x = try XCTUnwrap(frame["x"]), y = try XCTUnwrap(frame["y"])
        let env = ProcessInfo.processInfo.environment
        let statePath = try XCTUnwrap(env["HERNESS_FIXTURE_STATE"])
        let initialState = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: statePath))) as? [String: Any])
        let buttonX = try XCTUnwrap(Double(env["HERNESS_FIXTURE_BUTTON_X"] ?? ""))
        let buttonY = try XCTUnwrap(Double(env["HERNESS_FIXTURE_BUTTON_Y"] ?? ""))
        let fieldX = try XCTUnwrap(Double(env["HERNESS_FIXTURE_FIELD_X"] ?? ""))
        let fieldY = try XCTUnwrap(Double(env["HERNESS_FIXTURE_FIELD_Y"] ?? ""))
        _ = try await ComputerUseService.execute(arguments: ["action": "left_click", "x": x + buttonX, "y": y + buttonY], workspace: nil)
        _ = try await ComputerUseService.execute(arguments: ["action": "left_click", "x": x + fieldX, "y": y + fieldY], workspace: nil)
        _ = try await ComputerUseService.execute(arguments: ["action": "key", "key": "cmd+a"], workspace: nil)
        _ = try await ComputerUseService.execute(arguments: ["action": "type", "text": "HerNess ğüşiı 🚀"], workspace: nil)
        _ = try await ComputerUseService.execute(arguments: ["action": "key", "key": "Tab"], workspace: nil)
        try await Task.sleep(for: .milliseconds(300))
        let after = try await ComputerUseService.executeWithResult(arguments: ["action": "screenshot", "window_id": windowID], workspace: nil)
        let afterMetadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(after.text.utf8)) as? [String: Any])
        XCTAssertEqual(afterMetadata["image_size"] as? [String: Int], metadata["image_size"] as? [String: Int])
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: statePath))) as? [String: Any])
        XCTAssertEqual(state["clicks"] as? Int, (initialState["clicks"] as? Int ?? 0) + 1)
        XCTAssertEqual(state["text"] as? String, "HerNess ğüşiı 🚀")
        XCTAssertNotEqual(before.attachment?.path, after.attachment?.path)

        let close = try await ComputerUseService.execute(arguments: ["action": "close_window", "window_id": windowID], workspace: nil)
        XCTAssertTrue(close.contains("Closed the selected application window"), close)
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == app }) {
            let quit = try await ComputerUseService.execute(arguments: ["action": "quit_app", "app": app], workspace: nil)
            XCTAssertTrue(quit.contains("Quit "), quit)
        }
        _ = try await ComputerUseService.execute(arguments: ["action": "launch_app", "app": appPath], workspace: nil)
        var relaunched = false
        for _ in 0..<20 {
            let windows = try await ComputerUseService.executeWithResult(arguments: ["action": "list_windows"], workspace: nil)
            if windows.text.contains(app) { relaunched = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(relaunched, "The closed fixture application should launch again and expose a window.")
        let finalQuit = try await ComputerUseService.execute(arguments: ["action": "quit_app", "app": app], workspace: nil)
        XCTAssertTrue(finalQuit.contains("Quit "), finalQuit)
        print("HERNESS_LIVE_BEFORE=\(before.attachment?.path ?? "")")
        print("HERNESS_LIVE_AFTER=\(after.attachment?.path ?? "")")
    }
}
