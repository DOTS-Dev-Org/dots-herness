import XCTest
@testable import DotsHarnessCore
import PluginRuntime

/// The project's decisions as they pile up: the cases shared with the Windows and Linux
/// clients, what leaves a full file first, decisions kept with their reason and platforms,
/// the review that merges twins and only suggests removing stale ones, trust that follows a
/// project to another checkout, and the old signed log written into facts.md.
@MainActor
final class ProjectDecisionsTests: XCTestCase {
    private var root: URL!
    private var paths: SupportPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectDecisionsTests-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        paths = SupportPaths(
            root: support,
            plugins: support.appendingPathComponent("plugins", isDirectory: true),
            presets: support.appendingPathComponent("presets", isDirectory: true),
            settings: support.appendingPathComponent("settings.json"),
            hostPatch: support.appendingPathComponent("host.patch.yml"),
            trust: support.appendingPathComponent("trust.json"),
            models: support.appendingPathComponent("models", isDirectory: true),
            runtime: support.appendingPathComponent("runtime", isDirectory: true)
        )
        paths.ensure()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// shared/memory-contract/decisions.json, which the C# tests read too.
    private func contract() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/memory-contract/decisions.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testAgreesWithTheSharedContract() throws {
        let contract = try contract()
        for row in contract["same"] as? [[String: Any]] ?? [] {
            XCTAssertEqual(ProjectDecisions.same(row["left"] as! String, row["right"] as! String), row["same"] as? Bool, "\(row["left"]!)")
        }
        for row in contract["platforms"] as? [[String: Any]] ?? [] {
            XCTAssertEqual(ProjectDecisions.platforms(of: row["text"] as! String), row["platforms"] as? [String], "\(row["text"]!)")
        }
        for row in contract["applies"] as? [[String: Any]] ?? [] {
            XCTAssertEqual(ProjectDecisions.applies(row["text"] as! String, platform: row["platform"] as! String), row["applies"] as? Bool)
        }
        for row in contract["compose"] as? [[String: Any]] ?? [] {
            XCTAssertEqual(
                ProjectDecisions.compose(statement: row["statement"] as! String, reason: row["reason"] as! String, platforms: row["platforms"] as! [String]),
                row["text"] as? String)
        }
        for row in contract["tidy"] as? [[String: Any]] ?? [] {
            let fact = MemoryTransferFact(kind: row["kind"] as! String, key: row["key"] as! String, text: row["text"] as! String)
            XCTAssertEqual(ProjectDecisions.tidied([fact]).first?.text, row["tidied"] as? String)
        }
        let evict = try XCTUnwrap(contract["evict"] as? [String: Any])
        var facts = (evict["facts"] as? [[String: String]] ?? []).map { MemoryTransferFact(kind: $0["kind"]!, key: $0["key"]!, text: $0["text"]!) }
        ProjectDecisions.evict(&facts, max: evict["max"] as! Int)
        XCTAssertEqual(facts.map(\.key), evict["kept"] as? [String])
        for row in contract["remotes"] as? [[String: Any]] ?? [] {
            XCTAssertEqual(WorkspaceMemory.normalizeRemote(row["url"] as! String), row["normalized"] as? String, "\(row["url"]!)")
        }
    }

    func testAFullFileLosesItsOldestDecisionAndNeverWhatWasLearnedOfTheCode() throws {
        let memory = try makeMemory("full")
        try memory.setProjectDefault(key: "architecture", value: "Three layers: UI, core and providers.")
        for index in 0..<65 {
            try memory.recordProjectDecision(summary: Self.distinct(index))
        }
        let facts = memory.projectMemoryFacts()
        XCTAssertEqual(facts.count, 60)
        XCTAssertTrue(facts.contains { $0.key == "architecture" })
        XCTAssertFalse(facts.contains { $0.text == Self.distinct(0) }, "the oldest decision leaves first")
        XCTAssertTrue(facts.contains { $0.text == Self.distinct(64) })
    }

    func testADecisionKeepsItsReasonAndPlatforms() throws {
        let memory = try makeMemory("structured")
        try memory.recordProjectDecision(summary: "Keep the effort level", reason: "changing it invalidates the measured prompt cache", platforms: ["windows"])
        try memory.recordProjectDecision(summary: "Ship SQLite, not Postgres.")
        XCTAssertTrue(memory.projectMemoryFacts().contains { $0.text == "[windows] Keep the effort level. Reason: changing it invalidates the measured prompt cache" })
        let project = memory.projectText()
        XCTAssertTrue(project.contains("SQLite"))
        XCTAssertFalse(project.contains("effort level"), "a decision about another platform leaves the prompt")
        XCTAssertTrue(project.contains("1 more are about other platforms"))
        XCTAssertTrue(memory.recallText(query: "effort level").contains("effort level"))
    }

