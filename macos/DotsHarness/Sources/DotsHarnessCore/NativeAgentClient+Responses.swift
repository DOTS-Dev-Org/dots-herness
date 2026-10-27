// Copyright (c) 2026 DOTS
// Provider response and SSE parsing.

import Foundation
import HarnessPluginKit
import PluginRuntime

extension NativeAgentClient {
    static func mergeResponsesOutputItems(
        streamed: [JSONObject],
        terminalOutput: JSONValue?
    ) -> [JSONObject] {
        guard case .array(let output) = terminalOutput else { return streamed }
        var merged = output.compactMap(\.object)
        guard !merged.isEmpty else { return streamed }
        // The terminal output array is the provider's canonical order. Some
        // gateways omit stream items there, so retain any streamed items that
        // are missing after the terminal items (including compaction checkpoints).
        var itemIDs = Set<String>()
        var callIDs = Set<String>()
        var exactItems = Set<String>()
        func exactKey(_ item: JSONObject) -> String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(item) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        func index(_ item: JSONObject) {
            if let id = item["id"]?.string, !id.isEmpty { itemIDs.insert(id) }
            if item["type"]?.string == "function_call",
               let callID = item["call_id"]?.string, !callID.isEmpty { callIDs.insert(callID) }
            if let key = exactKey(item) { exactItems.insert(key) }
        }
        for item in merged { index(item) }
        for item in streamed {
            let idMatches = item["id"]?.string.map { !$0.isEmpty && itemIDs.contains($0) } ?? false
            let callIDMatches = item["call_id"]?.string.map { !$0.isEmpty && callIDs.contains($0) } ?? false
            let exactMatches = exactKey(item).map(exactItems.contains) ?? false
            guard !idMatches, !callIDMatches, !exactMatches else { continue }
            merged.append(item)
            index(item)
        }
        return merged
    }

    private static func anthropicContextEditStats(
        _ contextManagement: JSONValue?
    ) -> (clearedInputTokens: Int?, clearedToolUses: Int?) {
        guard case .array(let edits) = contextManagement?["applied_edits"] else { return (nil, nil) }
        let cleared = edits.filter { $0["type"]?.string == "clear_tool_uses_20250919" }
        guard !cleared.isEmpty else { return (nil, nil) }
        let tokens = cleared.compactMap { $0["cleared_input_tokens"]?.int }
        let toolUses = cleared.compactMap { $0["cleared_tool_uses"]?.int }
        return (
            tokens.isEmpty ? nil : tokens.reduce(0, +),
            toolUses.isEmpty ? nil : toolUses.reduce(0, +)
        )
    }

