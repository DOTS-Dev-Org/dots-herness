// Copyright (c) 2026 DOTS

import Foundation

/// Chat-completion replies a model gives to run a tool through the deferred
/// gateway: the schema is discovered first, then the call goes through `invoke_tool`.
enum DeferredToolScript {
    static func discover(_ names: [String]) -> [String: Any] {
        toolCall(id: "discover-\(names.joined(separator: "-"))", name: "discover_tools",
                 arguments: ["query": names.joined(separator: " ")])
    }

    /// `arguments` is the tool's own JSON input, exactly as the model would write it.
    static func invoke(id: String, name: String, arguments: String) -> [String: Any] {
        toolCall(id: id, name: "invoke_tool", arguments: ["name": name, "arguments": arguments])
    }

    static func reply(_ toolCall: [String: Any]) -> Data {
        let message: [String: Any] = ["role": "assistant", "content": "", "tool_calls": [toolCall]]
        return try! JSONSerialization.data(withJSONObject: ["choices": [["message": message]]])
    }

    /// Discovery, the call itself, then a closing "done".
    static func replies(id: String, name: String, arguments: String) -> [Data] {
        [
            reply(discover([name])),
            reply(invoke(id: id, name: name, arguments: arguments)),
            Data(#"{"choices":[{"message":{"role":"assistant","content":"done"}}]}"#.utf8),
        ]
    }

    private static func toolCall(id: String, name: String, arguments: [String: String]) -> [String: Any] {
        let encoded = String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        return ["id": id, "type": "function", "function": ["name": name, "arguments": encoded]]
    }
}
