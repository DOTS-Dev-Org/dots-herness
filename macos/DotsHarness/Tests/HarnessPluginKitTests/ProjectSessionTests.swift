import Foundation
import XCTest
import PluginRuntime
@testable import DotsHarnessCore

final class ProjectSessionTests: XCTestCase {
    func testMigrationKeepsWorkspaceConversationsAndDeletesProjectlessChat() throws {
        let paths = temporaryPaths()
        let projectRoot = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let short = Conversation(
            id: "duplicate",
            title: "Short copy",
            messages: [ChatMessage(kind: .user, text: "first")],
            blank: false,
            cwd: projectRoot.path
        )
        let full = Conversation(
            id: "duplicate",
            title: "Full copy",
            messages: [
                ChatMessage(kind: .user, text: "first"),
                ChatMessage(kind: .assistant, text: "second"),
            ],
            blank: false,
            cwd: projectRoot.path
        )
        let project = Conversation(id: "project", title: "Project", blank: false, cwd: projectRoot.path)
        let projectless = Conversation(id: "free-chat", title: "Free chat", blank: false)
        try JSONEncoder().encode([short, project]).write(to: paths.root.appendingPathComponent("coding-sessions.json"))
        try JSONEncoder().encode([full, projectless]).write(to: paths.root.appendingPathComponent("chat-sessions.json"))

        SessionAreaMigration.run(paths: paths)

        let canonicalURL = paths.root.appendingPathComponent("sessions.json")
        let migrated = try decodeConversations(at: canonicalURL)
        XCTAssertEqual(migrated.map(\.id), ["duplicate", "project"])
        XCTAssertEqual(migrated.first(where: { $0.id == "duplicate" })?.messages.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("coding-sessions.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("chat-sessions.json").path))
        XCTAssertFalse(migrated.contains { $0.id == "free-chat" })

        let snapshot = try decodeConversations(at: canonicalURL)
        SessionAreaMigration.run(paths: paths)
        let rerun = try decodeConversations(at: canonicalURL)
        XCTAssertEqual(rerun.map { "\($0.id):\($0.messages.count)" }, snapshot.map { "\($0.id):\($0.messages.count)" })
    }

    func testCanonicalStoreOnlyLoadsWorkspaceConversations() throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try JSONEncoder().encode([
            Conversation(id: "project", cwd: "/tmp/project"),
            Conversation(id: "projectless"),
        ]).write(to: paths.root.appendingPathComponent("sessions.json"))

        let store = ConversationStore(paths: paths)
        XCTAssertEqual(store.loadAll().map(\.id), ["project"])
        store.save(store.loadAll())
        XCTAssertEqual(try decodeConversations(at: paths.root.appendingPathComponent("sessions.json")).map(\.id), ["project"])
    }

    func testProjectCacheNamespaceSeparatesProjectsAndContextRevisionsWithoutRawPaths() {
        let first = AgentCacheNamespace.key(
            projectID: "project-a",
            model: "model",
            planMode: false,
            contextRevision: 1
        )
        let otherProject = AgentCacheNamespace.key(
            projectID: "project-b",
            model: "model",
            planMode: false,
            contextRevision: 1
        )
        let nextRevision = AgentCacheNamespace.key(
            projectID: "project-a",
            model: "model",
            planMode: false,
            contextRevision: 2
        )
        XCTAssertNotEqual(first, otherProject)
        XCTAssertNotEqual(first, nextRevision)
        XCTAssertTrue(first.hasPrefix("herness:unified-v2:"))
        XCTAssertFalse(first.contains("/tmp/"))
    }

    func testPromptCacheRevisionUsesOnlyTheStablePolicyPrefix() {
        let stable = PromptSection(tag: "core_policy", trust: .core, text: "policy")
        let standard = AgentCacheNamespace.promptContextRevision([
            stable,
            PromptSection(tag: "runtime_context", trust: .core, text: "today")
        ])
        let changedRuntime = AgentCacheNamespace.promptContextRevision([
            stable,
            PromptSection(tag: "runtime_context", trust: .core, text: "tomorrow"),
            PromptSection(tag: "response_style", trust: .core, text: "concise")
        ])
        let changedPolicy = AgentCacheNamespace.promptContextRevision([
            PromptSection(tag: "core_policy", trust: .core, text: "changed policy")
        ])

        XCTAssertEqual(standard, changedRuntime)
        XCTAssertNotEqual(standard, changedPolicy)
    }

    @MainActor
    func testAppModelUsesOneProjectScopedAgentFlow() throws {
        let paths = temporaryPaths()
        let projectRoot = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let model = AppModel(paths: paths)
        XCTAssertTrue(model.activeSkills === model.bridge.skills)
        model.setWorkspace(projectRoot.path)
        let id = try XCTUnwrap(model.selectedConversationID)
        model.draft = "project draft"
        XCTAssertEqual(model.selectedConversationID, id)
        XCTAssertEqual(model.draft, "project draft")
        XCTAssertTrue(model.conversations.allSatisfy { $0.cwd == projectRoot.path })
    }

    private func decodeConversations(at url: URL) throws -> [Conversation] {
        try JSONDecoder().decode([Conversation].self, from: Data(contentsOf: url))
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessProjectSessionTests-\(UUID().uuidString)", isDirectory: true)
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
