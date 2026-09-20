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

    /// The cache never outlives a change to the file: deleted or rewritten behind the store's back.
    func testCacheFollowsTheFileWhenItIsDeletedOrReplaced() throws {
        let store = ConversationStore(paths: paths)
        store.save([conversation("a", cwd: "/tmp/p1")])
        XCTAssertEqual(store.loadHeaders().map(\.id), ["a"])
        let file = root.appendingPathComponent("sessions.json")

        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(store.loadHeaders().isEmpty)

        let other = ConversationStore(paths: paths)
        other.save([conversation("z", cwd: "/tmp/p9", messages: 7)])
        XCTAssertEqual(store.loadHeaders().map(\.id), ["z"])
        store.save([conversation("a", cwd: "/tmp/p1")])
        XCTAssertEqual(Set(ConversationStore(paths: paths).loadAll().map(\.id)), ["a", "z"])
    }

    /// An unreadable file is set aside before the next save rewrites it.
    func testUnreadableFileIsKeptBeforeBeingRewritten() throws {
        let file = root.appendingPathComponent("sessions.json")
        try Data("{ not json".utf8).write(to: file)
        let store = ConversationStore(paths: paths)
        XCTAssertTrue(store.loadAll().isEmpty)
        store.save([conversation("a", cwd: "/tmp/p1")])
        XCTAssertEqual(store.loadAll().map(\.id), ["a"])
        let kept = try String(contentsOf: file.appendingPathExtension("corrupt"))
        XCTAssertEqual(kept, "{ not json")
    }
}
