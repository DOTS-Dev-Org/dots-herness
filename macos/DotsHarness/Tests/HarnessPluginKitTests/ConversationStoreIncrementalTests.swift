// Copyright (c) 2026 DOTS

import Foundation
import PluginRuntime
import XCTest
@testable import DotsHarnessCore

final class ConversationStoreIncrementalTests: XCTestCase {
    private var root: URL!
    private var paths: SupportPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationStoreIncremental-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins"),
            presets: root.appendingPathComponent("presets"),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models"),
            runtime: root.appendingPathComponent("runtime")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func conversation(_ id: String, cwd: String, messages: Int = 3, title: String = "chat") -> Conversation {
        Conversation(
            id: id,
            title: title,
            messages: (0..<messages).map { ChatMessage(kind: $0 % 2 == 0 ? .user : .assistant, text: "\(id) message \($0)") },
            blank: false,
            cwd: cwd
        )
    }

    /// Repeated saves (what a run does at every tool step) end up equal to a fresh decode.
    func testRepeatedSavesMatchAFreshRead() {
        let store = ConversationStore(paths: paths)
        var a = conversation("a", cwd: "/tmp/p1")
        let b = conversation("b", cwd: "/tmp/p2")
        store.save([a])
        store.save([b])
        for step in 0..<20 {
            a.messages.append(ChatMessage(kind: .tool, text: "step \(step)"))
            store.save([a])
        }
        let fresh = ConversationStore(paths: paths).loadAll()
        XCTAssertEqual(fresh.map(\.id), ["a", "b"])
        XCTAssertEqual(fresh.first { $0.id == "a" }?.messages.count, a.messages.count)
        XCTAssertEqual(fresh.first { $0.id == "b" }?.messages.count, 3)
        XCTAssertEqual(store.loadAll(), fresh)
    }

    /// A save must merge onto what another process (or store) wrote in between.
    func testSaveKeepsConversationsWrittenElsewhere() {
        let mine = ConversationStore(paths: paths)
        let other = ConversationStore(paths: paths)
        mine.save([conversation("a", cwd: "/tmp/p1")])
        other.save([conversation("b", cwd: "/tmp/p2")])
        var a = conversation("a", cwd: "/tmp/p1")
        a.title = "renamed"
        mine.save([a])

        let all = ConversationStore(paths: paths).loadAll()
        XCTAssertEqual(all.map(\.id), ["a", "b"])
        XCTAssertEqual(all.first { $0.id == "a" }?.title, "renamed")
        XCTAssertEqual(all.first { $0.id == "b" }?.messages.count, 3)
    }

    /// The header list that follows a save equals what decoding the file would give.
    func testHeadersFollowSavesWithoutDecoding() {
        let store = ConversationStore(paths: paths)
        store.save([conversation("a", cwd: "/tmp/p1"), conversation("b", cwd: "/tmp/p2")])
        _ = store.loadHeaders()            // prime the header cache

        var a = conversation("a", cwd: "/tmp/p1", messages: 6, title: "changed title")
        a.pinned = true
        store.save([a])

        let followed = store.loadHeaders()
        let decoded = ConversationStore(paths: paths).loadHeaders()
        XCTAssertEqual(followed.map(\.id), decoded.map(\.id))
        for (lhs, rhs) in zip(followed, decoded) {
            XCTAssertEqual(lhs.title, rhs.title)
            XCTAssertEqual(lhs.pinned, rhs.pinned)
            XCTAssertEqual(lhs.cwd, rhs.cwd)
            XCTAssertEqual(lhs.contentLoaded, rhs.contentLoaded)
            XCTAssertEqual(lhs.messages.count, rhs.messages.count)
            XCTAssertEqual(lhs.activityDate.timeIntervalSince1970, rhs.activityDate.timeIntervalSince1970, accuracy: 0.001)
        }
    }

    /// Saving a header (sidebar edit) changes metadata and keeps the stored transcript.
    func testHeaderSaveKeepsTheStoredTranscript() {
        let store = ConversationStore(paths: paths)
        store.save([conversation("a", cwd: "/tmp/p1", messages: 5)])
        var header = store.loadHeaders().first { $0.id == "a" }!
        XCTAssertFalse(header.contentLoaded)
        header.title = "from the sidebar"
        store.save([header])

        let stored = ConversationStore(paths: paths).loadAll().first { $0.id == "a" }
        XCTAssertEqual(stored?.title, "from the sidebar")
        XCTAssertEqual(stored?.messages.count, 5)
    }

    func testDeleteRemovesOnlyThatConversation() {
        let store = ConversationStore(paths: paths)
        store.save([conversation("a", cwd: "/tmp/p1"), conversation("b", cwd: "/tmp/p2")])
        store.delete("a")
        store.save([conversation("c", cwd: "/tmp/p3")])
        XCTAssertEqual(ConversationStore(paths: paths).loadAll().map(\.id), ["b", "c"])
    }

