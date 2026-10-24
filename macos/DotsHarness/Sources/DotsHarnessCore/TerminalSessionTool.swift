// Copyright (c) 2026 DOTS
// Agent-facing tool for long-lived processes (dev servers, backends, watchers)
// that outlive one bounded run_command call. Backed by TerminalSession;
// sessions are scoped to the conversation that opened them.

import Foundation
import HarnessPluginKit

public enum TerminalSessionTool {
    public static let name = "terminal_session"

    public static let definition = AgentToolDefinition(
        name: name,
        description: """
        Manage a long-lived interactive shell for processes that need to remain available \
        beyond one run_command call (a dev server, a backend, a file watcher). Start one, \
        read its output, send input, and stop it when done. Before starting work aimed at a \
        subproject, call list_files for that directory to load its scoped project rules. Prefer run_command for \
        one-off checks (default 120 seconds, maximum 600). Pass command to start to run it as a background task (a long \
        build, a download, a full test suite): the session exits with the command, \
        and you receive a message with its exit code when it does, so do not poll \
        with read - carry on with other work or end your turn and say what is still \
        running. Leave any other process running only if the user asked; otherwise \
        stop it before finishing and report anything left running. When the user refers \
        to their terminal, its output or text they selected there, call list, then read \
        that dock terminal. list also shows the terminals the user opened in the dock; read returns their output and any \
        text the user selected there, but they cannot be sent input or stopped.
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
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Shell command to run as a background task (start action)."),
                ]),
                "description": .object([
                    "type": .string("string"),
                    "description": .string("Short label for the background task, shown to the user (start action)."),
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
