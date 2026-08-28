import XCTest
import Foundation
import HarnessPluginKit
import PluginRuntime
@testable import DotsHarnessCore

@MainActor
final class SkillCatalogTests: XCTestCase {
    func testWorkspacePriorityRejectsSymlinkAndMissingFrontmatter() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        let preferred = workspace.appendingPathComponent(".dotshermess/skills/duplicate", isDirectory: true)
        let provider = workspace.appendingPathComponent(".codex/skills/duplicate", isDirectory: true)
        let nested = workspace.appendingPathComponent("packages/skills/duplicate", isDirectory: true)
        try writeSkill(at: preferred, name: "Preferred", description: "Workspace preferred", body: "preferred body")
        try writeSkill(at: provider, name: "Provider", description: "Provider copy", body: "provider body")
        try writeSkill(at: nested, name: "Nested", description: "Nested copy", body: "nested body")

        let invalid = workspace.appendingPathComponent("packages/skills/invalid", isDirectory: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        try "---\ndescription: missing name\n---\n".write(to: invalid.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let outside = paths.root.appendingPathComponent("outside/skills/escape", isDirectory: true)
        try writeSkill(at: outside, name: "Escape", description: "Outside", body: "outside body")
        let link = workspace.appendingPathComponent(".agent/skills/escape", isDirectory: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let catalog = SkillCatalog(paths: paths, workspaceURL: workspace)
        let entry = try XCTUnwrap(catalog.entries.first(where: { $0.id == "duplicate" }))
        XCTAssertEqual(entry.source, .workspace)
        XCTAssertEqual(entry.name, "Preferred")
        XCTAssertEqual(try catalog.read(id: "duplicate"), "---\nname: Preferred\ndescription: Workspace preferred\n---\npreferred body\n")
        XCTAssertNil(catalog.entries.first(where: { $0.id == "invalid" }))
        XCTAssertNil(catalog.entries.first(where: { $0.id == "escape" }))
    }

    func testSkillToolsReadOnlyContractAndDisableState() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        let skill = workspace.appendingPathComponent("skills/demo", isDirectory: true)
        try writeSkill(at: skill, name: "Demo", description: "A demo skill", body: "demo body")
        let catalog = SkillCatalog(paths: paths, workspaceURL: workspace)

        XCTAssertTrue(SkillTools.isReadOnly("skill.list"))
        XCTAssertTrue(SkillTools.isReadOnly("skill.read"))
        XCTAssertEqual(SkillTools.definitions.map(\.name), ["skill.list", "skill.read"])
        let call = AgentToolCall(id: "1", name: "skill.read", arguments: "{\"id\":\"demo\"}")
        XCTAssertTrue(SkillTools.execute(call, catalog: catalog).contains("demo body"))

        catalog.setEnabled("demo", false)
        XCTAssertNil(catalog.descriptor(for: "demo"))
        XCTAssertEqual(try catalog.read(id: "demo", includeDisabled: true).contains("demo body"), true)
    }

    private func writeSkill(at directory: URL, name: String, description: String, body: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(description)\n---\n\(body)\n".write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessSkillTests-\(UUID().uuidString)", isDirectory: true)
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