    func testAReviewMergesTwinsAndOnlySuggestsRemovingStaleDecisions() throws {
        let memory = try makeMemory("review")
        for index in 0..<ProjectDecisions.consolidationMinimum {
            try memory.recordProjectDecision(summary: Self.distinct(index))
        }
        let keys = memory.projectMemoryFacts().filter { $0.kind == "decision" }.map(\.key)
        XCTAssertNotNil(memory.decisionConsolidationPayload())
        let reply = #"{"merge":[{"keep":"\#(keys[1])","drop":["\#(keys[2])"],"text":"Merged decision."}],"stale":[{"key":"\#(keys[3])","reason":"A later one replaced it."}]}"#
        XCTAssertTrue(memory.applyDecisionConsolidation(reply: reply))
        let decisions = memory.projectMemoryFacts().filter { $0.kind == "decision" }
        XCTAssertEqual(decisions.count, ProjectDecisions.consolidationMinimum - 1)
        XCTAssertEqual(decisions.first { $0.key == keys[1] }?.text, "Merged decision.")
        XCTAssertEqual(memory.decisionProposals.map(\.key), [keys[3]])
        XCTAssertNil(memory.decisionConsolidationPayload(), "asked again only after more decisions")

        let note = try XCTUnwrap(memory.vault().notes.first { $0.id == keys[3] })
        XCTAssertTrue(note.tags.contains(WorkspaceMemory.decisionReviewTag))
        XCTAssertEqual(MemoryEdit.removal(of: note), .forgetDecision(key: keys[3]))

        memory.keepProjectDecision(key: keys[3])
        XCTAssertTrue(memory.decisionProposals.isEmpty)
        try memory.forgetProjectDecision(key: keys[3])
        XCTAssertFalse(memory.projectMemoryFacts().contains { $0.key == keys[3] })
        let index = try String(contentsOf: memory.memoryDirectory!.appendingPathComponent("index.md"), encoding: .utf8)
        XCTAssertTrue(index.contains("[[\(keys[1])]]"), "the index lists the decisions facts.md holds")
    }

    func testTrustFollowsTheProjectToAnotherCheckoutOfTheSameRepositoryOnly() throws {
        let id = UUID().uuidString
        func checkout(_ name: String, origin: String) throws -> WorkspaceMemory {
            let workspace = root.appendingPathComponent(name, isDirectory: true)
            let mem = workspace.appendingPathComponent(".mem", isDirectory: true)
            try FileManager.default.createDirectory(at: mem, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try #"{"schemaVersion":1,"projectId":"\#(id)"}"#.write(to: mem.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            try "## project\n- goal — Ship it.\n".write(to: mem.appendingPathComponent("facts.md"), atomically: true, encoding: .utf8)
            try "[remote \"origin\"]\n\turl = \(origin)\n".write(to: workspace.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
            let memory = WorkspaceMemory(paths: paths)
            memory.setWorkspace(workspace)
            return memory
        }
        let first = try checkout("first", origin: "git@github.com:owner/repo.git")
        let moved = try checkout("moved", origin: "https://github.com/owner/repo")
        let copy = try checkout("copy", origin: "https://github.com/attacker/repo")
        XCTAssertTrue(first.needsProjectMemoryTrust)
        try first.setProjectMemoryTrust(true)
        XCTAssertTrue(moved.projectMemoryTrusted)
        XCTAssertTrue(copy.needsProjectMemoryTrust, "the id is copied from the repository; the remote is not")
    }

    func testTheOldSignedLogIsWrittenIntoFactsAndRetired() throws {
        let memory = try makeMemory("legacy")
        try memory.setProjectDefault(key: "goal", value: "One harness.")
        let mem = try XCTUnwrap(memory.memoryDirectory)
        let events = mem.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        let eventID = UUID().uuidString
        let event: [String: Any] = [
            "schemaVersion": 1, "projectId": try XCTUnwrap(memory.projectID), "eventId": eventID, "lamport": 2,
            "scope": "project", "type": "decision.accepted", "parents": [],
            "payload": ["summary": "We ship SQLite, not Postgres."],
        ]
        try JSONSerialization.data(withJSONObject: event).write(to: events.appendingPathComponent("\(eventID).json"))
        try "{}".write(to: mem.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)

        memory.reload()
        let facts = try String(contentsOf: mem.appendingPathComponent("facts.md"), encoding: .utf8)
        XCTAssertTrue(facts.contains("We ship SQLite, not Postgres."))
        XCTAssertTrue(facts.contains("One harness."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: events.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mem.appendingPathComponent("state.json").path))
        XCTAssertTrue(memory.projectText().contains("We ship SQLite"))
    }

    private static let words = [
        "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima",
        "mike", "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey",
        "xray", "yankee", "zulu", "amber", "basalt", "cobalt", "dune", "ember", "fjord", "garnet", "harbor", "iris",
        "jasper", "kestrel", "lagoon", "marble", "nectar", "onyx", "prairie", "quartz", "raven", "saffron", "tundra",
        "umber", "velvet", "willow", "xenon", "yarrow", "zephyr", "acorn", "birch", "cedar", "dahlia", "elm", "fern",
        "gorse", "heather", "ivy", "juniper", "kelp", "larch", "maple", "nettle", "oak", "pine", "quince", "rowan",
    ]

    /// A decision sharing almost no words with any other, so none is taken for its twin.
    /// The same sentences as shared/ProjectDecisionsTests.cs.
    private static func distinct(_ index: Int) -> String {
        let n = words.count
        return "\(words[index % n]) \(words[(index * 7 + 3) % n]) \(words[(index * 13 + 5) % n]) \(words[(index * 29 + 11) % n]) settled."
    }

    private func makeMemory(_ name: String) throws -> WorkspaceMemory {
        let workspace = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let memory = WorkspaceMemory(paths: paths)
        memory.setWorkspace(workspace)
        memory.prepareForPrompt(prompt: "start", runID: UUID(), provider: "test", model: "test")
        return memory
    }
}
