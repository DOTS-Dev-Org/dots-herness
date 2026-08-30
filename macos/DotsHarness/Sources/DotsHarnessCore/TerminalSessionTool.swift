// Copyright (c) 2026 DOTS
// Agent-facing tool for long-lived processes (dev servers, backends, watchers)
// that outlive run_command's 45s one-shot budget. Backed by TerminalSession;
// sessions are scoped to the conversation that opened them.

import Foundation
import HarnessPluginKit

public enum TerminalSessionTool {
    public static let name = "terminal_session"

    public static let definition = AgentToolDefinition(
        name: name,
        description: """
        Manage a long-lived interactive shell for processes that outlast a short \
        run_command (a dev server, a backend, a file watcher). Start one, read \
        its output, send input, and stop it when done. Prefer run_command for \
        one-off checks. Leave a process running only if the user asked; otherwise \
        stop it before finishing and report anything left running.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string("list"), .string("start"), .string("read"),
                        .string("send"), .string("stop"),
                    ]),
                    "description": .string("Operation to perform."),
                ]),
                "session_id": .object([
                    "type": .string("string"),
                    "description": .string("Target session, required for read/send/stop."),
                ]),
                "input": .object([
                    "type": .string("string"),
                    "description": .string("Text to send (send action). A newline is appended if missing."),
                ]),
                "max_chars": .object([
                    "type": .string("integer"),
                    "description": .string("Trailing output to return for read (default 4000)."),
                ]),
            ]),
            "required": .array([.string("action")]),
        ])
    )

    public static func actionRequiresApproval(_ action: String) -> Bool {
        action == "start" || action == "send"
    }
}
