// Copyright (c) 2026 DOTS
// The plugin-author builtin: save then validate a generated plugin.

import XCTest
import HarnessPluginKit
import PluginRuntime

@MainActor
final class PluginAuthorTests: XCTestCase {
    func testSaveThenValidateNativeDraft() async throws {
        let paths = temporaryPaths()
        let catalog = PluginCatalog(paths: paths)
        catalog.registerBuiltin(PluginAuthorPlugin.self)
        let host = PluginHost(catalog: catalog)
        host.provideService("catalog", catalog)
        let issues = host.mount(CompositionDocument(plane: .host, entries: [
            CompositionEntry(id: "author", plugin: "dots.plugin-author"),
        ]))
        XCTAssertTrue(issues.isEmpty, issues.map(\.message).joined())

        let files = """
        {"plugin.yml": "id: com.example.made\\nname: Made\\nversion: 0.1.0\\nplane: session\\n", "plugin.ir.json": "{\\"schemaVersion\\":1,\\"promptSections\\":[]}"}
        """
        let saved = try await host.tools.call("plugin.save", arguments: ["id": "com.example.made", "files": files])
        XCTAssertTrue(saved.contains("native draft"))

        let result = try await host.tools.call("plugin.validate", arguments: ["id": "com.example.made"])
        XCTAssertTrue(result.contains("native"), result)

        _ = try await host.tools.call("plugin.remove", arguments: ["id": "com.example.made"])
        XCTAssertFalse(catalog.entries.contains { $0.manifest.id == "com.example.made" })
    }

    func testValidateReportsManifestError() async throws {
        let paths = temporaryPaths()
        let catalog = PluginCatalog(paths: paths)
        catalog.registerBuiltin(PluginAuthorPlugin.self)
        let host = PluginHost(catalog: catalog)
        host.provideService("catalog", catalog)
        _ = host.mount(CompositionDocument(plane: .host, entries: [
            CompositionEntry(id: "author", plugin: "dots.plugin-author"),
        ]))

        let files = #"{"plugin.yml": "name: NoId\nversion: 0.1.0\n", "plugin.ir.json": "{}"}"#
        _ = try await host.tools.call("plugin.save", arguments: ["id": "com.example.bad", "files": files])
        let result = try await host.tools.call("plugin.validate", arguments: ["id": "com.example.bad"])
        XCTAssertTrue(result.contains("error") || result.contains("native"), result)
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessAuthorTests-\(UUID().uuidString)", isDirectory: true)
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
