// Copyright (c) 2026 DOTS

import XCTest
import PluginRuntime
@testable import DotsHarnessCore

final class BotMessagesTests: XCTestCase {
    @MainActor
    func testReplySplitsAtSeparatorLinesOutsideCodeFences() {
        let reply = "Tamam, bakıyorum.\n---\n```yaml\n---\nkey: 1\n```\n ---\nBitti."
        let parts = BotStore.splitMessages(reply).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        XCTAssertEqual(parts, ["Tamam, bakıyorum.", "```yaml\n---\nkey: 1\n```", "Bitti."])
        XCTAssertEqual(BotStore.splitMessages("tek mesaj").count, 1)
    }

    @MainActor
    func testConsecutiveMessagesFromOneSideBecomeOneTurn() {
        let turns = BotStore.turns([
            BotMessage(role: .user, text: "a"),
            BotMessage(role: .assistant, text: "b"),
            BotMessage(role: .assistant, text: "c"),
            BotMessage(role: .user, text: "d"),
        ])
        XCTAssertEqual(turns.map(\.text), ["a", "b\n---\nc", "d"])
    }

    func testDeliveryStateIsSavedAndOlderChatsCountAsDelivered() throws {
        let waiting = BotMessage(role: .user, text: "a", delivered: false)
        let saved = try JSONEncoder().encode(waiting)
        XCTAssertFalse(try JSONDecoder().decode(BotMessage.self, from: saved).delivered)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        legacy["delivered"] = nil
        let old = try JSONDecoder().decode(BotMessage.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(old.delivered)
    }

    @MainActor
    func testBotArchiveRoundTripsAllBotsAndChatHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dots-bot-archive-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins"),
            presets: root.appendingPathComponent("presets"),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models"),
            runtime: root.appendingPathComponent("runtime")
        )
        let router = RouterController(paths: paths)
        let sourceRoot = root.appendingPathComponent("source-bots", isDirectory: true)
        let source = BotStore(root: sourceRoot, router: router, paths: paths, systemPrompt: { "" })
        source.loadIfNeeded()
        let original = Bot(
            id: "source-researcher",
            name: "Researcher",
            effort: "high",
            workspacePath: "/tmp/research-workspace",
            messages: [
                BotMessage(id: "source-message", role: .user, text: "Find facts", delivered: false),
                BotMessage(role: .assistant, text: "Verified answer"),
            ]
        )
        source.upsert(original)
        source.upsert(Bot(id: "source-coder", name: "Coder"))

        let archive = try source.exportArchive()
        let destinationRoot = root.appendingPathComponent("imported-bots", isDirectory: true)
        let destination = BotStore(root: destinationRoot, router: router, paths: paths, systemPrompt: { "" })
        let importedIDs = try destination.importArchive(archive)
        XCTAssertEqual(importedIDs.count, 2)
        XCTAssertEqual(destination.bots.count, 2)

        let imported = try XCTUnwrap(destination.bots.first { $0.name == "Researcher" })
        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertEqual(imported.effort, "high")
        XCTAssertEqual(imported.workspacePath, original.workspacePath)
        XCTAssertEqual(imported.messages.map(\.text), ["Find facts", "Verified answer"])
        XCTAssertNotEqual(imported.messages.first?.id, original.messages.first?.id)
        XCTAssertFalse(imported.messages[0].delivered)

        let secondImportIDs = try destination.importArchive(archive)
        XCTAssertEqual(destination.bots.count, 4)
        XCTAssertTrue(Set(importedIDs).isDisjoint(with: secondImportIDs))
        XCTAssertThrowsError(try destination.importArchive(Data("not json".utf8)))
        XCTAssertEqual(destination.bots.count, 4)
    }

    func testEffortIsSavedAndOlderBotsFollowTheApp() throws {
        let saved = try JSONEncoder().encode(Bot(name: "a", effort: "high"))
        XCTAssertEqual(try JSONDecoder().decode(Bot.self, from: saved).effort, "high")

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        legacy["effort"] = nil
        let old = try JSONDecoder().decode(Bot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.effort, "")
    }

    func testEveryLanguageNamesTheDeliveryTicks() {
        defer { AppCopy.setLanguage(.en) }
        AppCopy.setLanguage(.en)
        let english = ["bots.status.delivered", "bots.status.waiting"].map(AppCopy.text)
        for language in AppLanguage.supported where language != .en {
            AppCopy.setLanguage(language)
            for (key, englishText) in zip(["bots.status.delivered", "bots.status.waiting"], english) {
                XCTAssertNotEqual(AppCopy.text(key), key, language.rawValue)
                XCTAssertNotEqual(AppCopy.text(key), englishText, language.rawValue)
            }
        }
    }
}
