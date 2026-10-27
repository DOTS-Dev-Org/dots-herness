import Foundation
import HarnessPluginKit

/// Only this small, immutable interface reaches the provider. Real schemas are
/// returned by discovery and remain at their original point in the transcript.
public struct DeferredToolSession {
    public static let searchName = "discover_tools"
    public static let invokeName = "invoke_tool"
    public static let planName = "execution_plan"
    public static let outputName = "read_tool_output"
    public static let enterPlanName = "enter_plan_mode"
    public static let definitions: [AgentToolDefinition] = [
        .init(name: searchName, description: "Find tools by exact name or English capability query. Returns at most 5 matching schemas. Empty query lists names only; use offset to page.", parameters: schema(["query": .object(["type": .string("string")]), "offset": .object(["type": .string("integer")])], required: ["query"])),
        .init(name: invokeName, description: "Call a discovered tool. Arguments must be a JSON object encoded as a string. Send independent calls together in one response; they run as one round. Existing permissions and execution scope apply.", parameters: schema(["name": .object(["type": .string("string")]), "arguments": .object(["type": .string("string")])], required: ["name", "arguments"])),
        .init(name: planName, description: "Record a concrete plan after inspection, before implementation. Mark routine only for a bounded known approach; list unresolved uncertainties. Replan when scope or evidence changes.", parameters: schema(["steps": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "minItems": .number(1), "maxItems": .number(12)]), "routine": .object(["type": .string("boolean")]), "uncertainties": .object(["type": .string("array"), "items": .object(["type": .string("string")])])], required: ["steps", "routine", "uncertainties"])),
        .init(name: outputName, description: "Read the original result of a tool in this run without rerunning it. Offsets and limits are characters; default limit 4000, maximum 8000.", parameters: schema(["call_id": .object(["type": .string("string")]), "offset": .object(["type": .string("integer")]), "limit": .object(["type": .string("integer")])], required: ["call_id"])),
        .init(name: enterPlanName, description: "Switch this turn to read-only plan mode. Call it alone, first, only when the user asks for a plan or plan mode (any language) instead of the work. Not for running an existing plan.", parameters: schema([:], required: []))
    ]
    /// Sent with their schemas on every request: almost every coding turn reads, searches,
    /// edits and runs a check, and a discover round first would resend the whole context for nothing.
    public static let directNames = ["read_file", "grep_files", FileEditTools.globName, "edit_file", "run_command", WorkspaceTools.waitName]
    /// The provider surface: the controls, then the direct tools the catalog offers, in a fixed
    /// order so the prompt cache holds. Plan mode sends the same list - a plan and its approved
    /// run share one cache namespace - and refuses edit_file when it is called.
    public static func requestTools(_ catalog: [AgentToolDefinition]) -> [AgentToolDefinition] {
        definitions + directNames.compactMap { name in catalog.first { $0.name == name } }
    }
    private static func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }
    private var discovered: [String: JSONValue] = [:]
    private var outputs: [String: String] = [:]
    public private(set) var routineExecution = false
    public init() {}
    /// Reuse schemas already returned in this conversation; never restore a plan
    /// for a new user task or infer schemas from arbitrary user/tool text.
    public mutating func restoreDiscovery(_ messages: [AgentMessage]) {
        discovered = [:]
        let ids = Set(messages.filter { $0.role == .assistant }.flatMap(\.toolCalls).filter { $0.name == Self.searchName }.map(\.id))
        for message in messages where message.role == .tool && ids.contains(message.toolCallID ?? "") {
            guard let value = try? JSONCodec.parse(Data(message.content.utf8)), let tools = value.object?["tools"]?.array else { continue }
            for tool in tools {
                if let object = tool.object, let name = object["name"]?.string, let schema = object["parameters"] { discovered[name] = schema }
            }
        }
    }
    public func effort(selected: String, planMode: Bool) -> String {
        guard routineExecution, !planMode, ["medium", "high", "xhigh", "max", "ultra"].contains(selected.lowercased()) else { return selected }
        return "low"
    }
    public mutating func resetPlan() { routineExecution = false }
    /// Invalid envelopes never become executable underlying calls.
    public func resolve(_ call: AgentToolCall, catalog: [AgentToolDefinition]) -> AgentToolCall {
        guard call.name == Self.invokeName else {
            let direct = Self.directNames.contains(call.name) && catalog.contains { $0.name == call.name }
            return direct || Self.definitions.contains(where: { $0.name == call.name }) ? call : AgentToolCall(id: call.id, name: Self.invokeName, arguments: call.arguments)
        }
        // A direct tool's schema is already in every request, so wrapping it in invoke_tool
        // needs no discovery; refusing it only cost the model another full round.
        guard let input = (try? JSONCodec.parse(Data(call.arguments.utf8)))?.object,
              let name = input["name"]?.string,
              let tool = catalog.first(where: { $0.name == name && !Self.definitions.contains(where: { $0.name == name }) }),
              Self.directNames.contains(name) || discovered[name] == tool.parameters,
              let arguments = input["arguments"]?.string,
              (try? JSONCodec.parse(Data(arguments.utf8)))?.object != nil else { return call }
        return AgentToolCall(id: call.id, name: name, arguments: arguments)
    }
    public mutating func control(_ call: AgentToolCall, catalog: [AgentToolDefinition], planMode: Bool) -> String? {
        let input = (try? JSONCodec.parse(Data(call.arguments.utf8)))?.object ?? [:]
        switch call.name {
        case Self.enterPlanName:
            return planMode
                ? HerNessPrompt.planMode(tools: Self.definitions.map(\.name))
                : "Plan mode is unavailable here. Do the work directly."
        case Self.searchName:
            let query = (input["query"]?.string ?? "").lowercased()
            let candidates = catalog.filter { tool in !Self.definitions.contains { $0.name == tool.name } }.sorted { $0.name < $1.name }
            if query.isEmpty {
                let offset = max(0, input["offset"]?.int ?? 0)
                return encode(["names": Array(candidates.dropFirst(offset).prefix(20)).map(\.name), "next_offset": offset + 20, "total": candidates.count])
            }
            let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map(String.init)
            let scored: [(AgentToolDefinition, Int)] = candidates.map { tool in
                let body = (tool.name + " " + tool.description).lowercased()
                let score = tool.name.lowercased() == query ? 10_000 : terms.reduce(0) { $0 + (body.contains($1) ? 1 : 0) }
                return (tool, score)
            }
            let ranked = scored.filter { $0.1 > 0 }.sorted { $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 > $1.1 }
            let exact = candidates.filter { $0.name.lowercased() == query }
            let named = exact.isEmpty ? candidates.filter { terms.contains($0.name.lowercased()) } : exact
            let matches: [AgentToolDefinition] = named.isEmpty ? ranked.prefix(5).map { $0.0 } : Array(named.prefix(5))
            for tool in matches { discovered[tool.name] = tool.parameters }
            return encode(["tools": matches.map { ["name": $0.name, "description": String($0.description.prefix(480)), "parameters": $0.parameters.any] }, "instruction": "Use invoke_tool for these names only. Discover more when needed."])
        case Self.planName:
            guard let steps = input["steps"]?.array, !steps.isEmpty, steps.count <= 12,
                  steps.allSatisfy({ !($0.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }),
                  let uncertainties = input["uncertainties"]?.array,
                  uncertainties.allSatisfy({ $0.string != nil }), let routine = input["routine"]?.bool else {
                routineExecution = false
                return "Tool error: provide 1-12 concrete steps, routine, and uncertainties."
            }
            routineExecution = routine && steps.count <= 5 && uncertainties.isEmpty && !planMode
            var summary = ["Plan recorded:"]
            summary += steps.enumerated().map { "\($0.offset + 1). \($0.element.string ?? "")" }
            if uncertainties.isEmpty {
                summary.append("Unresolved uncertainties: none.")
            } else {
                summary.append("Unresolved uncertainties:")
                summary += uncertainties.compactMap { $0.string }.map { "- " + $0 }
            }
            var effortReasons: [String] = []
            if !routine { effortReasons.append("not marked routine") }
            if steps.count > 5 { effortReasons.append("more than five steps") }
            if !uncertainties.isEmpty { effortReasons.append("open uncertainties") }
            if planMode { effortReasons.append("plan mode is active") }
            summary.append(routineExecution
                ? "Execution effort: routine work uses low effort; failures restore the selected effort."
                : "Execution effort: selected level retained (\(effortReasons.joined(separator: ", "))).")
            return summary.joined(separator: "\n")
        case Self.outputName:
            guard let id = input["call_id"]?.string, let value = outputs[id] else { return "Tool error: no stored result for that call_id in this run." }
            let offset = max(0, input["offset"]?.int ?? 0)
            let limit = max(1, min(8_000, input["limit"]?.int ?? 4_000))
            let page = String(value.dropFirst(offset).prefix(limit))
            return page + (offset + page.count < value.count ? "\n[More output: offset=\(offset + page.count)]" : "")
        case Self.invokeName: return "Tool error: discover this tool first and pass a valid JSON arguments string."
        default: return nil
        }
    }
    private static let readOnlyToolNames: Set<String> = [
        "read_file", "grep_files", "list_files", "search_files", "glob",
        "web_search", "web_fetch", "skill.list", "skill.read",
        searchName, planName, outputName,
    ]
    public static func isReadOnlyTool(_ name: String?) -> Bool {
        guard let name else { return false }
        return readOnlyToolNames.contains(name.lowercased())
    }
    public static let repeatedReadPrefix = "[read_file unchanged:"
    /// A read_file whose lines already arrived verbatim in an earlier read of the
    /// same path in this run gets a pointer instead of the same bytes again. The
    /// verbatim check doubles as the unchanged-file proof; read_tool_output can
    /// always reach the earlier result because outputs live for the whole run.
    public func repeatedRead(_ value: String, arguments: String) -> String? {
        guard let path = Self.readPath(arguments) else { return nil }
        // Drop the "continue at line N (file has M lines)" footer of a cut page.
        let body = value.hasSuffix(" lines)")
            ? value.range(of: "\n\n", options: .backwards).map { String(value[..<$0.lowerBound]) } ?? value
            : value
        guard body.utf8.count >= 512, !body.hasPrefix("Tool error") else { return nil }
        guard let earlier = reads.last(where: { $0.path == path && outputs[$0.callID]?.contains(body) == true }) else { return nil }
        return "\(Self.repeatedReadPrefix) these lines of \(path) are identical to what call_id=\(earlier.callID) returned earlier in this run. Use that result, or read_tool_output call_id=\(earlier.callID) if it is no longer visible.]"
    }
    private var reads: [(callID: String, path: String)] = []
    private static func readPath(_ arguments: String) -> String? {
        guard var path = (try? JSONCodec.parse(Data(arguments.utf8)))?.object?["path"]?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/") else { return nil }
        while path.hasPrefix("./") { path.removeFirst(2) }
        return path.isEmpty ? nil : path
    }
    public mutating func record(_ value: String, callID: String, toolName: String? = nil, arguments: String? = nil) {
        outputs[callID] = value
        if toolName == "read_file", let arguments, let path = Self.readPath(arguments) { reads.append((callID, path)) }
        if !Self.isReadOnlyTool(toolName) && Self.failed(value) { routineExecution = false }
    }
    // Compiled once: `failed` runs on every tool result, on the main actor.
    nonisolated(unsafe) private static let exitCodePattern = try! NSRegularExpression(pattern: #"(?:exit[ _]?code|status)\s*[:=]?\s*-?[1-9][0-9]*\b"#)
    nonisolated(unsafe) private static let failureLinePattern = try! NSRegularExpression(pattern: #"(?:^|\n)\s*(?:fatal|error|exception|blocked|refused|failed)(?:[:\s])|\b[1-9][0-9]* (?:tests? )?failed\b|\[check [0-9]+ failed\]"#)

    public static func failed(_ value: String) -> Bool {
        let text = value.lowercased()
        let range = NSRange(text.startIndex..., in: text)
        return text.hasPrefix("tool error") || text.hasPrefix("error:") || text.contains("blocked_in_plan_mode") || text.contains("permission rejected")
            || exitCodePattern.firstMatch(in: text, range: range) != nil
            || failureLinePattern.firstMatch(in: text, range: range) != nil
    }
    private func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "Tool error: invalid discovery result." }
        return text
    }
}
