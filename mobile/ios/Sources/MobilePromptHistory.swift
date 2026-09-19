import Foundation

/// The initial policy stays ahead of history. Later host updates belong to the
/// new user turn and are captured before retries or tool execution can change them.
struct MobilePromptHistory: Codable {
    private(set) var policy: String?

    mutating func capture(prompt: String, policy currentPolicy: String, context: String) -> String {
        if policy == nil { policy = currentPolicy }
        var parts: [String] = []
        if currentPolicy != policy {
            parts.append("<runtime_context>\n\(currentPolicy)\n</runtime_context>")
        }
        if !context.isEmpty { parts.append(context) }
        parts.append(prompt)
        return parts.joined(separator: "\n\n")
    }
}
