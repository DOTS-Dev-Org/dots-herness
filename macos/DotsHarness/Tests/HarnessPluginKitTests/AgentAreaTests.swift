import Foundation
import XCTest
import PluginRuntime
@testable import DotsHarnessCore

final class AgentAreaTests: XCTestCase {
    func testLedgerRetainsMultipleRootsAndStructuredMemory() {
        var ledger = ChatContextLedger()
        let first = ChatContextRoot(path: "/tmp/project-a", kind: .directory)
        let second = ChatContextRoot(path: "/tmp/project-b", kind: .directory)

        XCTAssertEqual(ledger.attach(roots: [first], to: "message-a").count, 1)
        XCTAssertEqual(ledger.attach(roots: [second], to: "message-b").count, 1)
        ledger.addProjectNote("Keep the two roots independent")
        ledger.addChangeSummary("Updated project-a")

        XCTAssertEqual(ledger.roots.map(\.path), [first.path, second.path])
        XCTAssertEqual(ledger.roots[0].sourceMessageIDs, ["message-a"])
        XCTAssertEqual(ledger.projectNotes, ["Keep the two roots independent"])
        XCTAssertEqual(ledger.changeSummaries, ["Updated project-a"])
        XCTAssertGreaterThanOrEqual(ledger.revision, 4)
    }

    func testPathParserSupportsQuotedCrossPlatformCandidatesAndKnownRelativeRoots() throws {
        let paths = temporaryPaths()
        let root = paths.root.appendingPathComponent("relative-root", isDirectory: true)
        let source = root.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("print(\"ok\")".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let text = "Inspect \"\(root.path)\", `\(source.path)` and C:\\repo\\App.swift from \\\\server\\share\\repo."
        let candidates = ChatPathParser.extractPaths(from: text)
        XCTAssertTrue(candidates.contains(root.path))
        XCTAssertTrue(candidates.contains(source.path))
        XCTAssertTrue(candidates.contains("C:\\repo\\App.swift"))
        XCTAssertTrue(candidates.contains("\\\\server\\share\\repo"))

        let relative = ChatPathParser.roots(
            from: "Please inspect Sources/App.swift",
            knownRoots: [ChatContextRoot(path: root.path, kind: .directory)],
            sourceMessageID: "relative-message"
        )
        XCTAssertEqual(relative.map(\.path), [source.resolvingSymlinksInPath().path])
        XCTAssertEqual(relative.first?.sourceMessageIDs, ["relative-message"])
    }

    func testLegacySessionsSplitByWorkspaceWithoutDeletingLegacyFile() throws {
        let paths = temporaryPaths()
        let codingRoot = paths.root.appendingPathComponent("coding-root", isDirectory: true)
        try FileManager.default.createDirectory(at: codingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codingRoot) }

        let legacy: [[String: Any]] = [
            ["id": "coding-session", "title": "Code", "messages": [], "cwd": codingRoot.path],
            ["id": "chat-session", "title": "Chat", "messages": []],
        ]
        let legacyURL = paths.root.appendingPathComponent("sessions.json")
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyURL)

        SessionAreaMigration.run(paths: paths)

