// Copyright (c) 2026 DOTS
// Installed plugins must land in the mounted composition without a host.patch.yml.

import XCTest
import HarnessPluginKit
import PluginRuntime
import DotsHarnessCore

@MainActor
final class CompositionLoaderTests: XCTestCase {
    func testLegacyPluginIsComposedDisabled() throws {
        let paths = temporaryPaths()
        try writeGreeter(into: paths)

        let catalog = PluginCatalog(paths: paths)
        catalog.refresh()
        let document = CompositionLoader.loadHost(paths: paths, catalog: catalog)

        let entry = document.entries.first { $0.plugin == "com.example.greeter" }
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.disabled ?? false)

        let host = PluginHost(catalog: catalog)
        XCTAssertTrue(host.mount(document).isEmpty)
        XCTAssertFalse(host.prompt.assembledText().contains("Greeter JS plugin mounted."))
    }

    func testDisabledCatalogEntryIsComposedDisabled() throws {
        let paths = temporaryPaths()
        try writeGreeter(into: paths)

        let catalog = PluginCatalog(paths: paths)
        catalog.refresh()
        catalog.setEnabled("com.example.greeter", false)
        let document = CompositionLoader.loadHost(paths: paths, catalog: catalog)

        let entry = document.entries.first { $0.plugin == "com.example.greeter" }
        XCTAssertEqual(entry?.disabled, true)

        let host = PluginHost(catalog: catalog)
        XCTAssertTrue(host.mount(document).isEmpty)
        XCTAssertFalse(host.prompt.assembledText().contains("Greeter JS plugin mounted."))
    }

    func testBrokenManifestDoesNotBreakLoad() throws {
        let paths = temporaryPaths()
        let folder = paths.plugins.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "this: is: not: yaml: {".write(
            to: folder.appendingPathComponent("plugin.yml"), atomically: true, encoding: .utf8
        )

        let catalog = PluginCatalog(paths: paths)
        catalog.refresh()
        let document = CompositionLoader.loadHost(paths: paths, catalog: catalog)
        let entry = document.entries.first { $0.plugin == "bad" }
        XCTAssertEqual(entry?.disabled, true)

        let host = PluginHost(catalog: catalog)
        XCTAssertTrue(host.mount(document).isEmpty)
        XCTAssertFalse(host.fibers.contains { $0.pluginId == "bad" })
    }

    func testHostPatchConfigMergesWithoutDuplicating() throws {
        let paths = temporaryPaths()
        try writeGreeter(into: paths)
        try """
        - config:
            id: com.example.greeter
            merge:
              tone: loud
        """.write(to: paths.hostPatch, atomically: true, encoding: .utf8)

        let catalog = PluginCatalog(paths: paths)
        catalog.refresh()
        let document = CompositionLoader.loadHost(paths: paths, catalog: catalog)

        let matches = document.entries.filter { $0.plugin == "com.example.greeter" }
        XCTAssertEqual(matches.count, 1)
    }

    private func writeGreeter(into paths: SupportPaths) throws {
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
          h.tool("greeter:hello", "say hello", function (args) {
            return "hello " + (args.who || "world");
          });
        }
        """#.write(to: folder.appendingPathComponent("plugin.js"), atomically: true, encoding: .utf8)
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessCompositionTests-\(UUID().uuidString)", isDirectory: true)
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
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return paths
    }
}
