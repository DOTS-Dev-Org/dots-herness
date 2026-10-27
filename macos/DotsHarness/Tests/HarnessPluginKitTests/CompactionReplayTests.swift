// Copyright (c) 2026 DOTS

import Foundation
import PluginRuntime
import XCTest
@testable import DotsHarnessCore

/// Opt-in measurement. Replays saved conversations through the real compaction
/// decision, one check per assistant turn, and writes one JSON line per check:
/// the threshold numbers and whether a prune rewrote history. No provider is
/// called and no prompt text is written.
///
///     DOTS_COMPACTION_REPLAY_SESSIONS=<sessions.json> \
///     DOTS_COMPACTION_REPLAY_PROVIDERS=<dir holding provider-state.json and provider-models.json> \
///     DOTS_COMPACTION_REPLAY_MODEL=gpt-6-luna \
///     DOTS_COMPACTION_REPLAY_OUT=<output.jsonl> swift test --filter CompactionReplayTests
@MainActor
final class CompactionReplayTests: XCTestCase {
    private struct Check: Encodable {
        let conversation: Int
        let step: Int
        let messages: Int
        let strategy: String
        let changed: Bool
        /// Tokens kept before the first message a prune rewrote; nil when nothing changed.
        let keptPrefixTokens: Int?
        let trace: AgentCompactionTrace
    }

    func testReplaySavedConversations() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let sessionsPath = env["DOTS_COMPACTION_REPLAY_SESSIONS"],
              let providerDir = env["DOTS_COMPACTION_REPLAY_PROVIDERS"],
              let outputPath = env["DOTS_COMPACTION_REPLAY_OUT"] else {
            throw XCTSkip("Set DOTS_COMPACTION_REPLAY_SESSIONS, _PROVIDERS and _OUT to replay saved conversations.")
        }
        let modelID = env["DOTS_COMPACTION_REPLAY_MODEL"] ?? "gpt-6-luna"

        let source = URL(fileURLWithPath: providerDir, isDirectory: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsCompactionReplay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["provider-state.json", "provider-models.json"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: root.appendingPathComponent(name))
        }
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
        let router = RouterController(baseURL: "http://127.0.0.1:1", paths: paths)
        // The served route of the first active account that carries the model.
        let account = try XCTUnwrap(router.store.state.accounts.first {
            $0.active && $0.api == RouterAPIKind.chatGPT.rawValue
        })
        let config = try router.configuration(for: account, model: modelID, loadCredentials: false)
        print("replay route: window=\(config.contextWindow) provider=\(config.provider) policy=\(config.compactionPolicy.id.rawValue)")
        try XCTSkipUnless(config.supportsNativeCompaction,
                          "Replay covers the local-prune route; this route would ask a summarizer.")

        let host = NativeAgentHost(paths: paths, endpoint: AgentEndpointController(baseURL: "http://replay.test", modelID: modelID))
        host.start(workspacePath: FileManager.default.temporaryDirectory.path)
        let tools = host.agentTools(workspace: FileManager.default.temporaryDirectory).defs
        let client = NativeAgentClient(configuration: config)

        let sessions = try JSONDecoder().decode(
            [Conversation].self, from: Data(contentsOf: URL(fileURLWithPath: sessionsPath))
        )
        var lines: [Data] = []
        let encoder = JSONEncoder()
        for (number, saved) in sessions.enumerated() where !saved.modelContext.isEmpty {
            host.newConversation()
            let id = try XCTUnwrap(host.selectedID)
            let index = try XCTUnwrap(host.conversations.firstIndex { $0.id == id })
            let identity = host.contextRouteIdentity(configuration: config, modelOverride: nil, router: router, conversationID: id)
            host.conversations[index].contextRouteIdentity = identity

            var working: [AgentMessage] = []
            var step = 0
            for message in saved.modelContext {
                if message.role == .assistant {
                    let outcome = try await host.compactIfNeeded(
                        messages: working,
                        conversationID: id,
                        configuration: config,
                        tools: tools,
                        modelOverride: nil,
                        client: client,
                        nativeCompactionDisabled: false,
                        contextConfiguration: config,
                        routeIdentityOverride: identity,
                        router: router
                    )
                    let after = outcome.messages
                    let changed = after != working
                    var kept: Int?
                    if changed {
                        let shared = zip(working, after).prefix { $0 == $1 }.count
                        kept = AgentContextCompaction.estimateTokens(Array(working.prefix(shared)))
                    }
                    if let trace = outcome.trace {
                        lines.append(try encoder.encode(Check(
                            conversation: number, step: step, messages: working.count,
                            strategy: outcome.strategy.rawValue, changed: changed,
                            keptPrefixTokens: kept, trace: trace
                        )))
                    }
                    working = after
                    host.conversations[index].lastContextInputTokens = AgentContextCompaction.estimateTokens(working)
                    step += 1
                }
                working.append(message)
            }
        }
        var output = Data()
        for line in lines {
            output.append(line)
            output.append(0x0A)
        }
        try output.write(to: URL(fileURLWithPath: outputPath))
        try? FileManager.default.removeItem(at: root)

        let prunes = lines.filter { String(decoding: $0, as: UTF8.self).contains("\"changed\":true") }.count
        print("replay checks: \(lines.count), rewriting prunes: \(prunes), output: \(outputPath)")
    }
}
