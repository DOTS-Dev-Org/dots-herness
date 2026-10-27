// Copyright (c) 2026 DOTS
// Deterministic token economy policy shared by the native agent loop and transports.

import Foundation
import HarnessPluginKit

public enum AgentUsageMode: String, Codable, CaseIterable, Sendable {
    case standard
    case economy

    public var title: String {
        switch self {
        case .standard: return "Standard"
        case .economy: return "Economy"
        }
    }
}

/// A request budget deliberately separates the room needed for reasoning from
/// the room needed for the visible answer. Provider APIs charge both against
/// the same output ceiling on reasoning models.
public struct AgentOutputBudget: Sendable, Equatable {
    public let visibleReserve: Int
    public let reasoningReserve: Int
    public let protocolReserve: Int
    public let maxOutputTokens: Int
    public let providerReasoningBudgetTokens: Int?

    public init(
        visibleReserve: Int,
        reasoningReserve: Int,
        protocolReserve: Int = 1_024,
        maxOutputTokens: Int,
        providerReasoningBudgetTokens: Int? = nil
    ) {
        self.visibleReserve = visibleReserve
        self.reasoningReserve = reasoningReserve
        self.protocolReserve = protocolReserve
        self.maxOutputTokens = maxOutputTokens
        self.providerReasoningBudgetTokens = providerReasoningBudgetTokens
    }

    /// Expands the provider ceiling only for the single bounded retry used by
    /// soft economy/style turns. Strict per-turn limits must never call this.
    public func expanded(for configuration: AgentConfiguration) -> AgentOutputBudget {
        let expanded = min(
            AgentOutputBudget.providerMaximum(for: configuration),
            max(maxOutputTokens + 4_096, Int(ceil(Double(maxOutputTokens) * 1.5)))
        )
        return AgentOutputBudget(
            visibleReserve: visibleReserve,
            reasoningReserve: max(reasoningReserve, expanded - visibleReserve - protocolReserve),
            protocolReserve: protocolReserve,
            maxOutputTokens: min(AgentOutputBudget.providerMaximum(for: configuration), Self.roundUp(expanded)),
            providerReasoningBudgetTokens: providerReasoningBudgetTokens.map {
                min($0 + 4_096, max($0, expanded - visibleReserve - protocolReserve))
            }
        )
    }

    static func resolve(
        configuration: AgentConfiguration,
        messages: [AgentMessage],
        tools: [AgentToolDefinition],
        decision: ResponseStyleDecision? = nil
    ) -> AgentOutputBudget {
        let codingLike = !tools.isEmpty || messages.contains {
            $0.role == .tool || !$0.toolCalls.isEmpty
        }
        let selectedDecision = decision ?? ResponseStyleResolver.resolve(
            preference: configuration.responseStylePreference,
            prompt: messages.last(where: { $0.role == .user })?.authoredContent
        )
        let detectedStyle = selectedDecision.style
        let visibleBase: Int
        if codingLike {
            // The provider ceiling also contains tool calls, write_file payloads,
            // and reasoning. A short final answer must not starve execution.
            visibleBase = 12_288
        } else {
            visibleBase = switch detectedStyle {
            case .ultra: 1_024
            case .concise, .strict: 2_048
            case .standard, .detailed: 4_096
            }
        }
        let writeReserve = messages.flatMap(\.toolCalls).reduce(0) { total, call in
            let unwrapped = EconomyToolOutputPolicy.unwrapCall(call)
            guard unwrapped.name == "write_file",
                  let object = try? JSONCodec.parse(Data(unwrapped.arguments.utf8)).object,
                  let content = object["content"]?.string else { return total }
            return max(total, Int(ceil(Double(content.utf8.count) / 4.0)) + 1_024)
        }
        let visible = max(visibleBase, writeReserve)
        let effortReserve = reasoningStartingReserve(effort: configuration.effort, codingLike: codingLike)
        let recent = AgentOutputBudgetStore.shared.highestRecent(
            provider: configuration.provider,
            model: configuration.model,
            effort: configuration.effort
        )
        let reasoning = max(effortReserve, recent.map { $0 + max(1_024, effortReserve / 4) } ?? 0)
        let raw = reasoning + visible + 1_024
        let maximum = providerMaximum(for: configuration)
        // A provider cap on a tool turn would cut tool calls and write_file payloads;
        // the style limit still shapes the prose there.
        let requestedHardLimit = detectedStyle == .strict && !codingLike
            ? selectedDecision.providerOutputTokenCap
            : nil
        let cap = requestedHardLimit.map { min(maximum, max(1, $0)) }
            ?? min(maximum, max(1_024, roundUp(raw)))
        let providerBudget = configuration.supportsLegacyThinkingBudget && cap > visible + 1_024
            // Thinking parameters are rendered into the prompt. Following recent
            // usage would move the budget every turn and drop the message cache.
            ? max(4_096, effortReserve)
            : nil
        return AgentOutputBudget(
            visibleReserve: visible,
            reasoningReserve: reasoning,
            maxOutputTokens: cap,
            providerReasoningBudgetTokens: providerBudget.map { min($0, max(1, cap - visible - 1_024)) }
        )
    }

