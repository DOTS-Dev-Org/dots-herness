import XCTest
import Foundation
import HarnessPluginKit
import PluginRuntime
@testable import DotsHarnessCore

@MainActor
final class SkillSuggestionEngineTests: XCTestCase {
    private var clock = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!

    static func learned(_ rule: String, hits: Int) -> Lesson {
        Lesson(
            when: "editing the release workflow",
            rule: rule,
            why: "the signing step needs it",
            paths: ["ci/"],
            sources: (0..<hits).map { "\(Lesson.signalPrefix)\(rule)-\($0)" }
        )
    }

    func testOnlyALessonLearnedThreeTimesBecomesASuggestion() {
        XCTAssertTrue(SkillSuggestionEngine.fromLessons([Self.learned("Bump VERSION first", hits: 2)]).isEmpty)

        let suggestions = SkillSuggestionEngine.fromLessons([Self.learned("Bump VERSION first", hits: 3), Self.learned("Other", hits: 1)])
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.signal, .lesson)
        XCTAssertEqual(suggestions.first?.draftName, "Bump VERSION first")
        XCTAssertTrue(suggestions.first?.body.contains("`ci/`") == true)
    }

    func testAcceptWritesSkillAndCooldownHoldsTheNextCard() throws {
        let (monitor, skills) = makeMonitor()

        monitor.scan(lessons: [Self.learned("Bump VERSION first", hits: 3)])
        XCTAssertNotNil(monitor.pending)
        let id = try monitor.acceptCurrent(name: "Release prep", description: "Prepares a release.")
        XCTAssertNotNil(skills.descriptor(for: id))
        XCTAssertNil(monitor.pending)

        monitor.scan(lessons: [Self.learned("Run migrations before seeding", hits: 4)])
        XCTAssertNil(monitor.pending)

        clock += SkillSuggestionMonitor.cooldown
        monitor.scan(lessons: [Self.learned("Run migrations before seeding", hits: 4)])
        XCTAssertNotNil(monitor.pending)
    }

    func testTwoDismissalsInARowPauseSuggestions() {
        let (monitor, skills) = makeMonitor()

        monitor.scan(lessons: [Self.learned("A", hits: 3)])
        monitor.dismissCurrent()
        clock += SkillSuggestionMonitor.cooldown
        monitor.scan(lessons: [Self.learned("B", hits: 3)])
        monitor.dismissCurrent()

        clock += SkillSuggestionMonitor.cooldown
        monitor.scan(lessons: [Self.learned("C", hits: 3)])
        XCTAssertNil(monitor.pending)
        XCTAssertTrue(suggest(skills, monitor, name: "Deploy Preview").contains("No card shown"))

        clock += SkillSuggestionMonitor.pause
        monitor.scan(lessons: [Self.learned("C", hits: 3)])
        XCTAssertNotNil(monitor.pending)
    }

    func testDisablingDropsPendingAndBlocksAgentProposals() {
        let (monitor, skills) = makeMonitor()
        monitor.scan(lessons: [Self.learned("A", hits: 3)])
        XCTAssertNotNil(monitor.pending)

        monitor.enabled = false
        XCTAssertNil(monitor.pending)
        XCTAssertTrue(suggest(skills, monitor, name: "Deploy Preview").contains("turned off"))
        XCTAssertNil(monitor.pending)
    }

    func testAgentProposalIsNotShownAgainUnderAnotherDescription() {
        let (monitor, skills) = makeMonitor()

        XCTAssertTrue(suggest(skills, monitor, name: "Deploy Preview").contains("Suggestion card shown"))
        XCTAssertEqual(monitor.pending?.signal, .agentProposed)
        monitor.dismissCurrent()

        clock += SkillSuggestionMonitor.cooldown
        XCTAssertTrue(suggest(skills, monitor, name: "deploy preview", description: "Reworded.").contains("already suggested"))
        XCTAssertNil(monitor.pending)
    }

    private func suggest(_ skills: SkillCatalog, _ monitor: SkillSuggestionMonitor, name: String, description: String = "Builds and deploys a preview.") -> String {
        SkillTools.execute(
            AgentToolCall(id: "1", name: "skill.suggest", arguments: "{\"name\":\"\(name)\",\"description\":\"\(description)\",\"body\":\"## Steps\\n\\n1. Build\\n\"}"),
            catalog: skills,
            suggestions: monitor
        )
    }

    private func makeMonitor() -> (SkillSuggestionMonitor, SkillCatalog) {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let skills = SkillCatalog(paths: paths, workspaceURL: workspace)
        let monitor = SkillSuggestionMonitor(paths: paths, skills: skills)
        monitor.now = { [unowned self] in self.clock }
        monitor.setWorkspace(workspace.path)
        return (monitor, skills)
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessSuggestionTests-\(UUID().uuidString)", isDirectory: true)
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