        let coding = try decodeConversations(at: paths.root.appendingPathComponent(AgentArea.coding.sessionFileName))
        let chat = try decodeConversations(at: paths.root.appendingPathComponent(AgentArea.chat.sessionFileName))
        XCTAssertEqual(coding.map(\.id), ["coding-session"])
        XCTAssertEqual(coding.first?.area, .coding)
        XCTAssertEqual(coding.first?.cwd, codingRoot.path)
        XCTAssertEqual(chat.map(\.id), ["chat-session"])
        XCTAssertEqual(chat.first?.area, .chat)
        XCTAssertNil(chat.first?.cwd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testExistingAreaFilesRepairOwnershipUsingCwdAndDoNotLeakIntoCoding() throws {
        let paths = temporaryPaths()
        let codingURL = paths.root.appendingPathComponent(AgentArea.coding.sessionFileName)
        let chatURL = paths.root.appendingPathComponent(AgentArea.chat.sessionFileName)
        let coding = Conversation(
            id: "coding-session",
            title: "Coding",
            blank: false,
            cwd: "/tmp/coding-project",
            area: .coding
        )
        let chatWrittenAsCoding = Conversation(
            id: "chat-session",
            title: "Chat accidentally in coding store",
            messages: [ChatMessage(kind: .user, text: "chat content")],
            blank: false,
            area: .coding
        )
        let codingWrittenAsChat = Conversation(
            id: "coding-in-chat",
            title: "Coding accidentally in chat store",
            blank: false,
            cwd: "/tmp/another-project",
            area: .chat
        )
        try JSONEncoder().encode([coding, chatWrittenAsCoding]).write(to: codingURL)
        try JSONEncoder().encode([codingWrittenAsChat]).write(to: chatURL)
        try Data("{}".utf8).write(to: paths.root.appendingPathComponent("area-session-migration-v1.json"))

        SessionAreaMigration.run(paths: paths)

        let repairedCoding = try decodeConversations(at: codingURL)
        let repairedChat = try decodeConversations(at: chatURL)
        XCTAssertEqual(Set(repairedCoding.map(\.id)), ["coding-session", "coding-in-chat"])
        XCTAssertEqual(Set(repairedChat.map(\.id)), ["chat-session"])
        XCTAssertTrue(repairedCoding.contains { $0.id == "coding-in-chat" && $0.area == .coding })
        XCTAssertTrue(repairedChat.allSatisfy { $0.area == .chat && $0.cwd == nil })
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("area-session-migration-v2.json").path))
    }

    func testAreaStoreDoesNotPreserveForeignRecordsWhenSaving() throws {
        let paths = temporaryPaths()
        let codingURL = paths.root.appendingPathComponent(AgentArea.coding.sessionFileName)
        let codingConversation = Conversation(
            id: "coding-session",
            title: "Coding",
            blank: false,
            cwd: "/tmp/coding-project",
            area: .coding
        )
        let chatConversation = Conversation(
            id: "chat-session",
            title: "Chat accidentally in coding store",
            messages: [ChatMessage(kind: .user, text: "chat content")],
            blank: false,
            area: .coding
        )
        try JSONEncoder().encode([codingConversation, chatConversation]).write(to: codingURL)

        let store = ConversationStore(paths: paths, fileName: AgentArea.coding.sessionFileName, area: .coding)
        let visible = store.loadAll()
        XCTAssertEqual(visible.map(\.id), ["coding-session"])
        store.save(visible)

        let repaired = try decodeConversations(at: codingURL)
        XCTAssertEqual(repaired.map(\.id), ["coding-session"])
    }

    func testCacheNamespaceSeparatesAreasAndContextRevisionsWithoutRawPaths() {
        let chat = AgentCacheNamespace.key(
            area: .chat,
            conversationID: "conversation",
            chatProjectID: "chat-project",
            codingProjectID: nil,
            model: "model",
            planMode: false,
            contextRevision: 1,
            rootIDs: ["context-a"]
        )
        let coding = AgentCacheNamespace.key(
            area: .coding,
            conversationID: "conversation",
            chatProjectID: nil,
            codingProjectID: "coding-project",
            model: "model",
            planMode: false,
            contextRevision: 1
        )
        let nextRevision = AgentCacheNamespace.key(
            area: .chat,
            conversationID: "conversation",
            chatProjectID: "chat-project",
            codingProjectID: nil,
            model: "model",
            planMode: false,
            contextRevision: 2,
            rootIDs: ["context-a"]
        )

        XCTAssertNotEqual(chat, coding)
        XCTAssertNotEqual(chat, nextRevision)
        XCTAssertFalse(chat.contains("/tmp/"))
    }

    @MainActor
    func testAppModelKeepsChatAndCodingConversationsAndDraftsSeparate() throws {
        let paths = temporaryPaths()
        let codingRoot = paths.root.appendingPathComponent("coding-root", isDirectory: true)
        try FileManager.default.createDirectory(at: codingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codingRoot) }

        let model = AppModel(paths: paths)
        XCTAssertEqual(model.activeArea, .chat)
        XCTAssertTrue(model.chatRouter.store === model.codingRouter.store)
        XCTAssertFalse(model.chatBridge.skills === model.codingBridge.skills)
        XCTAssertNotNil(model.chatBridge.skillSuggestions)
        XCTAssertNotNil(model.codingBridge.skillSuggestions)
        XCTAssertTrue(model.activeSkills === model.chatBridge.skills)

        model.setWorkspace(codingRoot.path)
        XCTAssertEqual(model.activeArea, .coding)
        XCTAssertTrue(model.activeSkills === model.codingBridge.skills)
        let codingID = try XCTUnwrap(model.selectedConversationID)
        model.draft = "coding draft"

        model.setActiveArea(.chat)
        XCTAssertEqual(model.activeArea, .chat)
        model.draft = "chat draft"
        model.newChatConversation()
        let chatID = try XCTUnwrap(model.selectedConversationID)

        XCTAssertNotEqual(chatID, codingID)
        XCTAssertTrue(model.codingBridge.conversations.contains { $0.id == codingID })
        XCTAssertTrue(model.chatBridge.conversations.contains { $0.id == chatID })
        XCTAssertTrue(model.chatBridge.conversations.allSatisfy { $0.area == .chat && $0.cwd == nil })

        model.setActiveArea(.coding)
        XCTAssertEqual(model.draft, "coding draft")
        XCTAssertEqual(model.selectedConversationID, codingID)
        model.setActiveArea(.chat)
        XCTAssertEqual(model.draft, "chat draft")
        XCTAssertEqual(model.selectedConversationID, chatID)
    }

    @MainActor
    func testAppModelRestoresLastActiveAreaAfterRecreation() throws {
        let paths = temporaryPaths()

        let firstLaunch = AppModel(paths: paths)
        firstLaunch.setActiveArea(.coding)
        XCTAssertEqual(firstLaunch.activeArea, .coding)

        let codingLaunch = AppModel(paths: paths)
        XCTAssertEqual(codingLaunch.activeArea, .coding)

        codingLaunch.setActiveArea(.chat)
        XCTAssertEqual(codingLaunch.activeArea, .chat)

        let chatLaunch = AppModel(paths: paths)
        XCTAssertEqual(chatLaunch.activeArea, .chat)
    }

    private func decodeConversations(at url: URL) throws -> [Conversation] {
        try JSONDecoder().decode([Conversation].self, from: Data(contentsOf: url))
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessAgentAreaTests-\(UUID().uuidString)", isDirectory: true)
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
