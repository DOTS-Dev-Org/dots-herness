// Copyright (c) 2026 DOTS
// Incremental Codex /responses SSE parsing for Dots Harness.

import Foundation
import HarnessPluginKit

extension NativeAgentClient {
    /// Anthropic sends input/cache counters and diagnostics on message_start;
    /// message_delta usually adds only output usage. Keep both instead of
    /// replacing the initial counters with a partial terminal usage object.
    struct AnthropicStreamState {
        private var message: JSONObject = [:]
        private var usage: JSONObject = [:]
        private var blocks: [Int: JSONObject] = [:]
        private var arguments: [Int: String] = [:]
        /// Streamed text, thinking and signature per block, appended in place and merged
        /// into the block once: rebuilding the block's string per delta was O(n²).
        private var streamed: [Int: [String: String]] = [:]
        private var diagnostics: JSONValue?

        mutating func consume(line rawLine: some StringProtocol) throws {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { return }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let event = try? JSONCodec.parse(Data(payload.utf8)) else { return }
            switch event["type"]?.string {
            case "message_start":
                message = event["message"]?.object ?? [:]
                usage = event["message"]?["usage"]?.object ?? [:]
                diagnostics = event["message"]?["diagnostics"] ?? event["diagnostics"]
            case "content_block_start":
                guard let index = event["index"]?.int, let block = event["content_block"]?.object else { return }
                blocks[index] = block
            case "content_block_delta":
                guard let index = event["index"]?.int, blocks[index] != nil else { return }
                let delta = event["delta"]
                switch delta?["type"]?.string {
                case "text_delta":
                    streamed[index, default: [:]]["text", default: ""] += delta?["text"]?.string ?? ""
                case "thinking_delta":
                    streamed[index, default: [:]]["thinking", default: ""] += delta?["thinking"]?.string ?? ""
                case "signature_delta":
                    streamed[index, default: [:]]["signature", default: ""] += delta?["signature"]?.string ?? ""
                case "input_json_delta":
                    arguments[index, default: ""] += delta?["partial_json"]?.string ?? ""
                default: break
                }
            case "message_delta":
                if let partial = event["usage"]?.object { usage.merge(partial) { _, new in new } }
                if let reason = event["delta"]?["stop_reason"] { message["stop_reason"] = reason }
                if let contextManagement = event["context_management"] {
                    message["context_management"] = contextManagement
                }
            case "error":
                throw NativeAgentError(event["error"]?["message"]?.string ?? "The Claude stream reported an error.")
            default: break
            }
        }

        func response() throws -> AgentResponse {
            guard !message.isEmpty else { throw NativeAgentError(AppCopy.text("agent.noMessage")) }
            var final = message
            final["type"] = .string("message")
            final["usage"] = .object(usage)
            final["content"] = .array(try blocks.keys.sorted().map { index in
                var block = blocks[index]!
                for (key, text) in streamed[index] ?? [:] {
                    block[key] = .string((block[key]?.string ?? "") + text)
                }
                if let json = arguments[index], !json.isEmpty {
                    block["input"] = try JSONCodec.parse(Data(json.utf8))
                }
                return .object(block)
            })
            if let diagnostics { final["diagnostics"] = diagnostics }
            return try NativeAgentClient.response(from: .object(final))
        }
    }