    func testImportsLegacyJSONIntoSQLiteAndKeepsTheSourceArchive() throws {
        let legacyURL = root.appendingPathComponent("sessions.json")
        let source = conversation("legacy", cwd: "/tmp/legacy", messages: 12)
        let legacyData = try JSONEncoder().encode([source])
        try legacyData.write(to: legacyURL)

        let store = ConversationStore(paths: paths)
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyData)
        XCTAssertEqual(store.loadHeaders().map(\.id), ["legacy"])
        let latest = try XCTUnwrap(store.loadRecentConversation(id: "legacy"))
        XCTAssertEqual(latest.messages.count, 10)
        XCTAssertEqual(latest.messages.first?.text, "legacy message 2")
        XCTAssertEqual(latest.messages.last?.text, "legacy message 11")
        XCTAssertEqual(latest.messageStartIndex, 2)
    }

    func testHeadersObserveWritesFromAnotherStore() {
        let store = ConversationStore(paths: paths)
        store.save([conversation("a", cwd: "/tmp/p1")])
        XCTAssertEqual(store.loadHeaders().map(\.id), ["a"])

        let other = ConversationStore(paths: paths)
        other.save([conversation("z", cwd: "/tmp/p9", messages: 7)])
        XCTAssertEqual(Set(store.loadHeaders().map(\.id)), ["a", "z"])
        store.save([conversation("a", cwd: "/tmp/p1")])
        XCTAssertEqual(Set(ConversationStore(paths: paths).loadAll().map(\.id)), ["a", "z"])
    }

    /// An unreadable legacy archive is preserved and the new SQLite store stays writable.
    func testUnreadableLegacyArchiveIsPreservedAndSQLiteRemainsWritable() throws {
        let file = root.appendingPathComponent("sessions.json")
        try Data("{ not json".utf8).write(to: file)
        let store = ConversationStore(paths: paths)
        XCTAssertTrue(store.loadAll().isEmpty)
        XCTAssertTrue(store.save([conversation("a", cwd: "/tmp/p1")]))
        XCTAssertEqual(store.loadAll().map(\.id), ["a"])
        let kept = try String(contentsOf: file.appendingPathExtension("corrupt"))
        XCTAssertEqual(kept, "{ not json")
        XCTAssertEqual(try String(contentsOf: file), "{ not json")
    }

    /// Page totals come from the stored rows, and the changed-files query is bounded
    /// to the requested chats.
    func testMessagePageTotalAndRecentChangedFilesForWantedChatsOnly() {
        let store = ConversationStore(paths: paths)
        var a = conversation("a", cwd: "/tmp/p1", messages: 25)
        a.messages[24].changedFiles = [ChangedFile(path: "a.swift", operation: .modified)]
        var b = conversation("b", cwd: "/tmp/p1", messages: 2)
        b.messages[1].changedFiles = [ChangedFile(path: "b.swift", operation: .added)]
        XCTAssertTrue(store.save([a, b]))
        a.messages.append(ChatMessage(kind: .tool, text: "step"))
        XCTAssertTrue(store.save([a]))

        let page = store.loadMessagePage(id: "a", endingBefore: 26, limit: 10)
        XCTAssertEqual(page?.totalCount, 26)
        XCTAssertEqual(page?.startIndex, 15) // trailing tool step does not use up the limit

        var seen: [String: [String]] = [:]
        store.forEachRecentChangedFiles(ids: ["b"], since: .distantPast) { id, _, files in seen[id] = files.map(\.path) }
        XCTAssertEqual(seen, ["b": ["b.swift"]])
    }

    /// Tool steps and notices must not push the latest user/assistant turn off the page.
    func testRecentPageLimitCountsConversationalMessagesOnly() throws {
        let store = ConversationStore(paths: paths)
        var chat = conversation("tools", cwd: "/tmp/tools", messages: 2)
        chat.messages += (0..<15).map { ChatMessage(kind: .tool, text: "step \($0)") }
        chat.messages += (0..<3).map { _ in ChatMessage(kind: .system, text: "timeout") }
        XCTAssertTrue(store.save([chat]))

        let loaded = try XCTUnwrap(store.loadRecentConversation(id: chat.id))
        XCTAssertEqual(loaded.messages.map(\.id), chat.messages.map(\.id))
        XCTAssertFalse(loaded.hasOlderTranscriptMessages)
    }

    func testRecentAndOlderPagesRecoverTheWholeTranscriptInOrder() throws {
        let store = ConversationStore(paths: paths)
        let original = conversation("paged", cwd: "/tmp/paged", messages: 27)
        XCTAssertTrue(store.save([original]))

        var loaded = try XCTUnwrap(store.loadRecentConversation(id: original.id))
        XCTAssertEqual(loaded.messages.count, 10)
        XCTAssertTrue(loaded.hasOlderTranscriptMessages)

        while loaded.hasOlderTranscriptMessages {
            let older = try XCTUnwrap(store.loadMessagePage(
                id: original.id,
                endingBefore: loaded.messageStartIndex,
                limit: 10
            ))
            XCTAssertFalse(older.messages.isEmpty, "an older page should exist while the start index is nonzero")
            loaded.messages.insert(contentsOf: older.messages, at: 0)
            loaded.messageStartIndex = older.startIndex
            loaded.transcriptComplete = older.startIndex == 0
        }

        XCTAssertEqual(loaded.messages.map(\.id), original.messages.map(\.id))
        XCTAssertEqual(loaded.messages.map(\.text), original.messages.map(\.text))
    }
}
