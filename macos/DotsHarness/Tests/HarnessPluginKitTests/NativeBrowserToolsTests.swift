// Copyright (c) 2026 DOTS
// Unit tests for the Native In-App Browser (WebKit) tool definitions and runtime service.

import Foundation
import XCTest
@testable import DotsHarnessCore

final class NativeBrowserToolsTests: XCTestCase {

    func testNativeBrowserActionRawValues() {
        XCTAssertEqual(NativeBrowserAction(rawValue: "open"), .open)
        XCTAssertEqual(NativeBrowserAction(rawValue: "navigate"), .navigate)
        XCTAssertEqual(NativeBrowserAction(rawValue: "screenshot"), .screenshot)
        XCTAssertEqual(NativeBrowserAction(rawValue: "evaluate_js"), .evaluateJs)
        XCTAssertEqual(NativeBrowserAction(rawValue: "get_content"), .getContent)
        XCTAssertEqual(NativeBrowserAction(rawValue: "click"), .click)
        XCTAssertEqual(NativeBrowserAction(rawValue: "type"), .type)
        XCTAssertEqual(NativeBrowserAction(rawValue: "reload"), .reload)
        XCTAssertEqual(NativeBrowserAction(rawValue: "back"), .back)
        XCTAssertEqual(NativeBrowserAction(rawValue: "forward"), .forward)
        XCTAssertNil(NativeBrowserAction(rawValue: "unknown_action"))
    }

    func testNativeBrowserToolDefinition() {
        XCTAssertEqual(NativeBrowserTools.toolName, "native_browser")
        XCTAssertEqual(NativeBrowserTools.definitions.count, 1)

        let def = NativeBrowserTools.definitions[0]
        XCTAssertEqual(def.name, "native_browser")
        guard case let .object(parameters) = def.parameters,
              case let .object(props) = parameters["properties"] else {
            return XCTFail("native_browser parameters or properties are not an object")
        }
        XCTAssertNotNil(props["action"])
        XCTAssertNotNil(props["url"])
        XCTAssertNotNil(props["path"])
        XCTAssertNotNil(props["script"])
        XCTAssertNotNil(props["selector"])
        XCTAssertNotNil(props["text"])

        guard case let .array(required) = parameters["required"] else {
            return XCTFail("native_browser required is not an array")
        }
        XCTAssertEqual(required, [.string("action")])
    }

    func testBackendPolicyResolvesNativeBrowser() {
        XCTAssertEqual(BrowserBackend.native.rawValue, "Native")

        XCTAssertEqual(BrowserBackendPolicy.resolveUserRule("native browser kullan"), .native)
        XCTAssertEqual(BrowserBackendPolicy.resolveUserRule("dahili tarayıcıda aç"), .native)
        XCTAssertEqual(BrowserBackendPolicy.resolveUserRule("canlı tarayıcıyı kullan"), .native)
        XCTAssertEqual(BrowserBackendPolicy.resolveUserRule("use webkit"), .native)
        XCTAssertEqual(BrowserBackendPolicy.resolveUserRule("dock browser"), .native)

        XCTAssertEqual(BrowserBackendPolicy.parseConfirmation("Native"), .native)
        XCTAssertEqual(BrowserBackendPolicy.parseConfirmation("In-App Live Browser"), .native)
        XCTAssertEqual(BrowserBackendPolicy.parseConfirmation("dahili"), .native)
    }

    @MainActor
    func testNativeBrowserServiceEngineAndNavigation() async throws {
        let service = NativeBrowserService.shared
        XCTAssertTrue(service.engineName.contains("WebKit"), "Engine name on macOS should be WebKit")

        var notifiedURL: String?
        service.onNavigateRequested = { url in
            notifiedURL = url
        }

        let navResult = try await service.execute(
            arguments: ["action": "navigate", "url": "about:blank"],
            workspace: nil
        )
        XCTAssertTrue(navResult.contains("about:blank"), navResult)
        XCTAssertEqual(notifiedURL, "about:blank")
    }

    @MainActor
    func testNativeBrowserEvaluateJs() async throws {
        let service = NativeBrowserService.shared
        _ = try await service.execute(
            arguments: ["action": "navigate", "url": "about:blank"],
            workspace: nil
        )

        let evalResult = try await service.execute(
            arguments: ["action": "evaluate_js", "script": "1 + 1"],
            workspace: nil
        )
        XCTAssertTrue(evalResult.contains("2"), evalResult)

        let titleResult = try await service.execute(
            arguments: ["action": "evaluate_js", "script": "'hello ' + 'world'"],
            workspace: nil
        )
        XCTAssertTrue(titleResult.contains("hello world"), titleResult)
    }

    @MainActor
    func testNativeBrowserSnapshot() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-browser-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = NativeBrowserService.shared
        _ = try await service.execute(
            arguments: ["action": "navigate", "url": "about:blank"],
            workspace: nil
        )

        let snapshotResult = try await service.execute(
            arguments: ["action": "screenshot", "path": "test_snapshot.png"],
            workspace: tempDir
        )
        XCTAssertTrue(snapshotResult.contains("Saved") || snapshotResult.contains("test_snapshot.png"), snapshotResult)

        let fileURL = tempDir.appendingPathComponent("test_snapshot.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
