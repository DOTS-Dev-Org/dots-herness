import Foundation

/// Stable tool gateway. The complete registered catalog stays on the device.
struct MobileDeferredTools {
    static let search = "discover_tools", invoke = "invoke_tool", plan = "execution_plan", output = "read_tool_output"
    static let definitions: [AgentToolSpec] = [
        spec(search, "Find tools by exact name or short English capability query. Returns up to 5 schemas. Empty query lists names; offset pages them.", ["query": ["type": "string"], "offset": ["type": "integer"]], ["query"]),
        spec(invoke, "Call a discovered tool with its JSON input encoded in the arguments string. Existing approvals apply.", ["name": ["type": "string"], "arguments": ["type": "string"]], ["name", "arguments"]),
        spec(plan, "Record concrete steps before implementation. Mark routine only for bounded known work; include all uncertainties.", ["steps": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 12], "routine": ["type": "boolean"], "uncertainties": ["type": "array", "items": ["type": "string"]]], ["steps", "routine", "uncertainties"]),
        spec(output, "Read a stored tool result without rerunning it. Character offset; limit defaults to 4000, maximum 8000.", ["call_id": ["type": "string"], "offset": ["type": "integer"], "limit": ["type": "integer"]], ["call_id"])
    ]
    static let directNames = ["read_file", "search_files", "grep_files", "edit_file", "run_command", "wait_command", MobilePlanSteps.name]
    static func requestTools(_ catalog: [AgentToolSpec]) -> [AgentToolSpec] {
        definitions + directNames.compactMap { name in catalog.first { $0.name == name } }
    }
    private static let readOnlyToolNames: Set<String> = [
        "read_file", "search_files", "grep_files", "list_files", "glob", "wait_command",
        "web_search", "web_fetch", "skill.list", "skill.read", "skill.resources", "skill.read_resource",
        search, plan, output, MobilePlanSteps.name,
    ]
    static func isReadOnlyTool(_ name: String?) -> Bool {
        guard let name else { return false }
        return readOnlyToolNames.contains(name.lowercased())
    }
    private static func spec(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> AgentToolSpec {
        AgentToolSpec(name: name, description: description, schema: ["type": "object", "properties": properties, "required": required, "additionalProperties": false]) { _ in "Tool error: control tools run in the main session only." }
    }
    private var discovered: [String: Data] = [:]
    private var outputs: [String: String] = [:]
    private(set) var routine = false
    mutating func resetPlan() { routine = false }
    mutating func restoreDiscovery(_ messages: [[String: Any]]) {
        discovered = [:]
        let blocks = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let ids = Set(messages.filter { $0["role"] as? String == "assistant" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }.filter { $0["type"] as? String == "tool_use" && $0["name"] as? String == Self.search }.compactMap { $0["id"] as? String })
        for block in blocks where block["type"] as? String == "tool_result" && ids.contains(block["tool_use_id"] as? String ?? "") {
            guard let result = block["content"] as? String, let data = result.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tools = object["tools"] as? [[String: Any]] else { continue }
            for tool in tools {
                if let name = tool["name"] as? String, let schema = tool["input_schema"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) { discovered[name] = data }
            }
        }
    }
    func effort(_ selected: String, planMode: Bool) -> String {
        routine && !planMode && ["medium", "high", "xhigh", "max", "ultra"].contains(selected.lowercased()) ? "low" : selected
    }
    func resolve(_ call: [String: Any], catalog: [AgentToolSpec]) -> [String: Any] {
        guard call["name"] as? String == Self.invoke else {
            let name = call["name"] as? String ?? ""
            let direct = Self.directNames.contains(name) && catalog.contains { $0.name == name }
            if direct || Self.definitions.contains(where: { $0.name == name }) { return call }
            var rejected = call; rejected["name"] = Self.invoke; return rejected
        }
        guard let input = call["input"] as? [String: Any], let name = input["name"] as? String,
              let schema = discovered[name], catalog.contains(where: { $0.name == name && $0.schemaData == schema }), !Self.definitions.contains(where: { $0.name == name }),
              let args = input["arguments"] as? String, let data = args.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return call }
        var copy = call; copy["name"] = name; copy["input"] = parsed; return copy
    }
    mutating func control(name: String, input: AgentInput, catalog: [AgentToolSpec], planMode: Bool) -> String? {
        if name == Self.search {
            let query = (input.string("query") ?? "").lowercased()
            let candidates = catalog.filter { tool in !Self.definitions.contains { $0.name == tool.name } }
            if query.isEmpty {
                let offset = max(0, input.int("offset") ?? 0)
                return json(["names": Array(candidates.dropFirst(offset).prefix(20)).map(\.name), "next_offset": offset + 20, "total": candidates.count])
            }
            let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map(String.init)
            let scored: [(AgentToolSpec, Int)] = candidates.map { tool in
                let body = (tool.name + " " + tool.description).lowercased()
                return (tool, tool.name.lowercased() == query ? 10_000 : terms.filter { body.contains($0) }.count)
            }
            let ranked = Array(scored.filter { $0.1 > 0 }.sorted { $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 > $1.1 }.prefix(5)).map { $0.0 }
            let exact = candidates.filter { $0.name.lowercased() == query }
            let named = exact.isEmpty ? candidates.filter { terms.contains($0.name.lowercased()) } : exact
            let matches = named.isEmpty ? ranked : Array(named.prefix(5))
            for tool in matches { discovered[tool.name] = tool.schemaData }
            return json(["tools": matches.map(\.wire), "instruction": "Use invoke_tool for these names. Discover more when needed."])
        }
        if name == Self.plan {
            routine = false
            guard let steps = input.strings("steps"), !steps.isEmpty, steps.count <= 12, steps.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), let uncertainties = input.strings("uncertainties"), let bounded = input.bool("routine") else { return "Tool error: provide steps, routine and uncertainties." }
            routine = bounded && steps.count <= 5 && uncertainties.isEmpty && !planMode
            var summary = ["Plan recorded:"]
            summary += steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
            summary.append(uncertainties.isEmpty ? "Unresolved uncertainties: none." : "Unresolved uncertainties:")
            summary += uncertainties.map { "- " + $0 }
            var effortReasons: [String] = []
            if !bounded { effortReasons.append("not marked routine") }
            if steps.count > 5 { effortReasons.append("more than five steps") }
            if !uncertainties.isEmpty { effortReasons.append("open uncertainties") }
            if planMode { effortReasons.append("plan mode is active") }
            summary.append(routine
                ? "Execution effort: routine work uses low effort; failures restore the selected effort."
                : "Execution effort: selected level retained (\(effortReasons.joined(separator: ", "))).")
            return summary.joined(separator: "\n")
        }
        if name == Self.output {
            guard let id = input.string("call_id"), let value = outputs[id] else { return "Tool error: no stored result for this call_id." }
            let offset = max(0, input.int("offset") ?? 0), limit = max(1, min(8_000, input.int("limit") ?? 4_000))
            let page = String(value.dropFirst(offset).prefix(limit))
            return page + (offset + page.count < value.count ? "\n[More output: offset=\(offset + page.count)]" : "")
        }
        return name == Self.invoke ? "Tool error: discover the tool first and use a valid JSON arguments string." : nil
    }
    static let repeatedReadPrefix = "[read_file unchanged:"
    private var reads: [(id: String, path: String)] = []
    /// A read_file whose lines already arrived verbatim in an earlier read of the
    /// same path in this run gets a pointer instead of the same bytes again. The
    /// verbatim check doubles as the unchanged-file proof; read_tool_output can
    /// always reach the earlier result because outputs live for the whole run.
    func repeatedRead(_ text: String, path: String?) -> String? {
        guard let path = Self.normalizePath(path) else { return nil }
        // Drop the "continue at line N (file has M lines)" footer of a cut page.
        let body = text.hasSuffix(" lines)")
            ? text.range(of: "\n\n", options: .backwards).map { String(text[..<$0.lowerBound]) } ?? text
            : text
        guard body.utf8.count >= 512, !body.hasPrefix("Tool error"),
              let earlier = reads.last(where: { $0.path == path && outputs[$0.id]?.contains(body) == true }) else { return nil }
        return "\(Self.repeatedReadPrefix) these lines of \(path) are identical to what call_id=\(earlier.id) returned earlier in this run. Use that result, or read_tool_output call_id=\(earlier.id) if it is no longer visible.]"
    }
    private static func normalizePath(_ path: String?) -> String? {
        guard var path = path?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/") else { return nil }
        while path.hasPrefix("./") { path.removeFirst(2) }
        return path.isEmpty ? nil : path
    }
    mutating func record(_ text: String, id: String, failed: Bool, toolName: String? = nil, path: String? = nil) {
        outputs[id] = text
        if toolName == "read_file", let path = Self.normalizePath(path) { reads.append((id, path)) }
        if (failed || Self.isFailure(text)) && !Self.isReadOnlyTool(toolName) { routine = false }
    }
    static func isFailure(_ value: String) -> Bool {
        let text = value.lowercased()
        return text.hasPrefix("tool error") || text.hasPrefix("error:")
            || text.contains("blocked_in_plan_mode") || text.contains("permission rejected")
            || text.range(of: #"(?:exit[ _]?code|status)\s*[:=]?\s*-?[1-9][0-9]*\b"#, options: .regularExpression) != nil
            || text.range(of: #"(?:^|\n)\s*(?:fatal|error|exception|blocked|refused|failed)(?:[:\s])|\b[1-9][0-9]* (?:tests? )?failed\b|\[check [0-9]+ failed\]"#, options: .regularExpression) != nil
    }
    static func excerpt(_ text: String, name: String, id: String) -> String {
        if name == "read_file" || name == search || name == output || text.utf8.count <= 4_096 { return text }
        let decisive = text.components(separatedBy: "\n").filter { $0.range(of: "error|fatal|exception|failed|exit code|status|denied", options: [.regularExpression, .caseInsensitive]) != nil }.prefix(6).map { String($0.prefix(240)) }.joined(separator: "\n")
        return String(decoding: text.utf8.prefix(1_500), as: UTF8.self) + "\n[… tool output excerpt …]\n" + decisive + "\n" + String(decoding: text.utf8.suffix(600), as: UTF8.self) + "\nOriginal result: read_tool_output call_id=\(id)"
    }
    private func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "Tool error: invalid discovery result." }
        return String(decoding: data, as: UTF8.self)
    }
}
