import XCTest
import PluginRuntime
@testable import DotsHarnessCore
@testable import DotsHarnessUI

@MainActor
final class ScheduledTaskSuggestionTests: XCTestCase {
    func testEightTemplatesHaveValidSchedulesAndCurrentMemoryInstructions() {
        let values = ScheduledTaskSuggestion.defaults
        XCTAssertEqual(values.count, 8)
        XCTAssertEqual(Set(values.map(\.id)).count, 8)
        for value in values {
            XCTAssertNotNil(CronExpression(value.cron))
            XCTAssertFalse(value.prompt.contains(".detail"))
            XCTAssertTrue(value.prompt.contains(AppCopy.text("tasks.suggestions.instruction")))
            XCTAssertTrue(value.memorySourceIDs.isEmpty)
        }
    }

    func testStoredCardsSurviveRestartAndDropWhenSourceOrMemoryIsGone() {
        let original = ScheduledTaskSuggestions.directory
        ScheduledTaskSuggestions.directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: ScheduledTaskSuggestions.directory)
            ScheduledTaskSuggestions.directory = original
        }
        var cards = ScheduledTaskSuggestion.defaults
        cards[0].title = "Swift news"
        cards[0].memorySourceIDs = ["interest"]
        let memory = TaskSuggestionMemory(entries: [.init(id: "interest", text: "Swift")])
        XCTAssertNil(ScheduledTaskSuggestions.stored(memory: memory, locale: "tr", workspace: "/w"))
        ScheduledTaskSuggestions.save(cards, key: "k", locale: "tr", workspace: "/w")
        XCTAssertEqual(ScheduledTaskSuggestions.stored(memory: memory, locale: "tr", workspace: "/w"), cards)
        XCTAssertNil(ScheduledTaskSuggestions.stored(memory: memory, locale: "en", workspace: "/w"))
        let other = TaskSuggestionMemory(entries: [.init(id: "other", text: "Go")])
        XCTAssertNil(ScheduledTaskSuggestions.stored(memory: other, locale: "tr", workspace: "/w"))
        XCTAssertNil(ScheduledTaskSuggestions.stored(memory: .init(entries: []), locale: "tr", workspace: "/w"))
        XCTAssertNil(ScheduledTaskSuggestions.stored(memory: memory, locale: "tr", workspace: "/w"))
    }

    func testMalformedOrUnsupportedOutputKeepsEightTemplates() {
        let defaults = ScheduledTaskSuggestion.defaults
        let memory = TaskSuggestionMemory(entries: [.init(id: "interest", text: "Swift")])
        XCTAssertEqual(ScheduledTaskSuggestions.merge("not JSON", defaults: defaults, memory: memory), defaults)
        let ungrounded = #"{"suggestions":[{"id":"reading","title":"Swift reading","detail":"A Swift article","instruction":"Find a Swift article.","sourceIDs":["made-up"]}]}"#
        XCTAssertEqual(ScheduledTaskSuggestions.merge(ungrounded, defaults: defaults, memory: memory), defaults)
    }

    func testGroundedPersonalizationPreservesScheduleAndFillsMissingCategories() throws {
        let defaults = ScheduledTaskSuggestion.defaults
        let memory = TaskSuggestionMemory(entries: [.init(id: "interest", text: "Interested in Swift")])
        let raw = response()
        let values = ScheduledTaskSuggestions.merge(raw, defaults: defaults, memory: memory)
        XCTAssertEqual(values.count, 8)
        let reading = try XCTUnwrap(values.first { $0.id == "reading" })
        XCTAssertEqual(reading.title, "reading task")
        XCTAssertEqual(reading.memorySourceIDs, ["interest"])
        XCTAssertEqual(reading.cron, defaults.first { $0.id == "reading" }?.cron)
        XCTAssertEqual(reading.task(workspacePath: "/tmp/work").prompt, reading.prompt)
        XCTAssertTrue(reading.task(workspacePath: "/tmp/work").allowsNetwork)
        XCTAssertEqual(values.filter { !$0.memorySourceIDs.isEmpty }.count, 4)
        let general = values.filter { $0.memorySourceIDs.isEmpty }
        XCTAssertEqual(general.map(\.id), ["email", "prices", "weekend", "events"])
        XCTAssertEqual(general, general.compactMap { value in defaults.first { $0.id == value.id } })
        XCTAssertEqual(values.map(\.id), ["daily", "email", "reading", "prices", "weekly", "weekend", "followup", "events"])
    }

    func testRemovedMemoryInvalidatesGroundingAndDuplicateCategoriesAreRejected() {
        let defaults = ScheduledTaskSuggestion.defaults
        let raw = response()
        XCTAssertEqual(ScheduledTaskSuggestions.merge(raw, defaults: defaults, memory: .init(entries: [])), defaults)
        let duplicate = response(ids: ["daily", "reading", "reading", "followup"])
        XCTAssertEqual(ScheduledTaskSuggestions.merge(duplicate, defaults: defaults,
            memory: .init(entries: [.init(id: "interest", text: "Swift")])), defaults)
    }

    func testIncompletePersonalSetCannotReplaceTheFourPlusFourSelection() {
        let defaults = ScheduledTaskSuggestion.defaults
        let memory = TaskSuggestionMemory(entries: [.init(id: "interest", text: "Swift")])
        for ids in [["daily"], ["daily", "reading", "weekly"], ["daily", "reading", "unknown", "followup"]] {
            XCTAssertEqual(ScheduledTaskSuggestions.merge(response(ids: ids), defaults: defaults, memory: memory), defaults)
        }
    }

    func testCardsSwitchToHorizontalAndFitInShortOrNarrowWindows() {
        let wide = TaskSuggestionLayout(size: CGSize(width: 1000, height: 850))
        XCTAssertFalse(wide.horizontal)
        XCTAssertLessThanOrEqual(wide.occupiedHeight, 850)
        for size in [CGSize(width: 1000, height: 600), CGSize(width: 420, height: 850),
                     CGSize(width: 800, height: 450), CGSize(width: 320, height: 320)] {
            let layout = TaskSuggestionLayout(size: size)
            XCTAssertTrue(layout.horizontal)
            XCTAssertLessThanOrEqual(layout.occupiedHeight, size.height)
            XCTAssertGreaterThanOrEqual(layout.cardWidth, 280)
        }
    }

    private func response(ids: [String] = ["daily", "reading", "weekly", "followup"]) -> String {
        let rows = ids.map { id in
            ["id": id, "title": id + " task", "detail": "A distinct task for " + id,
             "instruction": "Summarize " + id, "sourceIDs": ["interest"]] as [String: Any]
        }
        return String(data: try! JSONSerialization.data(withJSONObject: ["suggestions": rows]), encoding: .utf8)!
    }

    func testUserPreferencesAreAvailableWithoutAnOpenProjectAndSecretsAreRedacted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SupportPaths(root: root, plugins: root.appendingPathComponent("plugins"),
            presets: root.appendingPathComponent("presets"), settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"), trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models"), runtime: root.appendingPathComponent("runtime"))
        paths.ensure()
        let memory = WorkspaceMemory(paths: paths)
        XCTAssertTrue(memory.taskSuggestionMemory().isEmpty)
        try memory.profile.setPreference(key: "interest", value: "Swift development")
        try memory.profile.setPreference(key: "note", value: "api_key=test-secret")
        let snapshot = memory.taskSuggestionMemory()
        XCTAssertTrue(snapshot.json.contains("Swift development"))
        XCTAssertFalse(snapshot.json.contains("test-secret"))
        XCTAssertTrue(snapshot.json.contains("[redacted]"))
        try memory.profile.removePreference(key: "interest", projectID: nil)
        XCTAssertFalse(memory.taskSuggestionMemory().json.contains("Swift development"))
    }
}
