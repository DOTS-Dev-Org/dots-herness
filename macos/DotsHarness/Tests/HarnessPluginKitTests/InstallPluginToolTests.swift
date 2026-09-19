// Copyright (c) 2026 DOTS

import XCTest
import PluginRuntime
import HarnessPluginKit
import DotsHarnessCore

final class InstallPluginToolTests: XCTestCase {
    func testRefusesDirectAgentInstallation() throws {
        let dir = tempDir()
        let args = json([
            "id": "com.example.limits",
            "files": [
                "plugin.yml": "id: com.example.limits\nname: Limits\nversion: 0.1.0\nplane: session\nmain: plugin.js\n",
                "plugin.js": "function apply(h){ h.prompt('x', 1, 'hi'); }\n",
            ],
        ])
        let outcome = InstallPluginTool.write(args, into: dir)
        XCTAssertFalse(outcome.installed)
        XCTAssertTrue(outcome.notice.contains("Marketplace"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("com.example.limits").path))
    }

    func testRejectsUnsafeId() {
        let outcome = InstallPluginTool.write(
            json(["id": "../evil", "files": ["plugin.yml": "id: x\nname: x\nversion: 0.1.0\nplane: session\n"]]),
            into: tempDir()
        )
        XCTAssertFalse(outcome.installed)
    }

    func testRejectsCompiledPlugin() {
        let outcome = InstallPluginTool.write(
            json([
                "id": "com.example.native",
                "files": ["plugin.yml": "id: com.example.native\nname: N\nversion: 0.1.0\nplane: host\nlibrary: libN.dylib\n"],
            ]),
            into: tempDir()
        )
        XCTAssertFalse(outcome.installed)
        XCTAssertTrue(outcome.notice.contains("Marketplace"))
    }

    func testRejectsMissingManifest() {
        let outcome = InstallPluginTool.write(
            json(["id": "com.example.x", "files": ["notes.md": "hi"]]),
            into: tempDir()
        )
        XCTAssertFalse(outcome.installed)
    }

    // MARK: helpers

    private func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallPluginToolTests-\(UUID().uuidString)/plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    private func paths(runtimeRoot: URL, plugins: URL) -> SupportPaths {
        SupportPaths(
            root: runtimeRoot,
            plugins: plugins,
            presets: runtimeRoot.appendingPathComponent("presets", isDirectory: true),
            settings: runtimeRoot.appendingPathComponent("settings.json"),
            hostPatch: runtimeRoot.appendingPathComponent("host.patch.yml"),
            trust: runtimeRoot.appendingPathComponent("trust.json"),
            models: runtimeRoot.appendingPathComponent("models", isDirectory: true),
            runtime: runtimeRoot.appendingPathComponent("runtime", isDirectory: true)
        )
    }
}
