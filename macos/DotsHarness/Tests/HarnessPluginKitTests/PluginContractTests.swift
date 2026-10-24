// Copyright (c) 2026 DOTS
// Native plugin contract tests.

import XCTest
import HarnessPluginKit
import PluginRuntime
import DotsHarnessCore

@MainActor
final class PluginContractTests: XCTestCase {
    func testYAMLCompositionAndPatches() throws {
        let yaml = """
        plane: host
        entries:
          - id: prompt
            plugin: dots.test-prompt
        """
        let document = try MiniYAML.decode(CompositionDocument.self, from: yaml)
        XCTAssertEqual(document.plane, .host)
        XCTAssertEqual(document.entries.count, 1)

        let patchText = """
        - disable: prompt
        """
        let patches = try MiniYAML.loadPatches(from: patchText)
        let next = CompositionPatch.apply(patches, to: document)
        XCTAssertTrue(next.entries[0].disabled)
    }

    func testPromptPluginMount() throws {
        let catalog = PluginCatalog(paths: temporaryPaths())
        catalog.registerBuiltin(PromptPlugin.self)
        let host = PluginHost(catalog: catalog)
        let issues = host.mount(CompositionDocument(plane: .host, entries: [CompositionEntry(id: "prompt", plugin: "dots.test-prompt")]))
        XCTAssertTrue(issues.isEmpty, issues.map(\.message).joined())
        XCTAssertEqual(host.fibers.count, 1)
        XCTAssertTrue(host.prompt.assembledText().contains(PromptPlugin.text))
    }

    func testUnmountReversesSlotsAndPrompt() throws {
        let catalog = PluginCatalog(paths: temporaryPaths())
        catalog.registerBuiltin(PromptPlugin.self)
        let host = PluginHost(catalog: catalog)
        _ = host.mount(CompositionDocument(plane: .host, entries: [CompositionEntry(id: "prompt", plugin: "dots.test-prompt")]))
        host.unmountAll()
        XCTAssertTrue(host.prompt.sections().isEmpty)
        XCTAssertTrue(host.slots.occupants(in: WellKnownSlot.overlay).isEmpty)
    }

    func testSessionServiceWithoutIsolateIsRejected() throws {
        let catalog = PluginCatalog(paths: temporaryPaths())
        catalog.registerBuiltin(PublishingPlugin.self)
        let host = PluginHost(catalog: catalog)
        let document = CompositionDocument(plane: .session, entries: [
            CompositionEntry(id: "pub", plugin: "dots.test-publisher"),
        ])
        let issues = host.mount(document)
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].message.contains("process-global service"))
        XCTAssertTrue(host.fibers.isEmpty)
    }

    func testSessionServiceWithIsolateMounts() throws {
        let catalog = PluginCatalog(paths: temporaryPaths())
        catalog.registerBuiltin(PublishingPlugin.self)
        let host = PluginHost(catalog: catalog)
        let document = CompositionDocument(plane: .session, entries: [
            CompositionEntry(id: "pub", plugin: "dots.test-publisher", isolate: ["demo": true]),
        ])
        let issues = host.mount(document)
        XCTAssertTrue(issues.isEmpty, issues.map(\.message).joined())
        XCTAssertEqual(host.fibers.count, 1)
    }

    func testHostPlaneIsolateKeepsNamedServicesPrivate() throws {
        let catalog = PluginCatalog(paths: temporaryPaths())
        catalog.registerBuiltin(PublishingPlugin.self)
        let shared = PluginHost(catalog: catalog)
        XCTAssertTrue(shared.mount(CompositionDocument(plane: .host, entries: [
            CompositionEntry(id: "pub", plugin: "dots.test-publisher"),
        ])).isEmpty)
        XCTAssertEqual(shared.getService("demo", as: String.self), "value")

        let isolated = PluginHost(catalog: catalog)
        XCTAssertTrue(isolated.mount(CompositionDocument(plane: .host, entries: [
            CompositionEntry(id: "pub", plugin: "dots.test-publisher", isolate: ["demo": true]),
        ])).isEmpty)
        XCTAssertNil(isolated.getService("demo", as: String.self))

        // A key set to false is not isolation; on the session plane that is a global publish.
        let session = PluginHost(catalog: catalog)
        XCTAssertEqual(session.mount(CompositionDocument(plane: .session, entries: [
            CompositionEntry(id: "pub", plugin: "dots.test-publisher", isolate: ["demo": false]),
        ])).count, 1)
    }

    func testManifestOnlyUserPluginIsRejected() throws {
        let paths = temporaryPaths()
        let folder = paths.plugins.appendingPathComponent("note")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        id: com.example.note
        name: Note
        version: 0.1.0
        abi: 1.0.0
        plane: host
        promptSection:
          name: note:remember
          order: 40
          file: prompt.md
        """.write(to: folder.appendingPathComponent("plugin.yml"), atomically: true, encoding: .utf8)
        try "Remember the note plugin.".write(
            to: folder.appendingPathComponent("prompt.md"),
            atomically: true,
            encoding: .utf8
        )

        let catalog = PluginCatalog(paths: paths)
        catalog.refresh()
        XCTAssertEqual(catalog.entries.filter { $0.manifest.id == "com.example.note" }.count, 1)

        let host = PluginHost(catalog: catalog)
        let document = CompositionDocument(plane: .host, entries: [
            CompositionEntry(id: "note", plugin: "com.example.note"),
        ])
        let issues = host.mount(document)
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].message.contains("native"), issues[0].message)
        XCTAssertTrue(host.fibers.isEmpty)
    }

    func testUntrustedDylibIsRejected() throws {
        let paths = temporaryPaths()
        let folder = paths.plugins.appendingPathComponent("hello")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        id: com.example.hello
        name: Hello
        version: 0.1.0
        abi: 1.0.0
        plane: session
        library: HelloPlugin.dylib
        """.write(to: folder.appendingPathComponent("plugin.yml"), atomically: true, encoding: .utf8)
        // The catalog requires a native artifact before it can classify the
        // entry as a dylib. The host must still reject it before attempting
        // to load because the publisher has not been trusted.
        try Data().write(to: folder.appendingPathComponent("HelloPlugin.dylib"))

        let catalog = PluginCatalog(paths: paths)
        catalog.refresh()
        let host = PluginHost(catalog: catalog)
        let document = CompositionDocument(plane: .session, entries: [
            CompositionEntry(id: "hello", plugin: "com.example.hello"),
        ])
        let issues = host.mount(document)
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].message.contains("untrusted"))
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessTests-\(UUID().uuidString)", isDirectory: true)
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

final class PromptPlugin: DefaultPlugin {
    static let manifest = PluginManifest(
        id: "dots.test-prompt",
        name: "Prompt",
        version: "1.0.0",
        plane: .host,
        inject: ["prompt"],
        description: "Test-only prompt section"
    )

    static let text = "Test-only prompt section"

    init() {}

    func apply(_ ctx: PluginContext) throws {
        _ = try ctx.require("prompt")
        ctx.prompt.section(name: "test:prompt", order: 5, text: Self.text)
    }
}

final class PublishingPlugin: DefaultPlugin {
    static let manifest = PluginManifest(
        id: "dots.test-publisher",
        name: "Publisher",
        version: "1.0.0",
        plane: .session,
        description: "Test-only service publisher"
    )

    init() {}

    func apply(_ ctx: PluginContext) throws {
        ctx.provide("demo", "value")
    }
}
