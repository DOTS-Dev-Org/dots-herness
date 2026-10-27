// Copyright (c) 2026 DOTS
// Canonical project-scoped agent cache contracts.

import CryptoKit
import Foundation
import HarnessPluginKit

public enum AgentCacheNamespace {
    /// The key partitions the provider cache, so it names only what makes the
    /// stable tools+policy prefix differ. Conversations of one account, project
    /// and model share it: a new chat reads that prefix instead of rewriting it.
    public static func key(
        projectID: String?,
        model: String,
        planMode: Bool,
        contextRevision: Int,
        provider: String? = nil,
        api: String? = nil,
        accountID: String? = nil,
        toolFingerprint: String? = nil
    ) -> String {
        let identity = [
            projectID ?? "none",
            model,
            planMode ? "plan" : "normal",
            String(contextRevision),
            provider ?? "unknown-provider",
            api ?? "unknown-api",
            accountID ?? "unknown-account",
            toolFingerprint ?? "unknown-tools",
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "herness:unified-v2:" + digest
    }

    /// Tool arrays are part of the provider prompt prefix. The fingerprint is
    /// canonical so plugin discovery order cannot create a false cache miss.
    public static func toolFingerprint(_ tools: [AgentToolDefinition]) -> String {
        let canonical = keyedCanonically(tools).map(\.key).joined(separator: "\n---\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return String(digest.prefix(32))
    }

    public static func toolSortKey(_ tool: AgentToolDefinition) -> String {
        tool.name + "\n" + tool.description + "\n" + canonicalJSON(tool.parameters)
    }

    /// Each key is built once: computing it inside the sort comparator serialized
    /// every schema ~2 log n times, seconds of main-thread CPU per run.
    public static func canonicallySorted(_ tools: [AgentToolDefinition]) -> [AgentToolDefinition] {
        keyedCanonically(tools).map(\.tool)
    }

    private static func keyedCanonically(_ tools: [AgentToolDefinition]) -> [(key: String, tool: AgentToolDefinition)] {
        tools.map { (key: toolSortKey($0), tool: $0) }.sorted { $0.key < $1.key }
    }

    /// Hash only the stable prompt prefix. Per-turn response style, workspace
    /// facts, memory, and the current date are folded into the user turn and do
    /// not belong in the cache identity.
    public static func promptContextRevision(_ sections: [PromptSection]) -> Int {
        let canonical = sections
            .filter { $0.tag == "core_policy" }
            .map { "\($0.tag)\n\($0.trust.rawValue)\n\($0.text)" }
            .joined(separator: "\n---\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.prefix(4).reduce(0) { ($0 << 8) | Int($1) } & Int.max
    }

    private static func canonicalJSON(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return String(value)
        case .string(let value):
            return "\"" + value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        case .array(let values): return "[" + values.map(canonicalJSON).joined(separator: ",") + "]"
        case .object(let values):
            return "{" + values.keys.sorted().map { key in
                let escaped = key
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"" + escaped + "\":" + canonicalJSON(values[key]!)
            }.joined(separator: ",") + "}"
        }
    }
}