    static func providerMaximum(for configuration: AgentConfiguration) -> Int {
        let transportMaximum: Int
        switch configuration.api {
        case RouterAPIKind.anthropic.rawValue: transportMaximum = 64_000
        case RouterAPIKind.geminiCLI.rawValue: transportMaximum = 65_536
        default: transportMaximum = 128_000
        }
        guard configuration.contextWindow > 0 else { return transportMaximum }
        return min(transportMaximum, max(1_024, configuration.contextWindow - 1_024))
    }

    static func reasoningStartingReserve(effort: String, codingLike: Bool) -> Int {
        switch effort.lowercased() {
        case "none": return 0
        case "minimal": return codingLike ? 1_024 : 512
        case "low": return codingLike ? 4_096 : 2_048
        case "medium": return codingLike ? 8_192 : 4_096
        case "high": return codingLike ? 12_288 : 8_192
        case "xhigh": return codingLike ? 16_384 : 12_288
        case "max": return codingLike ? 24_576 : 16_384
        default: return codingLike ? 4_096 : 2_048
        }
    }

    static func roundUp(_ value: Int) -> Int {
        let step = 512
        return max(step, ((max(1, value) + step - 1) / step) * step)
    }
}

/// Keeps a very small per-route history. This is intentionally process-local:
/// it is a sizing hint, not user content and must never become a transcript.
final class AgentOutputBudgetStore: @unchecked Sendable {
    static let shared = AgentOutputBudgetStore()
    private let lock = NSLock()
    private var values: [String: [Int]] = [:]

    func record(configuration: AgentConfiguration, reasoningTokens: Int) {
        guard reasoningTokens > 0 else { return }
        let key = "\(configuration.provider)|\(configuration.model)|\(configuration.effort)"
        lock.lock()
        defer { lock.unlock() }
        values[key] = Array((values[key, default: []] + [reasoningTokens]).suffix(4))
    }

    func highestRecent(provider: String, model: String, effort: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return values["\(provider)|\(model)|\(effort)"]?.max()
    }
}

public enum EconomyToolOutputPolicy {
    public static let tokenLimit = 1_024
    public static let lineLimit = 160
    public static let marker = "[… tool output reduced for context economy …]"
        + "\nContinue with read_file offset or a narrower grep_files query."

    public static func normalize(_ value: String, toolName: String, arguments: String = "") -> String {
        guard !value.isEmpty else { return value }
        let name = toolName.lowercased()
        // read_file already bounds whole lines and records exactly those bytes.
        // Clipping it again invalidates the read ledger and prevents editing.
        if name == "read_file" || name == DeferredToolSession.searchName || name == DeferredToolSession.outputName { return value }
        if name == "grep_files" { return normalizeLines(value, arguments: arguments, includeNextOffset: false) }
        if name == "run_command" || name == "terminal_session" {
            return clipHeadTail(value, marker: marker)
        }
        return clipHeadTail(value, marker: marker)
    }

    static func unwrapCall(_ call: AgentToolCall) -> AgentToolCall {
        guard call.name == DeferredToolSession.invokeName,
              let input = (try? JSONCodec.parse(Data(call.arguments.utf8)))?.object,
              let name = input["name"]?.string else { return call }
        let arguments = input["arguments"]?.string ?? "{}"
        return AgentToolCall(id: call.id, name: name, arguments: arguments)
    }