    static func response(from value: JSONValue) throws -> AgentResponse {
        if value["output"] != nil {
            let blocks: [JSONValue]
            if case .array(let items) = value["output"] { blocks = items } else { blocks = [] }
            let text = blocks.compactMap { block -> String? in
                guard block["type"]?.string == "message", case .array(let content) = block["content"] else { return nil }
                return content.compactMap { $0["text"]?.string }.joined()
            }.joined()
            let calls = blocks.compactMap { block -> AgentToolCall? in
                guard block["type"]?.string == "function_call", let name = block["name"]?.string else { return nil }
                return AgentToolCall(id: block["call_id"]?.string ?? block["id"]?.string ?? UUID().uuidString, name: name, arguments: block["arguments"]?.string ?? "{}")
            }
            let providerItems = blocks.compactMap(\.object)
            let usage = value["usage"]?.object.map {
                AgentUsage(
                    inputTokens: $0["input_tokens"]?.int ?? 0,
                    outputTokens: $0["output_tokens"]?.int ?? 0,
                    cachedTokens: $0["input_tokens_details"]?["cached_tokens"]?.int,
                    cacheWriteTokens: $0["input_tokens_details"]?["cache_write_tokens"]?.int,
                    cacheMissTokens: $0["prompt_cache_miss_tokens"]?.int,
                    reasoningTokens: $0["output_tokens_details"]?["reasoning_tokens"]?.int
                        ?? $0["completion_tokens_details"]?["reasoning_tokens"]?.int
                        ?? $0["reasoning_tokens"]?.int
                        ?? $0["thinking_tokens"]?.int
                )
            }
            let media = blocks.flatMap(Self.mediaPayloads)
            return AgentResponse(
                message: AgentMessage(role: .assistant, content: text, toolCalls: calls, providerItems: providerItems),
                usage: usage,
                media: media,
                nativeCompactionApplied: blocks.contains { $0["type"]?.string == "compaction" },
                incompleteReason: value["incomplete_details"]?["reason"]?.string,
                providerResponseID: value["id"]?.string,
                cacheDiagnostics: AgentProviderCacheDiagnostics(value: value["prompt_cache_diagnostics"])
            )
        }
        if value["type"]?.string == "message" || value["content"] != nil && value["choices"] == nil {
            let blocks: [JSONValue]
            if case .array(let items) = value["content"] { blocks = items } else { blocks = [] }
            var toolCalls: [AgentToolCall] = []
            for block in blocks where block["type"]?.string == "tool_use" {
                guard let name = block["name"]?.string else { continue }
                let input = block["input"]?.any ?? [:]
                let data = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                toolCalls.append(AgentToolCall(id: block["id"]?.string ?? UUID().uuidString, name: name, arguments: String(data: data, encoding: .utf8) ?? "{}"))
            }
            let thinkingBlocks = blocks.compactMap { block -> String? in
                if block["type"]?.string == "thinking" {
                    return block["thinking"]?.string
                }
                return nil
            }
            let thinking = thinkingBlocks.isEmpty ? nil : thinkingBlocks.joined(separator: "\n\n")
            let providerItems = blocks.compactMap(\.object)
            let contextEditStats = anthropicContextEditStats(value["context_management"])
            let usage = value["usage"]?.object.map {
                AgentUsage(
                    inputTokens: $0["input_tokens"]?.int ?? 0,
                    outputTokens: $0["output_tokens"]?.int ?? 0,
                    cachedTokens: $0["cache_read_input_tokens"]?.int,
                    cacheWriteTokens: $0["cache_creation_input_tokens"]?.int,
                    cacheMissTokens: $0["prompt_cache_miss_tokens"]?.int,
                    reasoningTokens: $0["output_tokens_details"]?["reasoning_tokens"]?.int
                        ?? $0["completion_tokens_details"]?["reasoning_tokens"]?.int
                        ?? $0["reasoning_tokens"]?.int
                        ?? $0["thinking_tokens"]?.int,
                    contextClearedInputTokens: contextEditStats.clearedInputTokens,
                    contextClearedToolUses: contextEditStats.clearedToolUses
                )
            }
            return AgentResponse(
                message: AgentMessage(
                    role: .assistant,
                    content: blocks.textBlocks,
                    thinking: thinking,
                    toolCalls: toolCalls,
                    providerItems: providerItems
                ),
                usage: usage,
                media: blocks.flatMap(Self.mediaPayloads),
                incompleteReason: value["stop_reason"]?.string == "max_tokens" ? "max_output_tokens" : nil,
                providerResponseID: value["id"]?.string,
                cacheDiagnostics: AgentProviderCacheDiagnostics(anthropicValue: value["diagnostics"])
            )
        }
        guard let choice = value["choices"]?.firstObject,
              let messageObject = choice["message"]?.object else {
            throw NativeAgentError(AppCopy.text("agent.noMessage"))
        }

        let content = messageObject["content"]?.textBlocks() ?? ""
        let reasoning = messageObject["reasoning_content"]?.string
            ?? messageObject["reasoning"]?.string
        var toolCalls: [AgentToolCall] = []
        if case .array(let items) = messageObject["tool_calls"] {
            toolCalls = items.compactMap { item in
                guard let function = item["function"]?.object,
                      let name = function["name"]?.string else { return nil }
                return AgentToolCall(
                    id: item["id"]?.string ?? UUID().uuidString,
                    name: name,
                    arguments: function["arguments"]?.string ?? "{}"
                )
            }
        }

        let usage = value["usage"]?.object.map {
            AgentUsage(
                inputTokens: $0["prompt_tokens"]?.int
                    ?? (($0["prompt_cache_hit_tokens"]?.int ?? 0) + ($0["prompt_cache_miss_tokens"]?.int ?? 0)),
                outputTokens: $0["completion_tokens"]?.int ?? 0,
                cachedTokens: $0["prompt_tokens_details"]?["cached_tokens"]?.int
                    ?? $0["prompt_cache_hit_tokens"]?.int,
                cacheWriteTokens: $0["prompt_tokens_details"]?["cache_write_tokens"]?.int,
                cacheMissTokens: $0["prompt_cache_miss_tokens"]?.int,
                reasoningTokens: $0["output_tokens_details"]?["reasoning_tokens"]?.int
                    ?? $0["completion_tokens_details"]?["reasoning_tokens"]?.int
                    ?? $0["reasoning_tokens"]?.int
                    ?? $0["thinking_tokens"]?.int
            )
        }
        return AgentResponse(
            message: AgentMessage(role: .assistant, content: content, thinking: reasoning, toolCalls: toolCalls),
            usage: usage,
            media: Self.mediaPayloads(from: messageObject["content"] ?? .null),
            incompleteReason: choice["finish_reason"]?.string == "length" ? "max_output_tokens" : nil
        )
    }

