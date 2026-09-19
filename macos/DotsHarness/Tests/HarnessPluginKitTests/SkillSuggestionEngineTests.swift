import XCTest
import Foundation
import HarnessPluginKit
import PluginRuntime
@testable import DotsHarnessCore

@MainActor
final class SkillSuggestionEngineTests: XCTestCase {
    func testToolSequenceFiresOnlyAtOrAboveThreshold() {
        var events = (0..<2).map { i in
            MemEvent(eventID: "e\(i)", lamport: Int64(i), createdAt: Date(), type: "tool.executed", commandSummary: "npm test && npm run lint", runID: "run1")
        }
        XCTAssertTrue(SkillSuggestionEngine.detectToolSequencePatterns(events: events, minOccurrences: 3).isEmpty)

        events.append(MemEvent(eventID: "e2", lamport: 2, createdAt: Date(), type: "tool.executed", commandSummary: "npm test && npm run lint", runID: "run1"))
        let suggestions = SkillSuggestionEngine.detectToolSequencePatterns(events: events, minOccurrences: 3)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.signal, .toolSequence)
        XCTAssertEqual(suggestions.first?.occurrences, 3)
    }

    func testToolSequenceIgnoresVolatileSubstringsWhenGrouping() {
        let events = [
            MemEvent(eventID: "e0", lamport: 0, createdAt: Date(), type: "tool.executed", commandSummary: "cat /tmp/abc123/out.txt", runID: "r1"),
            MemEvent(eventID: "e1", lamport: 1, createdAt: Date(), type: "tool.executed", commandSummary: "cat /tmp/def456/out.txt", runID: "r2"),
            MemEvent(eventID: "e2", lamport: 2, createdAt: Date(), type: "tool.executed", commandSummary: "cat /tmp/ghi789/out.txt", runID: "r3"),
        ]
        let suggestions = SkillSuggestionEngine.detectToolSequencePatterns(events: events, minOccurrences: 3)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.occurrences, 3)
    }

    func testPromptSimilarityClustersNearDuplicatesButNotUnrelatedPrompts() {
        let prompts = [
            "add a dark mode toggle",
            "add dark mode toggle please",
            "can you add a dark mode toggle",
            "fix the login page crash",
        ]
        let suggestions = SkillSuggestionEngine.detectPromptSimilarityPatterns(userPrompts: prompts, minOccurrences: 3, similarityThreshold: 0.6)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.signal, .promptSimilarity)
        XCTAssertEqual(suggestions.first?.occurrences, 3)
    }

    func testNoRepeatedPatternProducesNoSuggestions() {
        let prompts = ["one off request", "another unrelated ask", "a third distinct thing"]
        XCTAssertTrue(SkillSuggestionEngine.detectPromptSimilarityPatterns(userPrompts: prompts, minOccurrences: 3, similarityThreshold: 0.75).isEmpty)

        let events = [
            MemEvent(eventID: "e0", lamport: 0, createdAt: Date(), type: "tool.executed", commandSummary: "ls", runID: "r1"),
            MemEvent(eventID: "e1", lamport: 1, createdAt: Date(), type: "tool.executed", commandSummary: "pwd", runID: "r2"),
        ]
        XCTAssertTrue(SkillSuggestionEngine.detectToolSequencePatterns(events: events, minOccurrences: 2).isEmpty)
    }

    func testAgentCanProposeASuggestionAndItStopsAfterOneDismiss() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let skills = SkillCatalog(paths: paths, workspaceURL: workspace)
        let monitor = SkillSuggestionMonitor(paths: paths, skills: skills)
        monitor.setWorkspace(workspace.path)

        let call = AgentToolCall(id: "1", name: "skill.suggest", arguments: "{\"name\":\"Deploy Preview\",\"description\":\"Builds and deploys a preview.\",\"body\":\"## Steps\\n\\n1. Build\\n2. Deploy\\n\"}")
        let result = SkillTools.execute(call, catalog: skills, suggestions: monitor)

        XCTAssertTrue(result.contains("Suggestion card shown"))
        XCTAssertNotNil(monitor.pending)
        XCTAssertEqual(monitor.pending?.signal, .agentProposed)

        monitor.dismissCurrent()
        XCTAssertNil(monitor.pending)

        let again = SkillTools.execute(
            AgentToolCall(id: "2", name: "skill.suggest", arguments: "{\"name\":\"Deploy Preview\",\"description\":\"Builds and deploys a preview.\",\"body\":\"different body\"}"),
            catalog: skills,
            suggestions: monitor
        )
        XCTAssertTrue(again.contains("already suggested"))
        XCTAssertNil(monitor.pending)
    }

    func testAcceptWritesSkillAndRefreshesCatalog() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let skills = SkillCatalog(paths: paths, workspaceURL: workspace)
        let monitor = SkillSuggestionMonitor(paths: paths, skills: skills)
        monitor.toolRepeatThreshold = 2
        monitor.setWorkspace(workspace.path)

        try writeToolEvents(workspace: workspace, commandSummary: "npm test", count: 2)
        monitor.scan(recentUserPrompts: [])
        XCTAssertNotNil(monitor.pending)

        let id = try monitor.acceptCurrent(name: "Run Npm Test", description: "Runs the test suite.")
        XCTAssertNotNil(skills.descriptor(for: id))
        XCTAssertNil(monitor.pending)
    }

    private func writeToolEvents(workspace: URL, commandSummary: String, count: Int) throws {
        let directory = workspace.appendingPathComponent(".mem/events", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for i in 0..<count {
            let json = """
            {
                "eventId": "evt-\(i)",
                "lamport": \(i),
                "createdAt": "2026-01-01T00:00:0\(i)Z",
                "type": "tool.executed",
                "payload": { "commandSummary": "\(commandSummary)", "runId": "run-\(i)" }
            }
            """
            try json.write(to: directory.appendingPathComponent("evt-\(i).json"), atomically: true, encoding: .utf8)
        }
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