    public static func normalizeMessages(_ messages: [AgentMessage]) -> [AgentMessage] {
        // Keep this transformation position-independent. Turning an older tool
        // result into a marker merely because a new user turn was appended would
        // rewrite the already-sent provider prefix and cause a false cache miss.
        // The complete result remains in the durable transcript; this is only the
        // reversible provider-facing view.
        // Nearest preceding assistant call per id, built in one forward pass.
        var callsByID: [String: AgentToolCall] = [:]
        return messages.map { message in
            if message.role == .assistant {
                for call in message.toolCalls.reversed() { callsByID[call.id] = call }
            }
            guard message.role == .tool else { return message }
            var copy = message
            let matchedCall = message.toolCallID.flatMap { callsByID[$0] }.map(unwrapCall)
            let arguments = matchedCall?.arguments ?? ""
            let toolName: String
            if let name = message.name, !name.isEmpty, name != DeferredToolSession.invokeName {
                toolName = name
            } else {
                toolName = matchedCall?.name ?? message.name ?? "tool"
            }
            let body = normalize(message.content, toolName: toolName, arguments: arguments)
            copy.content = body
            copy.providerItems = normalizeProviderItems(message.providerItems, output: body)
            return copy
        }
    }

    public static func normalizeProviderItems(_ items: [JSONObject], output: String) -> [JSONObject] {
        items.map { item in
            var copy = item
            let type = item["type"]?.string?.lowercased() ?? ""
            if type == "function_call_output" { copy["output"] = .string(output) }
            if type == "tool_result" { copy["content"] = .string(output) }
            return copy
        }
    }

    private static func normalizeLines(_ value: String, arguments: String, includeNextOffset: Bool) -> String {
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let rawOffset = (try? JSONCodec.parse(Data(arguments.utf8)).object)?["offset"]?.int
            ?? (try? JSONCodec.parse(Data(arguments.utf8)).object)?["start_line"]?.int
            ?? 0
        let visibleLineCount = max(1, min(lines.count, lineLimit - 2))
        let continuation = includeNextOffset
            ? "\nDevam için offset=\(rawOffset + visibleLineCount) kullanın."
            : ""
        let boundedMarker = marker + continuation
        guard lines.count > lineLimit else { return clipHeadTail(value, marker: boundedMarker) }
        let kept = max(1, lineLimit - 2)
        let nextOffset = rawOffset + kept
        let lineBoundedContinuation = includeNextOffset
            ? "\nDevam için offset=\(nextOffset) kullanın."
            : ""
        let body = lines.prefix(kept).joined(separator: "\n")
        let marked = body + "\n" + marker + lineBoundedContinuation
        return marked.utf8.count <= tokenLimit * 4
            ? marked
            : clipHeadTail(body, marker: marker + lineBoundedContinuation)
    }

    private static func clipHeadTail(_ value: String, marker: String) -> String {
        let maximum = tokenLimit * 4
        guard value.utf8.count > maximum else { return value }
        var marker = marker
        let important = importantLines(in: value)
        if !important.isEmpty { marker += "\nImportant lines:\n" + important }
        if marker.utf8.count > maximum / 2 {
            marker = String(decoding: marker.utf8.prefix(maximum / 2), as: UTF8.self)
                + "\n[… additional important lines omitted …]"
        }
        let tailBytes = min(1_200, maximum / 5)
        let headBytes = max(1, maximum - tailBytes - marker.utf8.count - 8)
        // `headBytes`/`tailBytes` are byte budgets, while String.prefix/suffix
        // count extended grapheme clusters. Decode the bounded UTF-8 slices so
        // Turkish/CJK tool output cannot accidentally exceed the token cap.
        let head = String(decoding: value.utf8.prefix(headBytes), as: UTF8.self)
        let tail = String(decoding: value.utf8.suffix(tailBytes), as: UTF8.self)
        return head + "\n" + marker + "\n" + tail
    }

    private static func importantLines(in value: String) -> String {
        var seen = Set<String>()
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && isImportantLine($0) }
            .filter { seen.insert($0).inserted }
            .prefix(12)
            .map { line in
                let bounded = line.utf8.count <= 512
                    ? line
                    : String(decoding: line.utf8.prefix(512), as: UTF8.self) + "…"
                return "- " + bounded
            }
        return lines.joined(separator: "\n")
    }

    private static func isImportantLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("error")
            || lower.contains("fatal")
            || lower.contains("exception")
            || lower.contains("traceback")
            || lower.contains("failed")
            || lower.contains("failure")
            || lower.contains("security")
            || lower.contains("unsafe")
            || lower.contains("warning")
            || lower.contains("status")
            || lower.contains("exit code")
            || lower.contains("test")
            || lower.contains("assert")
            || lower.contains("denied")
            || lower.contains("rejected")
            || lower.contains("permission")
            || lower.hasPrefix("diff --git")
            || lower.hasPrefix("@@")
            || line.hasPrefix("+++ ")
            || line.hasPrefix("--- ")
    }
}