    static func anthropicResponseFromSSE(_ data: Data) throws -> AgentResponse {
        var state = AnthropicStreamState()
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
            try state.consume(line: line)
        }
        return try state.response()
    }

    /// One incremental piece of an assistant reply while the provider is still
    /// writing it. Only prose is worth showing early: tool calls, usage and the
    /// provider's opaque items stay inside the finished `AgentResponse`, because
    /// a half-parsed call would be a call the agent could not withdraw.
    public enum StreamDelta: Sendable, Equatable {
        case text(String)
        case thinking(String)
    }
    public typealias StreamDeltaHandler = @Sendable (StreamDelta) async -> Void

    /// The prose one Responses or Anthropic SSE line carries, for showing a
    /// reply while the buffered read is still collecting it.
    static func streamDelta(fromLine line: Data) -> StreamDelta? {
        guard isOutputDeltaLine(line),
              let event = try? JSONCodec.parse(Data(line.dropFirst(5))) else { return nil }
        let delta: StreamDelta?
        switch event["type"]?.string {
        case "response.output_text.delta": delta = event["delta"]?.string.map(StreamDelta.text)
        case "response.reasoning_text.delta": delta = event["delta"]?.string.map(StreamDelta.thinking)
        case "content_block_delta":
            delta = event["delta"]?["text"]?.string.map(StreamDelta.text)
                ?? event["delta"]?["thinking"]?.string.map(StreamDelta.thinking)
        default: delta = nil
        }
        switch delta {
        case .text(let value), .thinking(let value): return value.isEmpty ? nil : delta
        case nil: return nil
        }
    }

    /// What one SSE line adds while the reply is still being written: whether it
    /// carries model output at all (the first-token clock) and the prose in it.
    /// Responses and Anthropic name the event up front, so their lines are
    /// filtered by the head; chat-completions and Gemini chunks are small and
    /// are parsed whole.
    static func streamOutput(fromLine line: Data, api: String) -> (isOutput: Bool, deltas: [StreamDelta]) {
        guard line.starts(with: Data("data:".utf8)) else { return (false, []) }
        if api == RouterAPIKind.chatGPT.rawValue || api == RouterAPIKind.anthropic.rawValue {
            guard isOutputDeltaLine(line) else { return (false, []) }
            return (true, streamDelta(fromLine: line).map { [$0] } ?? [])
        }
        guard let event = try? JSONCodec.parse(Data(line.dropFirst(5))) else { return (false, []) }
        var deltas: [StreamDelta] = []
        if api == RouterAPIKind.geminiCLI.rawValue {
            guard case .array(let parts) = (event["response"] ?? event)["candidates"]?.firstObject?["content"]?["parts"] else {
                return (false, [])
            }
            for part in parts {
                guard let text = part["text"]?.string, !text.isEmpty else { continue }
                deltas.append(part["thought"]?.bool == true ? .thinking(text) : .text(text))
            }
            return (!parts.isEmpty, deltas)
        }
        guard let delta = event["choices"]?.firstObject?["delta"] else { return (false, []) }
        if let reasoning = delta["reasoning_content"]?.string ?? delta["reasoning"]?.string, !reasoning.isEmpty {
            deltas.append(.thinking(reasoning))
        }
        if let text = delta["content"]?.textBlocks(), !text.isEmpty { deltas.append(.text(text)) }
        if case .array = delta["tool_calls"] { return (true, deltas) }
        return (!deltas.isEmpty, deltas)
    }

    private static func sseEvents(_ data: Data) -> [JSONValue] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { return nil }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            return payload == "[DONE]" ? nil : try? JSONCodec.parse(Data(payload.utf8))
        }
    }

    private static func streamError(_ event: JSONValue) -> NativeAgentError? {
        guard let error = event["error"], error != .null else { return nil }
        let status = error["code"]?.int ?? error["status"]?.int ?? 502
        return NativeAgentError(
            error["message"]?.string ?? "The provider stream reported an error.",
            statusCode: status,
            retryable: isRetryable(status),
            isLimit: limitKind(from: event, status: status) != nil,
            isContextWindowExceeded: contextWindowOverflow(from: event)
        )
    }

    /// A streamed chat completion folded back into the buffered shape, so
    /// `response(from:)` stays the only reader of that wire format.
    static func chatCompletionFromSSE(_ data: Data) throws -> AgentResponse {
        var content = ""
        var reasoning = ""
        var calls: [(id: String, name: String, arguments: String)] = []
        var slots: [Int: Int] = [:]
        var finishReason: JSONValue?
        var usage: JSONValue?
        var sawChoice = false
        for event in sseEvents(data) {
            if let error = streamError(event) { throw error }
            if let value = event["usage"], value != .null { usage = value }
            guard let choice = event["choices"]?.firstObject else { continue }
            sawChoice = true
            if let reason = choice["finish_reason"], reason != .null { finishReason = reason }
            guard let delta = choice["delta"] else { continue }
            content += delta["content"]?.textBlocks() ?? ""
            reasoning += delta["reasoning_content"]?.string ?? delta["reasoning"]?.string ?? ""
            guard case .array(let items) = delta["tool_calls"] else { continue }
            for item in items {
                let index = item["index"]?.int ?? 0
                let id = item["id"]?.string ?? ""
                let name = item["function"]?["name"]?.string ?? ""
                let arguments = item["function"]?["arguments"]?.string ?? ""
                // Some gateways reuse index 0 for every call; a different id
                // on a taken index is a new call, not more of the old one.
                if let slot = slots[index], id.isEmpty || calls[slot].id.isEmpty || calls[slot].id == id {
                    if calls[slot].id.isEmpty { calls[slot].id = id }
                    calls[slot].name += name
                    calls[slot].arguments += arguments
                } else {
                    slots[index] = calls.count
                    calls.append((id, name, arguments))
                }
            }
        }
        guard sawChoice else { throw NativeAgentError(AppCopy.text("agent.noMessage")) }
        var message: JSONObject = ["content": .string(content)]
        if !reasoning.isEmpty { message["reasoning_content"] = .string(reasoning) }
        if !calls.isEmpty {
            message["tool_calls"] = .array(calls.map { call in
                var item: JSONObject = ["function": .object([
                    "name": .string(call.name),
                    "arguments": .string(call.arguments.isEmpty ? "{}" : call.arguments),
                ])]
                if !call.id.isEmpty { item["id"] = .string(call.id) }
                return .object(item)
            })
        }
        var choice: JSONObject = ["message": .object(message)]
        if let finishReason { choice["finish_reason"] = finishReason }
        var value: JSONObject = ["choices": .array([.object(choice)])]
        if let usage { value["usage"] = usage }
        return try response(from: .object(value))
    }

    /// `streamGenerateContent` chunks folded back into one `generateContent`
    /// reply for `geminiResponse(from:)`.
    static func geminiResponseFromSSE(_ data: Data) throws -> AgentResponse {
        var parts: [JSONValue] = []
        var usage: JSONValue?
        let proseKeys: Set<String> = ["text", "thought"]
        for event in sseEvents(data) {
            if let error = streamError(event) { throw error }
            let payload = event["response"] ?? event
            if let value = payload["usageMetadata"], value != .null { usage = value }
            guard case .array(let incoming) = payload["candidates"]?.firstObject?["content"]?["parts"] else { continue }
            for part in incoming {
                // Adjacent pieces of the same prose are one part: `geminiResponse`
                // puts a blank line between separate thinking parts.
                if let text = part["text"]?.string, let object = part.object, proseKeys.isSuperset(of: object.keys),
                   var last = parts.last?.object, let lastText = last["text"]?.string, proseKeys.isSuperset(of: last.keys),
                   (last["thought"]?.bool ?? false) == (object["thought"]?.bool ?? false) {
                    last["text"] = .string(lastText + text)
                    parts[parts.count - 1] = .object(last)
                } else {
                    parts.append(part)
                }
            }
        }
        guard !parts.isEmpty else { throw NativeAgentError(AppCopy.text("agent.noMessage")) }
        var value: JSONObject = ["candidates": .array([.object(["content": .object(["parts": .array(parts)])])])]
        if let usage { value["usageMetadata"] = usage }
        return try geminiResponse(from: .object(value))
    }

    /// The `/responses` event state machine, expressed one line at a time so the
    /// buffered read and the live read cannot drift apart.
    ///
    /// `responseFromSSE` feeds it every line it already has; the streaming
    /// transport feeds it each line as it arrives and shows what comes back.
    /// Both end at `response()`, so a streamed answer and a buffered one are the
    /// same `AgentResponse` by construction.
    struct ResponseStreamState {
        private var finalResponse: JSONValue?
        private var textAcc = ""
        private var thinkingAcc = ""
        private var callOrder: [String] = []
        private var calls: [String: (name: String, args: String)] = [:]
        private var providerItems: [JSONObject] = []
        /// Kept so the terminal payload can still be re-read by `response(from:)`
        /// on backends that ship `response.completed.output` instead of deltas.
        private var sawDeltaText = false

        /// Feed one physical line of the stream. Blank lines, `event:` fields and
        /// comment lines carry no state here, so they return nothing.
        mutating func consume(line rawLine: some StringProtocol) throws -> [StreamDelta] {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { return [] }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty, payload != "[DONE]" else { return [] }
            guard let event = try? JSONCodec.parse(Data(payload.utf8)) else { return [] }
            return try consume(event: event)
        }

        mutating func consume(event: JSONValue) throws -> [StreamDelta] {
            switch event["type"]?.string ?? "" {
            case "response.output_text.delta":
                let delta = event["delta"]?.string ?? ""
                textAcc += delta
                if delta.isEmpty { return [] }
                sawDeltaText = true
                return [.text(delta)]
            case "response.reasoning_text.delta":
                let delta = event["delta"]?.string ?? ""
                thinkingAcc += delta
                return delta.isEmpty ? [] : [.thinking(delta)]
            case "response.completed", "response.incomplete":
                finalResponse = event["response"]
                return []
            case "response.output_item.done":
                guard let item = event["item"]?.object else { return [] }
                providerItems.append(item)
                switch item["type"]?.string {
                case "function_call":
                    let id = item["call_id"]?.string ?? item["id"]?.string ?? UUID().uuidString
                    if calls[id] == nil { callOrder.append(id) }
                    calls[id] = (item["name"]?.string ?? "", item["arguments"]?.string ?? "{}")
                case "reasoning":
                    if case .array(let blocks) = item["content"] {
                        let contentThinking = blocks.compactMap { $0["text"]?.string }.joined()
                        if !contentThinking.isEmpty && thinkingAcc.isEmpty {
                            thinkingAcc = contentThinking
                        }
                    }
                case "message" where textAcc.isEmpty:
                    // No text deltas arrived (some models emit the message whole).
                    if case .array(let blocks) = item["content"] {
                        textAcc = blocks.compactMap { $0["text"]?.string }.joined()
                    }
                default:
                    break
                }
                return []
            case "response.failed", "error":
                let (message, status) = NativeAgentClient.streamFailure(in: event, fallback: "The Codex stream reported an error.")
                throw NativeAgentError(
                    message,
                    statusCode: status,
                    isLimit: NativeAgentClient.limitKind(from: event, status: status) != nil,
                    isContextWindowExceeded: NativeAgentClient.contextWindowOverflow(from: event)
                )
            default:
                return []
            }
        }

        /// The terminal answer. Call once the stream has ended.
        func response() throws -> AgentResponse {
            let items = NativeAgentClient.mergeResponsesOutputItems(
                streamed: providerItems,
                terminalOutput: finalResponse?["output"]
            )
            let toolCalls = callOrder.compactMap { id in
                calls[id].map { AgentToolCall(id: id, name: $0.name, arguments: $0.args) }
            }
            let usage = finalResponse?["usage"]?.object.map {
                AgentUsage(
                    inputTokens: $0["input_tokens"]?.int
                        ?? (($0["prompt_cache_hit_tokens"]?.int ?? 0) + ($0["prompt_cache_miss_tokens"]?.int ?? 0)),
                    outputTokens: $0["output_tokens"]?.int ?? 0,
                    cachedTokens: $0["input_tokens_details"]?["cached_tokens"]?.int
                        ?? $0["prompt_cache_hit_tokens"]?.int,
                    cacheWriteTokens: $0["input_tokens_details"]?["cache_write_tokens"]?.int,
                    cacheMissTokens: $0["prompt_cache_miss_tokens"]?.int,
                    reasoningTokens: $0["output_tokens_details"]?["reasoning_tokens"]?.int
                        ?? $0["completion_tokens_details"]?["reasoning_tokens"]?.int
                        ?? $0["reasoning_tokens"]?.int
                        ?? $0["thinking_tokens"]?.int
                )
            }

            if textAcc.isEmpty, toolCalls.isEmpty, items.isEmpty {
                // Nothing in the stream — fall back to the terminal payload for
                // backends that do populate `output` there.
                if let finalResponse, case .array(let output) = finalResponse["output"], !output.isEmpty {
                    return try NativeAgentClient.response(from: finalResponse)
                }
                if let reason = finalResponse?["incomplete_details"]?["reason"]?.string {
                    return AgentResponse(
                        message: AgentMessage(role: .assistant, content: ""),
                        usage: usage,
                        incompleteReason: reason
                    )
                }
                throw NativeAgentError(AppCopy.text("agent.noMessage"))
            }
            let media = items.flatMap {
                NativeAgentClient.mediaPayloads(from: JSONValue.object($0))
            }
            return AgentResponse(
                message: AgentMessage(
                    role: .assistant,
                    content: textAcc,
                    thinking: thinkingAcc.isEmpty ? nil : thinkingAcc,
                    toolCalls: toolCalls,
                    providerItems: items
                ),
                usage: usage,
                media: media,
                nativeCompactionApplied: items.contains { $0["type"]?.string == "compaction" },
                incompleteReason: finalResponse?["incomplete_details"]?["reason"]?.string,
                providerResponseID: finalResponse?["id"]?.string,
                cacheDiagnostics: AgentProviderCacheDiagnostics(value: finalResponse?["prompt_cache_diagnostics"])
            )
        }
    }

    /// `data(for:)` that also notes when the first SSE output delta arrived.
    static func dataTimingFirstDelta(
        for request: URLRequest,
        session: URLSession,
        api: String,
        onDelta: StreamDeltaHandler? = nil
    ) async throws -> (Data, URLResponse, Int?) {
        var collector = StreamCollector(api: api, onDelta: onDelta)
        let (bytes, response) = try await session.bytes(for: request)
        for try await line in bytes.lines { await collector.consume(line) }
        await collector.finish()
        return (collector.data, response, collector.firstDelta)
    }

    /// Buffers stream lines for the final parse, notes the first output delta and
    /// forwards deltas. Shared by the HTTP and WebSocket transports.
    struct StreamCollector {
        let api: String
        let onDelta: StreamDeltaHandler?
        let started = Date()
        private(set) var data = Data()
        private(set) var firstDelta: Int?
        // Each delta hopped to the main actor on its own, a job per token. Deltas are
        // sent in 50 ms batches instead, adjacent ones of a kind joined into one.
        private var pending: [StreamDelta] = []
        private var flushedAt = Date.distantPast

        init(api: String, onDelta: StreamDeltaHandler?) {
            self.api = api
            self.onDelta = onDelta
        }

        mutating func consume(_ line: String) async {
            let lineData = Data(line.utf8)
            data.append(contentsOf: lineData)
            data.append(0x0A)
            let output = NativeAgentClient.streamOutput(fromLine: lineData, api: api)
            if firstDelta == nil, output.isOutput {
                firstDelta = Int(Date().timeIntervalSince(started) * 1_000)
            }
            guard let onDelta else { return }
            pending.append(contentsOf: output.deltas)
            if !pending.isEmpty, Date().timeIntervalSince(flushedAt) >= 0.05 {
                for delta in NativeAgentClient.joinedDeltas(pending) { await onDelta(delta) }
                pending.removeAll(keepingCapacity: true)
                flushedAt = Date()
            }
        }

        mutating func finish() async {
            guard let onDelta else { return }
            for delta in NativeAgentClient.joinedDeltas(pending) { await onDelta(delta) }
            pending.removeAll()
        }
    }

    static func joinedDeltas(_ deltas: [StreamDelta]) -> [StreamDelta] {
        var joined: [StreamDelta] = []
        for delta in deltas {
            switch (joined.last, delta) {
            case (.text(let head)?, .text(let tail)): joined[joined.count - 1] = .text(head + tail)
            case (.thinking(let head)?, .thinking(let tail)): joined[joined.count - 1] = .thinking(head + tail)
            default: joined.append(delta)
            }
        }
        return joined
    }

    /// Responses (`response.*.delta`) and Anthropic (`content_block_delta`) put
    /// the event type first. Only the head is searched: `response.created`
    /// echoes the instructions, which may contain the word themselves.
    static func isOutputDeltaLine(_ line: Data) -> Bool {
        line.starts(with: Data("data:".utf8)) && line.prefix(96).range(of: Data("delta\"".utf8)) != nil
    }
}
