// Copyright (c) 2026 DOTS

import XCTest
import Foundation
import PluginRuntime
import HarnessPluginKit
@testable import DotsHarnessCore

/// Several chats running at once each append messages; every append used to
/// re-encode and rewrite the provider context of every loaded chat.
final class PersistCostTests: XCTestCase {
    @MainActor
    func testAppendInOneChatPersistsOnlyWhatChanged() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsPersistCost-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let host = NativeAgentHost(paths: paths, endpoint: AgentEndpointController())

        // Four running chats, ~1 MB of provider context each (real chats reach 2 MB).
        let chunk = String(repeating: "x", count: 2_000)
        host.conversations = (0..<4).map { index in
            Conversation(
                title: "chat \(index)",
                messages: (0..<50).map { ChatMessage(kind: .assistant, text: "m\($0) " + chunk) },
                modelContext: (0..<500).map { AgentMessage(role: .user, content: "c\($0) " + chunk) },
                running: true,
                blank: false,
                projectless: true
            )
        }
        XCTAssertTrue(host.persist())

        let start = Date()
        for step in 0..<40 {
            // A tool step grows the provider context as well as the transcript.
            host.conversations[step % 4].modelContext.append(AgentMessage(role: .tool, content: "result \(step)"))
            host.append(ChatMessage(kind: .tool, text: "tool \(step)"), to: host.conversations[step % 4].id)
        }
        let elapsed = Date().timeIntervalSince(start)
        print("PersistCost: 40 appends across 4 chats took \(String(format: "%.3f", elapsed))s")

        for conversation in host.conversations {
            let stored = try XCTUnwrap(host.store.load(id: conversation.id))
            XCTAssertEqual(stored.messages.count, 60)
            XCTAssertEqual(stored.modelContext, conversation.modelContext)
            XCTAssertEqual(stored.messages.map(\.id), conversation.messages.map(\.id))
        }

        // Compaction replaces the context: rows must not keep the old tail.
        host.conversations[0].modelContext = [AgentMessage(role: .user, content: "summary")]
        XCTAssertTrue(host.persist())
        XCTAssertEqual(host.store.load(id: host.conversations[0].id)?.modelContext.map(\.content), ["summary"])
    }
}
