// Copyright (c) 2026 DOTS
// Declarative (code-free) plugin tests.

import XCTest
import HarnessPluginKit
import PluginRuntime

@MainActor
final class DeclarativePluginTests: XCTestCase {
    func testDeclarativeManifestRegistersToolAndPanel() async throws {
        let paths = temporaryPaths()
        let folder = paths.plugins.appendingPathComponent("weather")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        id: com.example.weather
        name: Weather
        version: 0.1.0
        plane: session
        tools:
          - name: weather:ping
            description: fire an event
            action:
              kind: emit
              event: weather/ping
              payload: hi
        panels:
          - slot: conversation.composer.accessory
            id: main
            order: 10
            label: Weather
            body:
              type: vstack
              children:
                - type: text
                  text: Hello
                - type: button
                  label: Ping
                  tool: weather:ping
        """.write(to: folder.appendingPathComponent("plugin.yml"), atomically: true, encoding: .utf8)

        let catalog = PluginCatalog(paths: paths)
        catalog.refresh()
        let host = PluginHost(catalog: catalog)
        let issues = host.mount(CompositionDocument(plane: .session, entries: [
            CompositionEntry(id: "weather", plugin: "com.example.weather"),
        ]))
        XCTAssertTrue(issues.isEmpty, issues.map(\.message).joined())
        XCTAssertTrue(host.tools.tools().contains { $0.name == "weather:ping" })
        XCTAssertFalse(host.slots.occupants(in: "conversation.composer.accessory").isEmpty)

        var received: Any?
        _ = host.events.on("weather/ping") { received = $0 }
        _ = try await host.tools.call("weather:ping", arguments: [:])
        XCTAssertEqual(received as? String, "hi")
    }

    func testUntrustedShellToolIsRejected() throws {
        let paths = temporaryPaths()
        let folder = paths.plugins.appendingPathComponent("sh")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        id: com.example.sh
        name: Sh
        version: 0.1.0
        plane: session
        tools:
          - name: sh:echo
            action:
              kind: shell
              command:
                - echo
                - hi
        """.write(to: folder.appendingPathComponent("plugin.yml"), atomically: true, encoding: .utf8)

        let catalog = PluginCatalog(paths: paths)
        catalog.refresh()
        let host = PluginHost(catalog: catalog)
        let issues = host.mount(CompositionDocument(plane: .session, entries: [
            CompositionEntry(id: "sh", plugin: "com.example.sh"),
        ]))
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].message.contains("trusted"))
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessDeclTests-\(UUID().uuidString)", isDirectory: true)
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
