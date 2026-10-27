import XCTest
import Foundation
import PluginRuntime
@testable import DotsHarnessCore

/// Project memory and the person's memory are two layers. Project facts live in the repository.
/// The person's layer is their own folder
/// on this Mac. These tests hold the line between them: what the person says or does reaches
/// no file the repository tracks, and the project reaches the person only as a read at prompt time.
@MainActor
final class MemoryLayerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryLayerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - remember routes each kind to its layer

    func testPreferenceDefaultsToEveryProjectAndNeverReachesTheRepository() throws {
        XCTAssertEqual(RememberTool.parse(#"{"kind":"preference","key":"stack","text":"Builds apps with Flutter."}"#)?.scope, RememberTool.userScope)

        let (host, workspace) = try openedHost("preference")
        let call = AgentToolCall(id: "1", name: RememberTool.name, arguments: #"{"kind":"preference","key":"stack","text":"Builds apps with Flutter."}"#)
        XCTAssertEqual(host.remember(call), RememberTool.confirmation(try XCTUnwrap(RememberTool.parse(call.arguments))))
        XCTAssertEqual(host.memory.profile.preferences()["stack"], "Builds apps with Flutter.")
        XCTAssertFalse(repositoryContains("Flutter", in: workspace))
    }

    func testProjectPreferenceStaysOnThisMacUnderTheProject() throws {
        let (host, workspace) = try openedHost("project-preference")
        let call = AgentToolCall(id: "1", name: RememberTool.name, arguments: #"{"kind":"preference","scope":"project","key":"style","text":"Prefers tabs in this repo."}"#)
        _ = host.remember(call)
        let projectID = try XCTUnwrap(host.memory.projectID)
        XCTAssertEqual(host.memory.profile.projectPreferences(projectID: projectID)["style"], "Prefers tabs in this repo.")
        XCTAssertFalse(repositoryContains("tabs", in: workspace))
    }

    func testProjectEntryAndDecisionAreTheRepositorysOnly() throws {
        let (host, workspace) = try openedHost("project-entry")
        _ = host.remember(AgentToolCall(id: "1", name: RememberTool.name, arguments: #"{"kind":"project","key":"goal","text":"Ship the vault."}"#))
        XCTAssertEqual(host.memory.projectDefaults["goal"], "Ship the vault.")
        XCTAssertTrue(repositoryContains("Ship the vault.", in: workspace))
        XCTAssertFalse(folderContains("Ship the vault.", in: host.memory.userMemoryDirectory))
    }

    func testReplyLanguageIsKeptInTheProfileOnly() throws {
        let (host, workspace) = try openedHost("language")
        let runID = UUID()
        host.memory.prepareForPrompt(prompt: "Bundan sonra Türkçe cevap ver", runID: runID, provider: "test", model: "test")
        host.memory.finishTask(runID: runID, success: true, finalText: "Tamam.")
        XCTAssertEqual(host.memory.profile.preferences()["language"], "Turkish")
        XCTAssertFalse(repositoryContains("Turkish", in: workspace))
    }

    // MARK: - Activity and feedback stay with the person

    func testTaskAndToolActivityStayOnThisMac() throws {
        let (host, workspace) = try openedHost("activity")
        let runID = UUID()
        host.memory.prepareForPrompt(prompt: "Refactor the login screen", runID: runID, provider: "test", model: "test")
        host.memory.recordTool(
            runID: runID,
            call: AgentToolCall(id: "1", name: "read_file", arguments: #"{"path":"README.md"}"#),
            result: "ok", beforeFile: nil, beforeGit: [], afterGit: [], workspace: workspace
        )
        host.memory.finishTask(runID: runID, success: true, finalText: "Done.")

        XCTAssertFalse(repositoryContains("Refactor the login screen", in: workspace))
        XCTAssertFalse(repositoryContains(runID.uuidString, in: workspace))
        let folder = try XCTUnwrap(host.memory.userMemoryDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("tasks/\(runID.uuidString).md").path))
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("activity.jsonl"), encoding: .utf8).contains(runID.uuidString))
    }

    func testFeedbackIsKeptInTheUserLayer() throws {
        let (host, workspace) = try openedHost("feedback")
        try XCTUnwrap(host.feedbackStore).upsert(FeedbackRecord(
            conversationID: "c", messageID: "m", prompt: "p", response: "A distinctive answer.", feedbackType: .good
        ))
        let folder = try XCTUnwrap(host.memory.userMemoryDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("feedback.jsonl").path))
        XCTAssertFalse(repositoryContains("A distinctive answer.", in: workspace))
    }

    /// Memory writes into `.mem` are the host's bookkeeping, not work the model did.
    func testMemoryWritesAreNotReportedAsChangedFiles() async throws {
        let (host, workspace) = try openedHost("changed")
        try runGit(["init", "-q"], in: workspace)
        try host.memory.setProjectDefault(key: "goal", value: "Ship the vault.")
        try "edited".write(to: workspace.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let changed = await host.memory.changedGitPaths(workspace: workspace)
        XCTAssertTrue(changed.contains("notes.txt"))
        XCTAssertFalse(changed.contains { $0 == ".mem" || $0.hasPrefix(".mem/") })
    }

    // MARK: - The prompt reads each layer in its own section

    func testPromptCarriesEachLayerInItsOwnSection() throws {
        let (host, workspace) = try openedHost("sections")
        _ = host.remember(AgentToolCall(id: "1", name: RememberTool.name, arguments: #"{"kind":"project","key":"goal","text":"Project goal alpha."}"#))
        _ = host.remember(AgentToolCall(id: "2", name: RememberTool.name, arguments: #"{"kind":"preference","scope":"project","key":"style","text":"Preference beta."}"#))
        let runID = UUID()
        host.memory.prepareForPrompt(prompt: "Gamma task", runID: runID, provider: "test", model: "test")
        host.memory.recordTool(
            runID: runID,
            call: AgentToolCall(id: "3", name: "read_file", arguments: #"{"path":"README.md"}"#),
            result: "ok", beforeFile: nil, beforeGit: [], afterGit: [], workspace: workspace
        )
        host.memory.finishTask(runID: runID, success: true, finalText: "Done.")

        let sections = host.systemPromptSections(workspace: workspace, prompt: "Gamma task")
        func text(_ tag: String) -> String { sections.first { $0.tag == tag }?.text ?? "" }
        XCTAssertTrue(text("project_memory").contains("Project goal alpha."))
        XCTAssertFalse(text("project_memory").contains("Preference beta."))
        XCTAssertFalse(text("project_memory").contains("Gamma task"))
        XCTAssertTrue(text("learned_rules").contains("Preference beta."))
        XCTAssertFalse(text("learned_rules").contains("Project goal alpha."))
        XCTAssertTrue(text("task_history").contains("Gamma task"))
    }

    // MARK: - Vault: the person's notes link to the project, never the other way

    func testVaultEdgesRunFromThePersonToTheProjectOnly() throws {
        let (host, workspace) = try openedHost("vault")
        _ = host.remember(AgentToolCall(id: "1", name: RememberTool.name, arguments: #"{"kind":"preference","key":"tone","text":"Brief."}"#))
        let runID = UUID()
        host.memory.prepareForPrompt(prompt: "Add a footer", runID: runID, provider: "test", model: "test")
        host.memory.recordTool(
            runID: runID,
            call: AgentToolCall(id: "1", name: "read_file", arguments: #"{"path":"README.md"}"#),
            result: "ok", beforeFile: nil, beforeGit: [], afterGit: [], workspace: workspace
        )
        host.memory.finishTask(runID: runID, success: true, finalText: "Done.")

        let vault = host.memory.vault()
        let userIDs = Set(vault.notes.filter { $0.layer == .user }.map(\.id))
        let projectIDs = Set(vault.notes.filter { $0.layer == .project }.map(\.id))
        XCTAssertTrue(userIDs.contains("task-\(runID.uuidString)"))
        XCTAssertTrue(projectIDs.contains("map") && projectIDs.contains("index"))
        for edge in vault.edges where projectIDs.contains(edge.from) {
            XCTAssertFalse(userIDs.contains(edge.to), "\(edge.from) links to the person's \(edge.to)")
        }
    }

    // MARK: - The profile is the main memory; the project wins where the two disagree

    func testProjectValueReplacesTheEverywhereValueInThatProjectOnly() throws {
        let (host, workspace) = try openedHost("override")
        try host.memory.setUserPreference(key: "tone", value: "Long and detailed.")
        try host.memory.setUserPreference(key: "language", value: "Turkish")
        try host.memory.setProjectUserPreference(key: "tone", value: "Brief.")

        let sections = host.systemPromptSections(workspace: workspace, prompt: "hello")
        func text(_ tag: String) -> String { sections.first { $0.tag == tag }?.text ?? "" }
        XCTAssertFalse(text("user_memory").contains("Long and detailed."))
        XCTAssertTrue(text("user_memory").contains("language: Turkish"))
        XCTAssertTrue(text("learned_rules").contains("Brief."))
        // Outside the project the person's own value still holds.
        XCTAssertTrue(host.memory.profile.text().contains("Long and detailed."))

        let vault = host.memory.vault()
        let everywhere = WorkspaceMemory.preferenceNotePrefix + "everywhere:tone"
        let own = WorkspaceMemory.preferenceNotePrefix + "project:tone"
        XCTAssertTrue(vault.edges.contains { $0.from == own && $0.to == everywhere })
        XCTAssertEqual(vault.notes.first { $0.id == everywhere }?.tags.contains("overridden"), true)
        XCTAssertTrue(vault.edges.contains { $0.from == everywhere && $0.to == "user-profile" })
    }

    func testTasksLinkToTheToolsAndSkillsTheyUsedWeightedByCalls() throws {
        let (host, workspace) = try openedHost("usage")
        let runID = UUID()
        host.memory.prepareForPrompt(prompt: "Read twice", runID: runID, provider: "test", model: "test")
        for id in ["1", "2"] {
            host.memory.recordTool(
                runID: runID,
                call: AgentToolCall(id: id, name: "read_file", arguments: #"{"path":"README.md"}"#),
                result: "ok", beforeFile: nil, beforeGit: [], afterGit: [], workspace: workspace
            )
        }
        host.memory.recordSkill(runID: runID, skill: "pdf")
        // A run this memory never began leaves nothing in the project's records.
        host.memory.recordSkill(runID: UUID(), skill: "elsewhere")
        host.memory.finishTask(runID: runID, success: true, finalText: "Done.")

        let vault = host.memory.vault()
        let task = "task-\(runID.uuidString)"
        XCTAssertEqual(vault.edges.first { $0.from == task && $0.to == "tool:read_file" }?.weight, 2)
        XCTAssertEqual(vault.edges.first { $0.from == task && $0.to == "skill:pdf" }?.weight, 1)
        XCTAssertNil(vault.notes.first { $0.id == "skill:elsewhere" })
        XCTAssertFalse(vault.notes.contains { $0.kind == "missing" })
    }

    // MARK: - Findings: what the work taught, not the chat

    func testScanTurnsFinishedTasksIntoFindingsThatAreRecalledAndStrengthened() throws {
        let (host, workspace) = try openedHost("findings")
        let memory = host.memory
        func finishTask(_ prompt: String, command: String, result: String, finalText: String = "Done.") -> String {
            let runID = UUID()
            memory.prepareForPrompt(prompt: prompt, runID: runID, provider: "test", model: "test")
            memory.recordTool(
                runID: runID,
                call: AgentToolCall(id: "1", name: "run_command", arguments: #"{"command":"\#(command)"}"#),
                result: result, beforeFile: nil, beforeGit: [], afterGit: [], workspace: workspace
            )
            memory.finishTask(runID: runID, success: true, finalText: finalText)
            return runID.uuidString
        }
        XCTAssertFalse(memory.memoryScanDue(interval: .hourly), "nothing finished, nothing to read")
        let first = finishTask("Fix the billing webhook", command: "swift test", result: "error: signature mismatch")
        XCTAssertTrue(memory.memoryScanDue(interval: .hourly))
        XCTAssertFalse(memory.memoryScanDue(interval: .off))

        let batch = try XCTUnwrap(memory.nextScanBatch())
        XCTAssertEqual(batch.runIDs, [first])
        XCTAssertTrue(batch.payload.contains("run_command `swift test` [FAILED]"))
        XCTAssertFalse(memory.applyScan(reply: "I could not decide.", runIDs: batch.runIDs), "not JSON: the batch stays unread")
        XCTAssertEqual(memory.unscannedTaskCount, 1)

        let reply = #"Here: {"insights":[{"kind":"error","text":"Billing webhook failed on a signature mismatch; fixed in Webhook.swift.","files":["Sources/Webhook.swift"],"tools":["run_command"],"runs":["\#(first)","made-up"]}]}"#
        XCTAssertTrue(memory.applyScan(reply: reply, runIDs: batch.runIDs))
        let learned = try XCTUnwrap(memory.insights.first)
        XCTAssertEqual(learned.runs, [first], "only tasks of the batch can be named")
        XCTAssertEqual(memory.unscannedTaskCount, 0)
        XCTAssertFalse(memory.memoryScanDue(interval: .hourly, now: Date().addingTimeInterval(7_200)), "no new task, no model call")

        // The activity log stays redacted; the compact task outcome remains searchable.
        let folder = try XCTUnwrap(memory.userMemoryDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("tasks/\(first).md").path))
        let activity = try String(contentsOf: folder.appendingPathComponent("activity.jsonl"), encoding: .utf8)
        XCTAssertFalse(activity.contains("Fix the billing webhook"))
        XCTAssertTrue(activity.contains("tool.executed"), "tool calls stay, as counts")
        XCTAssertEqual(memory.historyText(for: "unrelated words").contains("Fix the billing webhook"), false)

        // Within the budget every finding is recalled, whatever the request's words, and
        // through the task history section.
        XCTAssertTrue(memory.insightsText(for: "the webhook breaks again").contains("signature mismatch"))
        XCTAssertEqual(memory.insightsText(for: "rename the settings pane"), memory.insightsText(for: "webhook imzası tutmuyor"))
        let history = host.systemPromptSections(workspace: workspace, prompt: "the webhook breaks again").first { $0.tag == "task_history" }?.text ?? ""
        XCTAssertTrue(history.contains("[error] Billing webhook failed"))
        XCTAssertFalse(repositoryContains("signature mismatch", in: workspace))

        // Met again in a later task: the same finding grows stronger instead of doubling.
        let second = finishTask("Webhook again", command: "swift test", result: "ok")
        XCTAssertFalse(memory.memoryScanDue(interval: .daily), "the interval has not passed")
        XCTAssertTrue(memory.memoryScanDue(interval: .daily, now: Date().addingTimeInterval(90_000)))
        XCTAssertTrue(memory.applyScan(
            reply: #"{"insights":[{"id":"\#(learned.id)","kind":"error","text":"\#(learned.text)","runs":["\#(second)"]}]}"#,
            runIDs: [second]
        ))
        XCTAssertEqual(memory.insights.count, 1)
        XCTAssertEqual(memory.insights.first?.strength, 2)

        // In the graph it links to the tool and file; task notes stay on disk for recall.
        let vault = memory.vault()
        let id = WorkspaceMemory.insightNotePrefix + learned.id
        for target in ["tool:run_command", "file:Sources/Webhook.swift"] {
            XCTAssertEqual(vault.edges.first { $0.from == id && $0.to == target }?.weight, 2, target)
        }
        XCTAssertTrue(vault.notes.contains { $0.kind == "task" && $0.id == "task-\(first)" })
        XCTAssertEqual(vault.notes.first { $0.id == "index" }?.title, workspace.lastPathComponent)

        // Another project's findings hang off a root of their own and stay out of this project's chat.
        let other = folder.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(#"{"insights":[{"id":"abc","kind":"how","text":"Deploys go through wrangler.","files":[],"tools":[],"runs":[],"strength":1,"updatedAt":""}],"scannedRuns":[]}"#.utf8)
            .write(to: other.appendingPathComponent("insights.json"))
        let both = memory.vault()
        let otherRoot = WorkspaceMemory.otherProjectPrefix + other.lastPathComponent
        XCTAssertTrue(both.edges.contains { $0.from == otherRoot + "/abc" && $0.to == otherRoot })
        XCTAssertEqual(both.notes.first { $0.id == otherRoot + "/abc" }?.tags.first { $0 == "lesson" }, "lesson", "an older kind reads as a lesson")
        XCTAssertFalse(host.memoryChatContext(for: "wrangler deploys", vault: both).contains("wrangler"))
        XCTAssertFalse(memory.insightsText(for: "wrangler deploys").contains("wrangler"))

        // The finding hangs off the project's root, and a decision is listed before it.
        XCTAssertTrue(vault.edges.contains { $0.from == id && $0.to == "index" })
        memory.writeInsight(id: nil, kind: .decision, text: "Networking stays on URLSession; no Alamofire.")
        XCTAssertTrue(memory.insightsText(for: "rename the settings pane").hasPrefix("- [decision] Networking stays on URLSession"))
        memory.deleteInsight(id: try XCTUnwrap(memory.insights.last).id)

        // Past the budget: whole lines only, what the request names first - by a longer form
        // of its word too - and the count of what was left out.
        let kept = memory.insights
        for number in 0..<60 {
            memory.writeInsight(id: nil, kind: .lesson, text: "Filler \(number) " + String(repeating: "x", count: 180))
        }
        let crowded = memory.insightsText(for: "webhooks keep failing")
        XCTAssertTrue(crowded.hasPrefix("- [error] Billing webhook failed"))
        XCTAssertLessThanOrEqual(crowded.count, WorkspaceMemory.insightBudget + 60)
        XCTAssertTrue(crowded.hasSuffix("weaker findings not shown; search them with recall]"))
        memory.insights.filter { !kept.contains($0) }.forEach { memory.deleteInsight(id: $0.id) }

        // Deleting the tasks it came from takes the finding with them.
        try memory.deleteTaskNote(runID: first)
        XCTAssertEqual(memory.insights.first?.runs, [second])
        try memory.deleteTaskNote(runID: second)
        XCTAssertTrue(memory.insights.isEmpty)
    }

    func testReasonedDecisionOutcomeSurvivesAnEmptyScanAndRecall() throws {
        let (host, workspace) = try openedHost("reasoned-task-outcome")
        let memory = host.memory
        let reason = "Kept max planning and medium tool effort unchanged because prior runs showed that changing effort invalidated most prompt cache."
        let runID = UUID()
        memory.prepareForPrompt(prompt: "Add wait tool and lock wait", runID: runID, provider: "test", model: "test")
        memory.recordTool(
            runID: runID,
            call: AgentToolCall(id: "1", name: "run_command", arguments: #"{"command":"swift test"}"#),
            result: "ok", beforeFile: nil, beforeGit: [], afterGit: [], workspace: workspace
        )
        memory.finishTask(runID: runID, success: true, finalText: reason)

        let batch = try XCTUnwrap(memory.nextScanBatch())
        XCTAssertTrue(batch.payload.contains(reason))
        XCTAssertTrue(memory.applyScan(reply: #"{"insights":[]}"#, runIDs: batch.runIDs))

        let folder = try XCTUnwrap(memory.userMemoryDirectory)
        let note = folder.appendingPathComponent("tasks/\(runID.uuidString).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
        XCTAssertTrue(memory.historyText(for: "medium effort prompt cache").contains(reason))
        XCTAssertTrue(memory.recallText(query: "medium effort prompt cache").contains(reason))
    }

    // MARK: - Memory starts by itself and studies the project a part at a time

    func testAPromptedProjectIsStudiedInPartsAndAnUnpromptedOneIsLeftAlone() throws {
        let (host, workspace) = try openedHost("study")
        try Data("Run the tests with `swift test`. token=abcdefghijklmnop".utf8).write(to: workspace.appendingPathComponent("README.md"))
        let app = workspace.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("node_modules/dep"), withIntermediateDirectories: true)
        try Data("The app talks to the worker only.".utf8).write(to: app.appendingPathComponent("README.md"))
        try Data("ignored".utf8).write(to: app.appendingPathComponent("node_modules/dep/README.md"))
        // A folder no prompt was sent in has no memory and is given none by the background work.
        let fresh = workspace.deletingLastPathComponent().appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        let unprompted = WorkspaceMemory(paths: host.paths)
        unprompted.setWorkspace(fresh)
        XCTAssertNil(unprompted.nextStudyBatch())
        XCTAssertFalse(unprompted.compactActivity())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.appendingPathComponent(".mem").path))

        let memory = host.memory
        let root = try XCTUnwrap(memory.nextStudyBatch())
        XCTAssertEqual(root.area, ".")
        XCTAssertTrue(root.payload.contains("swift test") && !root.payload.contains("abcdefghijklmnop"))
        XCTAssertFalse(root.payload.contains("talks to the worker"), "a folder is a part of its own")
        memory.applyStudy(reply: #"{"insights":[{"kind":"lesson","text":"Tests run with swift test.","files":["README.md"]}]}"#, area: root.area)
        XCTAssertEqual(memory.insights.map(\.kind), [.lesson])
        XCTAssertNil(memory.lastMemoryScan, "a study does not put the task scan off")

        let part = try XCTUnwrap(memory.nextStudyBatch())
        XCTAssertEqual(part.area, "app")
        XCTAssertTrue(part.payload.contains("talks to the worker") && part.payload.contains("Tests run with swift test."))
        XCTAssertFalse(part.payload.contains("node_modules"))
        memory.applyStudy(reply: "I cannot say.", area: part.area)
        XCTAssertNil(memory.nextStudyBatch(), "every part is read once")
        XCTAssertEqual(memory.insights.count, 1)

        // The background work leaves the home folder, a volume and temporary folders alone.
        XCTAssertTrue(WorkspaceMemory.isProjectFolder(URL(fileURLWithPath: "/Volumes/Disk/Projects/app")))
        for path in [FileManager.default.homeDirectoryForCurrentUser.path, "/Volumes/Disk", "/tmp/scratch/app", NSTemporaryDirectory() + "x/y"] {
            XCTAssertFalse(WorkspaceMemory.isProjectFolder(URL(fileURLWithPath: path)), path)
        }
    }

    func testMemoryIsCompactedNotCutAndGoesQuietWhenSwitchedOff() throws {
        let (host, workspace) = try openedHost("compact")
        let memory = host.memory
        let user = try XCTUnwrap(memory.userMemoryDirectory)
        try Data("Deploy with make ship.".utf8).write(to: workspace.appendingPathComponent("README.md"))
        try runGit(["init"], in: workspace)
        try runGit(["add", "README.md"], in: workspace)

        // The log: a task whose note is kept stays in full, the rest becomes one count per tool.
        let tasks = user.appendingPathComponent("tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        try Data("status: unfinished".utf8).write(to: tasks.appendingPathComponent("open.md"))
        let log = user.appendingPathComponent("activity.jsonl")
        let call = { (run: String, status: String) in #"{"type":"tool.executed","payload":{"runId":"\#(run)","name":"read_file","resultStatus":"\#(status)"}}"# + "\n" }
        try (#"{"type":"task.started","payload":{"runId":"done","promptSummary":"what the person typed"}}"# + "\n"
            + call("done", "completed") + call("done", "failed") + call("gone", "completed") + call("open", "completed"))
            .write(to: log, atomically: true, encoding: .utf8)
        XCTAssertTrue(memory.compactActivity())
        XCTAssertFalse(memory.compactActivity(), "a compacted log is not rewritten")
        let kept = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(kept.split(separator: "\n").count, 2)
        XCTAssertFalse(kept.contains("what the person typed"))
        XCTAssertTrue(kept.contains(#""runId":"open""#))
        XCTAssertTrue(memory.vault().notes.contains { $0.id == "tool:read_file" && $0.body.contains("Used 4 times in 3 tasks") }, "every call is still counted")

        // The findings: nothing goes for being old; the model merges, and a reply that guts memory is refused.
        let rows = (0..<WorkspaceMemory.consolidationStep).map { #"{"kind":"lesson","text":"Fact number \#($0) of the project."}"# }.joined(separator: ",")
        XCTAssertTrue(memory.applyScan(reply: #"{"insights":[\#(rows)]}"#, runIDs: [], now: Date(timeIntervalSince1970: 0)))
        let ids = memory.insights.map(\.id)
        XCTAssertEqual(ids.count, WorkspaceMemory.consolidationStep)
        XCTAssertNotNil(memory.consolidationPayload())
        memory.applyConsolidation(reply: #"{"insights":[],"drop":\#(ids)}"#)
        XCTAssertEqual(memory.insights.count, ids.count)
        XCTAssertNil(memory.consolidationPayload(), "asked again only after more is learned")
        memory.applyConsolidation(reply: #"{"insights":[{"id":"\#(ids[0])","kind":"decision","text":"Facts 0 and 1 are one."},{"kind":"lesson","text":"Invented."}],"drop":["\#(ids[1])","nobody"]}"#)
        XCTAssertEqual(memory.insights.count, ids.count - 1)
        XCTAssertEqual(memory.insights.first?.text, "Facts 0 and 1 are one.")
        XCTAssertEqual(memory.insights.last?.text, "Fact number \(ids.count - 1) of the project.", "what did not change stays as it is")

        // Switched off: nothing is written or handed over, but the file index still answers.
        host.setMemoryEnabled(false)
        XCTAssertNil(memory.userMemoryDirectory)
        XCTAssertNil(host.feedbackStore)
        XCTAssertEqual(host.remember(AgentToolCall(id: "1", name: RememberTool.name, arguments: #"{"kind":"preference","key":"stack","text":"Flutter."}"#)), RememberTool.unavailableNotice)
        XCTAssertTrue(memory.filesText(for: "readme").contains("README.md"))
        let quiet = workspace.deletingLastPathComponent().appendingPathComponent("quiet", isDirectory: true)
        try FileManager.default.createDirectory(at: quiet, withIntermediateDirectories: true)
        host.start(workspacePath: quiet.path)
        host.memory.prepareForPrompt(prompt: "start", runID: UUID(), provider: "test", model: "test")
        XCTAssertFalse(host.openProjectMemory())
        XCTAssertFalse(FileManager.default.fileExists(atPath: quiet.appendingPathComponent(".mem").path))
    }

    func testAutomaticMemoryWorkDefersWhileAgentIsBusy() throws {
        let (host, workspace) = try openedHost("memory-work-busy")
        defer { try? FileManager.default.removeItem(at: workspace) }

        XCTAssertTrue(host.canStartAutomaticMemoryWork())
        host.isBusy = true
        XCTAssertFalse(host.canStartAutomaticMemoryWork())
        host.isBusy = false
        XCTAssertTrue(host.canStartAutomaticMemoryWork())
    }

    // MARK: - Memory chat: adds and corrects at once, deletes only when confirmed

    func testMemoryChatActionsAddAndCorrectButOnlyProposeDeletion() throws {
        let (host, workspace) = try openedHost("chat")
        try host.memory.setProjectDefault(key: "goal", value: "Ship the desktop app.")
        let outcome = host.applyMemoryChatActions([
            ["op": "set_project", "key": "constraints", "value": "Must run on every platform."],
            ["op": "set_preference", "key": "tone", "value": "Brief.", "scope": "project"],
            ["op": "add_rule", "text": "Run the tests before answering."],
            ["op": "add_finding", "kind": "ran", "text": "Tests run with swift test in macos/DotsHarness."],
            ["op": "add_finding", "kind": "ran", "text": "api_key=sk-abcdefghijklmnopqrstuvwx"],
            ["op": "delete", "id": WorkspaceMemory.projectNotePrefix + "goal"],
            ["op": "delete", "id": "no-such-note"],
            ["op": "format_disk"],
        ], vault: host.memoryVault)

        XCTAssertEqual(host.memory.projectDefaults["constraints"], "Must run on every platform.")
        XCTAssertEqual(host.memory.profile.projectPreferences(projectID: try XCTUnwrap(host.memory.projectID))["tone"], "Brief.")
        XCTAssertTrue(host.manualRules.contains("Run the tests before answering."))
        XCTAssertEqual(host.memory.insights.map(\.text), ["Tests run with swift test in macos/DotsHarness."], "a credential is refused")
        XCTAssertEqual(outcome.applied.count, 5)
        XCTAssertTrue(outcome.applied.last?.hasPrefix("Not saved") == true || outcome.applied.last?.hasPrefix("Kaydedilmedi") == true)
        // The deletion is returned for the person to confirm; nothing is gone yet.
        XCTAssertEqual(outcome.deletions.map(\.edit), [.forgetProject(key: "goal")])
        XCTAssertEqual(host.memory.projectDefaults["goal"], "Ship the desktop app.")

        let finding = try XCTUnwrap(host.memory.insights.first)
        _ = host.applyMemoryChatActions(
            [["op": "edit_finding", "id": WorkspaceMemory.insightNotePrefix + finding.id, "text": "Tests run with swift test."]],
            vault: host.memoryVault
        )
        XCTAssertEqual(host.memory.insights.map(\.text), ["Tests run with swift test."])
        // The question's own notes reach the model, with the ids it answers by.
        let context = host.memoryChatContext(for: "how do I run the tests", vault: host.memoryVault)
        XCTAssertTrue(context.contains("id: " + WorkspaceMemory.insightNotePrefix + finding.id))
        XCTAssertTrue(context.contains("id: " + WorkspaceMemory.projectNotePrefix + "goal"))
        XCTAssertFalse(repositoryContains("swift test", in: workspace))
    }

    func testMemoryChatIsKeptForTheProjectOutsideTheRepository() throws {
        let (host, workspace) = try openedHost("chat-kept")
        var answer = MemoryChatTurn(role: .assistant, text: "With swift test.", applied: ["Rule: x"])
        answer.deletions = [MemoryChatDeletion(id: "n", title: "n", edit: .forgetProject(key: "goal"))]
        let history = [MemoryChatTurn(role: .user, text: "How do I run the zebra suite?"), answer]
        host.saveMemoryChat(history)
        let kept = host.memoryChatHistory
        XCTAssertEqual(kept.map(\.id), history.map(\.id))
        XCTAssertEqual(kept.last?.applied, ["Rule: x"])
        XCTAssertEqual(kept.last?.deletions, [], "a proposal does not outlive the window")
        XCTAssertFalse(repositoryContains("zebra", in: workspace))
        host.saveMemoryChat([])
        XCTAssertEqual(host.memoryChatHistory, [])
    }

    // MARK: - Files named like the request are recalled

    func testFilesAreRecalledByTheWordsOfTheirNames() {
        let common = (0..<40).map { "Sources/UI/Panel\($0)View.swift" }
        let index = FileIndex(paths: common + ["Sources/UI/MemoryVaultView.swift", "Sources/Core/billing_webhook.ts", "\"odd\\303\\251.txt\""])
        XCTAssertEqual(index.matching("the memory vault shows nothing"), ["Sources/UI/MemoryVaultView.swift"])
        XCTAssertEqual(index.matching("fix MemoryVaultView.swift"), ["Sources/UI/MemoryVaultView.swift"])
        XCTAssertEqual(index.matching("webhook fails"), ["Sources/Core/billing_webhook.ts"])
        XCTAssertEqual(index.matching("restyle the view"), [], "a word forty files share picks none")
    }

    func testFileIndexCacheStampIncludesWorkspaceAndLearnedInputs() {
        let learned = ["Sources/Billing.swift": Set(["invoice", "payment"])]
        let stamp = WorkspaceMemory.fileIndexCacheStamp(workspaceStamp: "workspace-v1", learned: learned)

        XCTAssertEqual(stamp, WorkspaceMemory.fileIndexCacheStamp(workspaceStamp: "workspace-v1", learned: learned))
        XCTAssertNotEqual(stamp, WorkspaceMemory.fileIndexCacheStamp(workspaceStamp: "workspace-v2", learned: learned))
        XCTAssertNotEqual(
            stamp,
            WorkspaceMemory.fileIndexCacheStamp(workspaceStamp: "workspace-v1", learned: ["Sources/Billing.swift": ["invoice", "refund"]])
        )
    }

    func testFilesAreRecalledByWhatTheyDeclare() {
        XCTAssertEqual(
            FileIndex.symbols(in: "final class InvoiceMailer {\n  func sendReminder() {}\n  func sendReminder(x: Int) {}\n}\nexport function parseWebhook() {}"),
            ["InvoiceMailer", "sendReminder", "parseWebhook"]
        )
        let index = FileIndex(
            paths: ["src/a.swift", "src/reminder.swift"],
            symbols: ["src/a.swift": ["InvoiceMailer", "sendReminder"], "src/reminder.swift": ["Unrelated"]]
        )
        let hits = index.hits("the invoice reminder is sent twice")
        // Two declarations the request names outweigh one word of a file's name.
        XCTAssertEqual(hits.map(\.path), ["src/a.swift", "src/reminder.swift"])
        XCTAssertEqual(hits.first?.symbols, ["InvoiceMailer", "sendReminder"])
        XCTAssertEqual(index.matching("unknown words only"), [])
    }

    /// Symbols survive a relaunch in `symbols.json`, and a file whose date stands is not
    /// read again; `git log` reruns only when HEAD's reflog moves.
    func testSavedSymbolsAreReusedAndGitHistoryIsStampedByHead() throws {
        let file = root.appendingPathComponent("src/a.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A whole-second date: the file system keeps it exactly.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try "final class InvoiceMailer {}".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let cacheURL = root.appendingPathComponent("user/symbols.json")
        FileIndex.saveSymbols(FileIndex.scanSymbols(paths: ["src/a.swift"], workspace: root, known: [:]), to: cacheURL)

        // Same date, new text: the saved names are kept, so the file was not read.
        try "final class Replaced {}".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let saved = FileIndex.loadSymbols(cacheURL)
        XCTAssertEqual(FileIndex.scanSymbols(paths: ["src/a.swift"], workspace: root, known: saved)["src/a.swift"]?.names, ["InvoiceMailer"])
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(5)], ofItemAtPath: file.path)
        XCTAssertEqual(FileIndex.scanSymbols(paths: ["src/a.swift"], workspace: root, known: saved)["src/a.swift"]?.names, ["Replaced"])

        XCTAssertNil(WorkspaceMemory.gitHistoryStamp(root))
        let reflog = root.appendingPathComponent(".git/logs/HEAD")
        try FileManager.default.createDirectory(at: reflog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "one\n".write(to: reflog, atomically: true, encoding: .utf8)
        let first = try XCTUnwrap(WorkspaceMemory.gitHistoryStamp(root))
        XCTAssertEqual(WorkspaceMemory.gitHistoryStamp(root), first)
        try "one\ntwo\n".write(to: reflog, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(WorkspaceMemory.gitHistoryStamp(root), first)
    }

    /// The map of where things are: one finding per concern, brought up to date when the
    /// concern is worked on again, and recalled by the words the person uses for it.
    func testAnAreaIsKeptOncePerConcernAndRecalledByItsWords() throws {
        let (host, _) = try openedHost("areas")
        let memory = host.memory
        XCTAssertTrue(memory.applyScan(
            reply: #"{"insights":[{"kind":"area","text":"Token sayımı: ContextTelemetry.swift içinde record(); son iş: önbellek sayımı düzeltildi.","files":["Sources/ContextTelemetry.swift"]}]}"#,
            runIDs: []
        ))
        let id = try XCTUnwrap(memory.insights.first?.id)
        memory.applyScan(reply: #"{"insights":[{"id":"\#(id)","kind":"area","text":"Token sayımı: ContextTelemetry.swift içinde record(); son iş: çıktı tokenları eklendi."}]}"#, runIDs: [])
        XCTAssertEqual(memory.insights.map(\.kind), [.area])
        let recalled = memory.insightsText(for: "token sayımı yanlış çıkıyor")
        XCTAssertTrue(recalled.contains("[area]") && recalled.contains("çıktı tokenları eklendi") && recalled.contains("Sources/ContextTelemetry.swift"))
    }

    /// A request in another language than a finding still meets it through the keywords a scan wrote,
    /// and `recall` reaches only the open project's findings.
    func testRecallMatchesKeywordsAcrossLanguagesForTheOpenProjectOnly() throws {
        let (host, workspace) = try openedHost("recall")
        XCTAssertTrue(host.memory.applyScan(reply: #"""
        {"insights":[
          {"kind":"area","text":"Long-term memory lives in WorkspaceMemory+Insights.swift.","files":["Sources/WorkspaceMemory+Insights.swift"],"keywords":["memory","hafıza","bellek"]},
          {"kind":"lesson","text":"Release builds run scripts/package.sh.","keywords":["release","paketleme"]}
        ]}
        """#, runIDs: []))
        let found = host.memory.recallText(query: "hafıza nasıl çalışıyor")
        XCTAssertTrue(found.contains("WorkspaceMemory+Insights.swift"))
        XCTAssertFalse(found.contains("package.sh"))

        let call = AgentToolCall(id: "1", name: RecallTool.name, arguments: #"{"query":"bellek"}"#)
        XCTAssertTrue(host.recall(call, workspace: workspace).contains("Long-term memory"))
        XCTAssertEqual(host.recall(call, workspace: root.appendingPathComponent("elsewhere")), RecallTool.unavailableNotice)
        XCTAssertEqual(host.recall(AgentToolCall(id: "2", name: RecallTool.name, arguments: #"{"query":"kubernetes"}"#), workspace: workspace), RecallTool.emptyNotice)
    }

    func testFilesCarryTheirLatestCommit() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one".write(to: repo.appendingPathComponent("login.swift"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "Fix the login redirect"]] {
            _ = WorkspaceMemory.gitLines(arguments, workspace: repo)
        }
        XCTAssertEqual(WorkspaceMemory.lastChanges(workspace: repo)["login.swift"]?.hasSuffix(" Fix the login redirect"), true)
    }

    func testAFileIsRecalledByTheWordsOfTheTaskThatChangedIt() throws {
        let (host, workspace) = try openedHost("learned")
        let runID = UUID()
        host.memory.prepareForPrompt(prompt: "Fix the checkout payment flow", runID: runID, provider: "test", model: "test")
        host.memory.recordTool(
            runID: runID,
            call: AgentToolCall(id: "1", name: "run_command", arguments: "{}"),
            result: "ok", beforeFile: nil, beforeGit: [], afterGit: ["src/lib/paytr.ts"], workspace: workspace
        )
        host.memory.finishTask(runID: runID, success: true, finalText: "Done.")

        let learned = host.memory.taskFileTerms()
        XCTAssertEqual(learned["src/lib/paytr.ts"]?.contains("checkout"), true)
        let index = FileIndex(paths: ["src/lib/paytr.ts", "src/lib/smtp.ts"], learned: learned)
        XCTAssertEqual(index.matching("checkout is broken again"), ["src/lib/paytr.ts"])
        XCTAssertEqual(FileIndex(paths: ["src/lib/paytr.ts"]).matching("checkout is broken again"), [])
    }

    // MARK: - The map lists the project's documents by their headings

    func testTheMapListsDocumentsWithTheirHeadingsWithoutAModel() throws {
        let (host, workspace) = try openedHost("documents")
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try "# Billing\n\n```sh\n# not a heading\n```\n\n## Refund rules\n".write(
            to: workspace.appendingPathComponent("docs/billing.md"), atomically: true, encoding: .utf8)
        try "# Rules\n".write(to: workspace.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        host.memory.prepareForPrompt(prompt: "start", runID: UUID(), provider: "test", model: "test")
        let map = host.memory.projectText()
        XCTAssertTrue(map.contains("- `docs/billing.md` - Billing; Refund rules"), map)
        XCTAssertFalse(map.contains("not a heading"))
        XCTAssertFalse(map.contains("`AGENTS.md` -"), "the rule files are sent as rules, not listed again")
    }

    // MARK: - Deletion of the person's records is permanent

    func testDeletingAPersonsRecordsRemovesThemAndTheirActivity() throws {
        let (host, workspace) = try openedHost("delete")
        let runID = UUID()
        host.memory.prepareForPrompt(prompt: "Add a footer", runID: runID, provider: "test", model: "test")
        host.memory.recordTool(
            runID: runID,
            call: AgentToolCall(id: "1", name: "read_file", arguments: #"{"path":"README.md"}"#),
            result: "ok", beforeFile: nil, beforeGit: [], afterGit: [], workspace: workspace
        )
        host.memory.finishTask(runID: runID, success: true, finalText: "Done.")
        let folder = try XCTUnwrap(host.memory.userMemoryDirectory)
        let note = folder.appendingPathComponent("tasks/\(runID.uuidString).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))

        XCTAssertTrue(host.editMemory(.deleteTask(runID: runID.uuidString)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        XCTAssertFalse(try String(contentsOf: folder.appendingPathComponent("activity.jsonl"), encoding: .utf8).contains(runID.uuidString))

        XCTAssertTrue(host.editMemory(.setPreference(key: "tone", value: "Brief.", scope: .everywhere)))
        XCTAssertEqual(host.memory.profile.preferences()["tone"], "Brief.")
        XCTAssertTrue(host.editMemory(.deletePreference(key: "tone", scope: .everywhere)))
        XCTAssertNil(host.memory.profile.preferences()["tone"])

        XCTAssertTrue(host.editMemory(.addManualRule("Keep the loading state.")))
        XCTAssertTrue(host.manualRules.contains("Keep the loading state."))
        XCTAssertFalse(repositoryContains("Keep the loading state.", in: workspace))
    }

    // MARK: - Helpers

    /// A host on a fresh workspace with the project's memory opened, as the first prompt does.
    // MARK: - rules are never compacted away

    func testEveryFindingFitsThePromptAndGrowthAsksForCompaction() throws {
        let (host, _) = try openedHost("budget")
        let memory = host.memory
        // Fifty findings: past the budget with their file lists, under it without them.
        let files = (0..<4).map { #""Sources/Module\#($0)/SomeRatherLongFileName\#($0).swift""# }.joined(separator: ",")
        let rows = (0..<50).map { number in
            let words = (0..<18).map { "w\(number)x\($0)" }.joined(separator: " ")
            return #"{"kind":"lesson","text":"Finding \#(number) \#(words)","files":[\#(files)]}"#
        }.joined(separator: ",")
        XCTAssertTrue(memory.applyScan(reply: #"{"insights":[\#(rows)]}"#, runIDs: [], now: Date(timeIntervalSince1970: 0)))
        XCTAssertGreaterThan(memory.insightsSize, WorkspaceMemory.insightTarget)

        let text = memory.insightsText(for: "hafıza penceresi")
        XCTAssertLessThanOrEqual(text.count, WorkspaceMemory.insightBudget)
        for number in 0..<50 { XCTAssertTrue(text.contains("Finding \(number) w"), "finding \(number) is left out") }
        XCTAssertFalse(text.contains("not shown"))
        XCTAssertFalse(text.contains("SomeRatherLongFileName"), "the file lists give way first")

        // Past the target the model is asked to fold them, and told how far.
        let payload = try XCTUnwrap(memory.consolidationPayload())
        XCTAssertTrue(payload.hasPrefix("## Size\nTheir text takes \(memory.insightsSize) characters"))
        let marker = "at most \(WorkspaceMemory.shortFinding) characters long, every fact kept: "
        let named = try XCTUnwrap(payload.components(separatedBy: marker).last?.components(separatedBy: "\n").first)
            .components(separatedBy: ", ")
        XCTAssertFalse(named.isEmpty, "the longest findings are named")
        XCTAssertTrue(named.allSatisfy { id in (memory.insights.first { $0.id == id }?.text.count ?? 0) > WorkspaceMemory.shortFinding })
        let dropped = memory.insights.prefix(4).map { #""\#($0.id)""# }.joined(separator: ",")
        memory.applyConsolidation(reply: #"{"insights":[],"drop":[\#(dropped)]}"#)
        XCTAssertNotNil(memory.consolidationPayload(), "it shrank but is still over the target: asked again")
        memory.applyConsolidation(reply: #"{"insights":[],"drop":[]}"#)
        XCTAssertNil(memory.consolidationPayload(), "a model that could not shrink them is not asked again at once")
        for number in 0..<WorkspaceMemory.consolidationSizeStep {
            memory.writeInsight(id: nil, kind: .lesson, text: "Later finding \(number).")
        }
        XCTAssertNotNil(memory.consolidationPayload(), "more findings, another try")
    }

    func testFindingTitlesEndAtTheSentenceOrAWord() {
        XCTAssertEqual(WorkspaceMemory.noteTitle("Alarm cleanup is eventual recovery, not real-time. A closed tab"), "Alarm cleanup is eventual recovery, not real-time")
        XCTAssertEqual(WorkspaceMemory.noteTitle("AGENTS.md and CLAUDE.md stay identical."), "AGENTS.md and CLAUDE.md stay identical")
        let long = WorkspaceMemory.noteTitle(String(repeating: "word ", count: 30))
        XCTAssertTrue(long.hasSuffix("word…"))
        XCTAssertLessThanOrEqual(long.count, 61)
    }

    func testRulesOutliveScansConsolidationAndTheCap() throws {
        let (host, _) = try openedHost("rules")
        let memory = host.memory
        memory.writeInsight(id: nil, kind: .lesson, text: "Always answer in Turkish.")
        XCTAssertTrue(memory.applyScan(
            reply: #"{"insights":[{"kind":"decision","text":"Networking stays on URLSession."}]}"#,
            runIDs: [], now: Date(timeIntervalSince1970: 0)
        ))
        let user = try XCTUnwrap(memory.insights.first { $0.source == MemoryInsight.userSource })
        let decision = try XCTUnwrap(memory.insights.first { $0.kind == .decision })

        // A scan may strengthen a rule, never reword or drop it.
        XCTAssertTrue(memory.applyScan(
            reply: #"{"insights":[{"id":"\#(user.id)","kind":"lesson","text":"Answer in English."}],"drop":["\#(decision.id)"]}"#,
            runIDs: []
        ))
        XCTAssertEqual(memory.insights.first { $0.id == user.id }?.text, "Always answer in Turkish.")
        XCTAssertEqual(memory.insights.first { $0.id == user.id }?.strength, 2)
        XCTAssertNotNil(memory.insights.first { $0.id == decision.id })

        // A scan reply that would drop more than half is not believed.
        XCTAssertTrue(memory.applyScan(reply: #"{"insights":[{"kind":"lesson","text":"One."},{"kind":"lesson","text":"Two."},{"kind":"lesson","text":"Three."}]}"#, runIDs: []))
        let open = memory.insights.filter { !$0.isRule }.map { "\"\($0.id)\"" }.joined(separator: ",")
        XCTAssertTrue(memory.applyScan(reply: #"{"insights":[],"drop":[\#(open)]}"#, runIDs: []))
        XCTAssertEqual(memory.insights.count, 5)

        // Past the cap the oldest, weakest finding goes - unless it is a rule.
        let rows = (0..<WorkspaceMemory.maxInsights).map { #"{"kind":"lesson","text":"Fact number \#($0)."}"# }.joined(separator: ",")
        XCTAssertTrue(memory.applyScan(reply: #"{"insights":[\#(rows)]}"#, runIDs: []))
        XCTAssertEqual(memory.insights.count, WorkspaceMemory.maxInsights)
        XCTAssertNotNil(memory.insights.first { $0.id == decision.id })
        XCTAssertNotNil(memory.insights.first { $0.id == user.id })

        // Consolidation never sees a rule, and a reply naming one changes nothing.
        let payload = try XCTUnwrap(memory.consolidationPayload())
        XCTAssertFalse(payload.contains("URLSession"))
        XCTAssertFalse(payload.contains("Turkish"))
        memory.applyConsolidation(reply: #"{"insights":[{"id":"\#(user.id)","kind":"lesson","text":"Merged."}],"drop":["\#(decision.id)"]}"#)
        XCTAssertEqual(memory.insights.first { $0.id == user.id }?.text, "Always answer in Turkish.")
        XCTAssertNotNil(memory.insights.first { $0.id == decision.id })
    }

    private func openedHost(_ name: String, device: String = "") throws -> (NativeAgentHost, URL) {
        let workspace = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let support = root.appendingPathComponent("support-\(name)\(device)", isDirectory: true)
        let paths = SupportPaths(
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
        let host = NativeAgentHost(paths: paths, endpoint: AgentEndpointController())
        host.start(workspacePath: workspace.path)
        host.memory.prepareForPrompt(prompt: "start", runID: UUID(), provider: "test", model: "test")
        host.syncFeedbackStore()
        return (host, workspace)
    }

    private func repositoryContains(_ text: String, in workspace: URL) -> Bool {
        folderContains(text, in: workspace.appendingPathComponent(".mem", isDirectory: true))
    }

    /// Whether any regular file under the folder contains the text.
    private func folderContains(_ text: String, in folder: URL?) -> Bool {
        guard let folder, let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return false
        }
        for case let url as URL in files {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if body.contains(text) { return true }
        }
        return false
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
