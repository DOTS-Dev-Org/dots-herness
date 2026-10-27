// Copyright (c) 2026 DOTS
// Runs Claude models through the user's installed, official `claude` CLI.

import Foundation
import HarnessPluginKit
import os

/// The CLI is a complete agent: it runs its own tools in the workspace and
/// signs in with its own credentials. HerNess hands it the prompt and shows
/// the stream; HerNess tools are not offered to it.
enum ClaudeCLIClient {
    /// The CLI's own session per conversation, and how many turns it has seen.
    // ponytail: process memory, so after a restart the first turn sends the transcript once
    // and the CLI session starts over from it; persist this map if that costs too much.
    private struct Session: Sendable { var id: String; var turns: Int }
    private static let sessions = OSAllocatedUnfairLock(initialState: [String: Session]())

    static func complete(
        messages: [AgentMessage],
        configuration: AgentConfiguration,
        workspace: URL?,
        onDelta: NativeAgentClient.StreamDeltaHandler?
    ) async throws -> AgentResponse {
        let conversationID = AgentRunScope.conversationID
        let turns = turns(from: messages)
        var session = conversationID.flatMap { id in sessions.withLock { $0[id] } }
        // An edited or rewound conversation no longer matches what the CLI saw.
        if let known = session, known.turns >= turns.count { session = nil }
        do {
            return try await run(turns: turns, session: session, conversationID: conversationID,
                                 configuration: configuration, workspace: workspace, onDelta: onDelta)
        } catch let error as NativeAgentError where session != nil && error.message.localizedCaseInsensitiveContains("No conversation found") {
            // The CLI no longer has that session: start a new one from the transcript.
            // Other failures may follow real work, so they surface.
            if let conversationID { sessions.withLock { _ = $0.removeValue(forKey: conversationID) } }
            return try await run(turns: turns, session: nil, conversationID: conversationID,
                                 configuration: configuration, workspace: workspace, onDelta: onDelta)
        }
    }

    private static func run(
        turns: [AgentMessage],
        session: Session?,
        conversationID: String?,
        configuration: AgentConfiguration,
        workspace: URL?,
        onDelta: NativeAgentClient.StreamDeltaHandler?
    ) async throws -> AgentResponse {
        guard let executable = executableURL() else {
            throw NativeAgentError(AppCopy.text("claudeCLI.notInstalled"))
        }
        var arguments = [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--permission-mode", "acceptEdits",
            "--model", configuration.model,
        ]
        if !configuration.effort.isEmpty { arguments += ["--effort", configuration.effort] }
        if let session { arguments += ["--resume", session.id] }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let workspace { process.currentDirectoryURL = workspace }
        // A GUI app starts with launchd's short PATH; the CLI's own Bash tool needs the user's.
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(prompt(turns: turns, seen: session?.turns ?? 0).utf8))
        try? input.fileHandleForWriting.close()

        var texts: [String] = []
        var finalText: String?
        var failure: String?
        var usage: AgentUsage?
        var sessionID: String?
        try await withTaskCancellationHandler {
            for try await line in output.fileHandleForReading.bytes.lines {
                guard let event = try? JSONCodec.parse(Data(line.utf8)) else { continue }
                if let id = event["session_id"]?.string, !id.isEmpty { sessionID = id }
                switch event["type"]?.string {
                case "stream_event":
                    let delta = event["event"]?["delta"]
                    if delta?["type"]?.string == "text_delta", let text = delta?["text"]?.string {
                        await onDelta?(.text(text))
                    } else if delta?["type"]?.string == "thinking_delta", let text = delta?["thinking"]?.string {
                        await onDelta?(.thinking(text))
                    }
                case "assistant":
                    for block in event["message"]?["content"]?.array ?? [] {
                        if block["type"]?.string == "text", let text = block["text"]?.string {
                            texts.append(text)
                            // Separates this turn's prose from the next one in the live view.
                            await onDelta?(.text("\n\n"))
                        } else if block["type"]?.string == "tool_use", let name = block["name"]?.string {
                            await onDelta?(.thinking("› \(name)\n"))
                        }
                    }
                case "result":
                    if event["is_error"]?.bool == true {
                        failure = event["result"]?.string ?? event["subtype"]?.string ?? "error"
                    } else {
                        finalText = event["result"]?.string
                    }
                    if let u = event["usage"] {
                        usage = AgentUsage(
                            inputTokens: u["input_tokens"]?.int ?? 0,
                            outputTokens: u["output_tokens"]?.int ?? 0,
                            cachedTokens: u["cache_read_input_tokens"]?.int,
                            cacheWriteTokens: u["cache_creation_input_tokens"]?.int
                        )
                    }
                default:
                    break
                }
            }
        } onCancel: {
            process.terminate()
        }
        process.waitUntilExit()
        if let failure { throw NativeAgentError(failure) }
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile().prefix(4_000), encoding: .utf8) ?? ""
            throw NativeAgentError(stderr.isEmpty ? "claude exited with \(process.terminationStatus)" : stderr)
        }
        let content = texts.isEmpty ? finalText ?? "" : texts.joined(separator: "\n\n")
        // The CLI now holds every turn so far plus this reply.
        if let conversationID, let sessionID {
            sessions.withLock { $0[conversationID] = Session(id: sessionID, turns: turns.count + 1) }
        }
        return AgentResponse(message: AgentMessage(role: .assistant, content: content), usage: usage)
    }

    /// Prefers the user's own install; `claude update` keeps whichever one this finds current.
    static func executableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// The CLI keeps its own system prompt and tools, so HerNess's system
    /// prompt and other providers' tool traffic stay out.
    static func turns(from messages: [AgentMessage]) -> [AgentMessage] {
        messages.filter { ($0.role == .user || $0.role == .assistant) && !$0.content.isEmpty }
    }

    /// A resumed session already holds the first `seen` turns, so only what came
    /// after travels (turns another provider answered in between, then the new
    /// request). A new session gets the whole transcript once.
    static func prompt(turns: [AgentMessage], seen: Int) -> String {
        guard let last = turns.last else { return "" }
        let history = turns.dropLast().dropFirst(seen).map { ($0.role == .user ? "User: " : "Assistant: ") + $0.content }
        guard !history.isEmpty else { return last.content }
        let heading = seen == 0 ? "Earlier in this conversation:" : "Since your last reply in this conversation:"
        return heading + "\n\n" + history.joined(separator: "\n\n") + "\n\n---\n\n" + last.content
    }
}
