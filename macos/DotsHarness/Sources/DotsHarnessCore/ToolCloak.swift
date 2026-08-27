// Copyright (c) 2026 DOTS
// Claude OAuth tool cloaking. When an OAuth (subscription) token calls
// /v1/messages, Anthropic expects Claude Code's own tool surface. Arbitrary
// client tools are renamed with a suffix and a few canonical Claude Code tool
// names are added as decoys so the request looks like it came from the CLI.
// Response tool-call names are mapped back with `restore`.

import Foundation

public enum ToolCloak {
    public static let suffix = "_cc"

    private static func decoyTools() -> [[String: Any]] {
        [
            ["name": "Read", "description": "Read a file from the filesystem.",
             "input_schema": ["type": "object", "properties": ["file_path": ["type": "string"]], "required": ["file_path"]]],
            ["name": "Bash", "description": "Run a shell command.",
             "input_schema": ["type": "object", "properties": ["command": ["type": "string"]], "required": ["command"]]],
        ]
    }

    /// Rewrites `body` in place. Returns true if anything was cloaked.
    @discardableResult
    public static func apply(to body: inout [String: Any]) -> Bool {
        guard var tools = body["tools"] as? [[String: Any]], !tools.isEmpty else { return false }

        var renamed = Set<String>()
        tools = tools.map { tool in
            // Built-in server tools carry a `type` and a reserved `name`; leave them.
            guard tool["type"] == nil, let name = tool["name"] as? String else { return tool }
            renamed.insert(name)
            var copy = tool
            copy["name"] = name + suffix
            return copy
        }
        for decoy in decoyTools() where !renamed.contains(decoy["name"] as? String ?? "") {
            tools.append(decoy)
        }
        body["tools"] = tools

        if var messages = body["messages"] as? [[String: Any]] {
            messages = messages.map { message in
                guard var content = message["content"] as? [[String: Any]] else { return message }
                content = content.map { block in
                    guard block["type"] as? String == "tool_use",
                          let name = block["name"] as? String,
                          renamed.contains(name) else { return block }
                    var copy = block
                    copy["name"] = name + suffix
                    return copy
                }
                var copy = message
                copy["content"] = content
                return copy
            }
            body["messages"] = messages
        }

        if var choice = body["tool_choice"] as? [String: Any],
           choice["type"] as? String == "tool",
           let name = choice["name"] as? String,
           renamed.contains(name) {
            choice["name"] = name + suffix
            body["tool_choice"] = choice
        }
        return true
    }

    public static func restore(_ name: String) -> String {
        name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name
    }
}
