// Copyright (c) 2026 DOTS
// `runtime: js` plugin tests.

import XCTest
import HarnessPluginKit
import PluginRuntime

@MainActor
final class JSPluginTests: XCTestCase {
    func testJSPluginRegistersPromptToolAndEvents() async throws {
        let paths = temporaryPaths()
        let folder = paths.plugins.appendingPathComponent("greeter")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        id: com.example.greeter
        name: Greeter
        version: 0.1.0
        plane: session
        main: plugin.js
        """.write(to: folder.appendingPathComponent("plugin.yml"), atomically: true, encoding: .utf8)
        try #"""
        function apply(h) {
          h.prompt("greeter:note", 40, "Greeter JS plugin mounted.");
          h.on("greeter/in", function (name) { h.emit("greeter/out", "hi " + name); });
          h.tool("greeter:hello", "say hello", function (args) {
            return "hello " + (args.who || "world");
          });
        }
        """#.write(to: folder.appendingPathComponent("plugin.js"), atomically: true, encoding: .utf8)

        let catalog = PluginCatalog(paths: paths)
        catalog.refresh()
        let host = PluginHost(catalog: catalog)
        let issues = host.mount(CompositionDocument(plane: .session, entries: [
            CompositionEntry(id: "greeter", plugin: "com.example.greeter"),
        ]))
        XCTAssertTrue(issues.isEmpty, issues.map(\.message).joined())
        XCTAssertTrue(host.prompt.assembledText().contains("Greeter JS plugin mounted."))

        let result = try await host.tools.call("greeter:hello", arguments: ["who": "ali"])
        XCTAssertEqual(result, "hello ali")

        var out: Any?
        _ = host.events.on("greeter/out") { out = $0 }
        host.events.emit("greeter/in", "ali")
        XCTAssertEqual(out as? String, "hi ali")
    }

    func testBrokenJSSurfacesMountIssue() throws {
        let paths = temporaryPaths()
        let folder = paths.plugins.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        id: com.example.broken
        name: Broken
        version: 0.1.0
        plane: session
        main: plugin.js
        """.write(to: folder.appendingPathComponent("plugin.yml"), atomically: true, encoding: .utf8)
        try "// no apply function here\n".write(
            to: folder.appendingPathComponent("plugin.js"), atomically: true, encoding: .utf8
        )

        let catalog = PluginCatalog(paths: paths)
        catalog.refresh()
        let host = PluginHost(catalog: catalog)
        let issues = host.mount(CompositionDocument(plane: .session, entries: [
            CompositionEntry(id: "broken", plugin: "com.example.broken"),
        ]))
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].message.contains("apply"))
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessJSTests-\(UUID().uuidString)", isDirectory: true)
        let paths = SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins", isDirectory: true),
            presets: root.appendingPathComponent("presets", isDirectory: true),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models", isDirectory: true),
            runtime: root.appendingPathComponent("runtime", isDirectory: true)
        )
        paths.ensure()
        return paths
    }
}
