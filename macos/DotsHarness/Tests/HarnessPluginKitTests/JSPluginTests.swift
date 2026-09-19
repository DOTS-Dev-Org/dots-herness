// Copyright (c) 2026 DOTS
// Legacy JavaScript/declarative packages are rejected by the native-only catalog.

import XCTest
import HarnessPluginKit
import PluginRuntime

@MainActor
final class JSPluginTests: XCTestCase {
    func testLegacyJavaScriptPluginIsNotLoadable() throws {
        let paths = temporaryPaths()
        try writePlugin(
            id: "com.example.legacy-js",
            manifest: """
            id: com.example.legacy-js
            name: Legacy JS
            version: 0.1.0
            plane: session
            main: plugin.js
            """,
            into: paths
        )

        let catalog = PluginCatalog(paths: paths)
        catalog.refresh()
        let entry = try XCTUnwrap(catalog.entries.first { $0.manifest.id == "com.example.legacy-js" })
        XCTAssertFalse(entry.enabled)
        XCTAssertTrue(entry.broken?.contains("native") == true)

        let host = PluginHost(catalog: catalog)
        let issues = host.mount(CompositionDocument(plane: .session, entries: [
            CompositionEntry(id: "legacy", plugin: "com.example.legacy-js"),
        ]))
        XCTAssertEqual(issues.count, 1)
    }

    func testManifestOnlyPluginIsNotLoadable() throws {
        let paths = temporaryPaths()
        try writePlugin(
            id: "com.example.legacy-manifest",
            manifest: """
            id: com.example.legacy-manifest
            name: Legacy Manifest
            version: 0.1.0
            plane: session
            """,
            into: paths
        )

        let catalog = PluginCatalog(paths: paths)
        catalog.refresh()
        let entry = try XCTUnwrap(catalog.entries.first { $0.manifest.id == "com.example.legacy-manifest" })
        XCTAssertFalse(entry.enabled)
        XCTAssertTrue(entry.broken?.contains("native") == true)
    }

    private func writePlugin(id: String, manifest: String, into paths: SupportPaths) throws {
        let folder = paths.plugins.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifest.write(to: folder.appendingPathComponent("plugin.yml"), atomically: true, encoding: .utf8)
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessNativeOnlyTests-\(UUID().uuidString)", isDirectory: true)
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