    /// The Codex `/responses` endpoint answers only as an SSE stream, and its
    /// terminal `response.completed` payload ships an EMPTY `output` array —
    /// content lives solely in the incremental events. So the stream itself is
    /// the source of truth for text and tool calls; `response.completed` only
    /// contributes usage (and the output blocks, on backends that do send them).
    static func responseFromSSE(_ data: Data) throws -> AgentResponse {
        let text = String(decoding: data, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return try response(from: JSONCodec.parse(data))
        }
        var state = ResponseStreamState()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            _ = try state.consume(line: line)
        }
        return try state.response()
    }

    static func imageBase64FromResponse(_ data: Data) throws -> String {
        let text = String(decoding: data, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            guard let result = imageBase64(from: try JSONCodec.parse(data)), !result.isEmpty else {
                throw NativeAgentError(AppCopy.text("media.noOutput"))
            }
            return result
        }

        var result: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty, payload != "[DONE]",
                  let event = try? JSONCodec.parse(Data(payload.utf8)) else { continue }
            switch event["type"]?.string ?? "" {
            case "response.output_item.done":
                result = imageBase64(from: event["item"] ?? .null) ?? result
            case "response.completed", "response.incomplete":
                result = imageBase64(from: event["response"] ?? event) ?? result
            case "response.image_generation_call.completed":
                result = event["result"]?.string
                    ?? event["image_generation_call"]?["result"]?.string
                    ?? result
            case "response.failed", "error":
                let (message, status) = NativeAgentClient.streamFailure(in: event, fallback: "The image generation stream reported an error.")
                throw NativeAgentError(
                    message,
                    statusCode: status,
                    isLimit: Self.limitKind(from: event, status: status) != nil
                )
            default:
                break
            }
        }
        guard let result, !result.isEmpty else {
            throw NativeAgentError(AppCopy.text("media.noOutput"))
        }
        return result
    }

    private static func imageBase64(from value: JSONValue) -> String? {
        if value["type"]?.string == "image_generation_call" {
            return value["result"]?.string
        }
        let payload = value["response"] ?? value
        guard case .array(let output) = payload["output"] else { return nil }
        return output.first { $0["type"]?.string == "image_generation_call" }?["result"]?.string
    }

    /// Code Assist nests the Gemini reply under `response`; older shapes return it
    /// at the top level, so accept both.
    static func geminiResponse(from value: JSONValue) throws -> AgentResponse {
        let payload = value["response"] ?? value
        guard case .array(let candidates) = payload["candidates"], let first = candidates.first,
              case .array(let parts) = first["content"]?["parts"] else {
            throw NativeAgentError(AppCopy.text("agent.noMessage"))
        }
        let thinkingParts = parts.compactMap { part -> String? in
            if part["thought"]?.bool == true {
                return part["text"]?.string
            }
            return nil
        }
        let thinking = thinkingParts.isEmpty ? nil : thinkingParts.joined(separator: "\n\n")
        let text = parts.compactMap { part -> String? in
            if part["thought"]?.bool == true {
                return nil
            }
            return part["text"]?.string
        }.joined()
        let calls = parts.compactMap { part -> AgentToolCall? in
            guard let call = part["functionCall"]?.object, let name = call["name"]?.string else { return nil }
            let arguments = call["args"]?.any ?? [:]
            let data = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
            return AgentToolCall(id: name, name: name, arguments: String(data: data, encoding: .utf8) ?? "{}")
        }
        let usage = payload["usageMetadata"]?.object.map {
            AgentUsage(
                inputTokens: $0["promptTokenCount"]?.int ?? 0,
                // Gemini bills thinking as output but reports it outside
                // `candidatesTokenCount`; other routes already include it.
                outputTokens: ($0["candidatesTokenCount"]?.int ?? 0) + ($0["thoughtsTokenCount"]?.int ?? 0),
                cachedTokens: $0["cachedContentTokenCount"]?.int,
                reasoningTokens: $0["thoughtsTokenCount"]?.int
            )
        }
        return AgentResponse(
            message: AgentMessage(role: .assistant, content: text, thinking: thinking, toolCalls: calls),
            usage: usage,
            media: parts.flatMap(Self.mediaPayloads)
        )
    }
}
