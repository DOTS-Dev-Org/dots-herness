// Copyright (c) 2026 DOTS
// Provider request construction: OpenAI, Anthropic, Gemini and Responses bodies.

import Foundation
import HarnessPluginKit
import PluginRuntime

extension NativeAgentClient {
    func makeRequest(body: Data, accept: String, sessionKey: String? = nil) throws -> URLRequest {
        guard let endpoint else { throw NativeAgentError(AppCopy.text("agent.invalidEndpoint")) }
        var request = URLRequest(url: endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let apiKey = configuration.apiKey, !apiKey.isEmpty {
            if configuration.api == RouterAPIKind.anthropic.rawValue && !configuration.isOAuth {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        if configuration.api == RouterAPIKind.geminiCLI.rawValue {
            // Cloud Code Assist identifies the caller by UA, and answers
            // `:generateContent` as plain JSON.
            request.setValue("GeminiCLI/0.34.0/\(configuration.model) (darwin; arm64; terminal)", forHTTPHeaderField: "User-Agent")
            request.setValue("google-genai-sdk/1.41.0 gl-node/v22.19.0", forHTTPHeaderField: "X-Goog-Api-Client")
        } else if configuration.api == RouterAPIKind.anthropic.rawValue {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if configuration.fast { request.setValue("fast-mode-2026-02-01", forHTTPHeaderField: "anthropic-beta") }
        } else if configuration.api == RouterAPIKind.chatGPT.rawValue {
            // The Responses transport is shared (Codex, Grok CLI, …); only the
            // ChatGPT backend binds requests to an account id.
            if configuration.transportSpec?.quirks.requiresSessionAccountID == true {
                guard let accountID = configuration.sessionAccountID, !accountID.isEmpty else {
                    throw NativeAgentError("The GPT session account is unavailable.")
                }
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
                request.setValue("codex", forHTTPHeaderField: "OAI-Product-Sku")
                request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
            }
            // The backend routes its prompt cache by session, so a fresh id per
            // request would land every turn on a cold shard. Reuse the
            // conversation's cache key; only one-off calls get a random id.
            let sessionID = sessionKey.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            request.setValue(sessionID, forHTTPHeaderField: "session-id")
            request.setValue(sessionID, forHTTPHeaderField: "thread-id")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "x-client-request-id")
        }
        // Registry-supplied transport headers are applied last so a provider
        // spec can override the defaults above.
        for (key, value) in configuration.transportSpec?.extraHeaders ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body
        return request
    }

    var endpoint: URL? {
        // Code Assist methods hang off the base as `…/v1internal:generateContent`,
        // which is not a path segment — build it by string, not URLComponents.
        if configuration.api == RouterAPIKind.geminiCLI.rawValue {
            let base = configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return URL(string: base + ":generateContent")
        }
        guard var components = URLComponents(string: configuration.baseURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else { return nil }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basePath = path.isEmpty
            ? (configuration.api == RouterAPIKind.chatGPT.rawValue ? "" : "/v1")
            : "/\(path)"
        if configuration.api == RouterAPIKind.anthropic.rawValue {
            components.path = basePath + "/messages"
        } else if configuration.api == RouterAPIKind.chatGPT.rawValue {
            components.path = basePath + "/responses"
        } else {
            components.path = basePath + "/chat/completions"
        }
        if let suffix = configuration.transportSpec?.urlSuffix, !suffix.isEmpty {
            components.percentEncodedQuery = suffix.hasPrefix("?") ? String(suffix.dropFirst()) : suffix
        }
        return components.url
    }

    func makeBody(
        messages: [AgentMessage],
        tools: [AgentToolDefinition],
        cachePolicy: AgentCachePolicy
    ) -> [String: Any] {
        let messages = Self.foldingDynamicPrompt(into: messages)
        if configuration.api == RouterAPIKind.anthropic.rawValue {
            return makeAnthropicBody(messages: messages, tools: tools)
        }
        if configuration.api == RouterAPIKind.chatGPT.rawValue {
            return makeResponsesBody(messages: messages, tools: tools, cachePolicy: cachePolicy)
        }
        if configuration.api == RouterAPIKind.geminiCLI.rawValue {
            return makeGeminiBody(messages: messages, tools: tools)
        }
        var wireMessages: [[String: Any]] = []
        for message in messages {
            wireMessages.append(message.jsonObject())
            if message.role == .tool, !message.attachments.isEmpty {
                wireMessages.append([
                    "role": "user",
                    "content": message.openAIContent(),
                ])
            }
        }
        var body: [String: Any] = ["model": configuration.model, "messages": wireMessages, "temperature": 0.2]
        // OpenAI-compatible: `prompt_cache_key` routes repeat prefixes to the
        // same cache shard. Servers that don't implement the field ignore it;
        // `complete` retries without it for the few that reject it.
        if let key = cachePolicy.promptCacheKey, !key.isEmpty {
            body["prompt_cache_key"] = key
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { $0.jsonObject() }
            body["tool_choice"] = "auto"
        }
        if !configuration.effort.isEmpty {
            body["reasoning_effort"] = configuration.effort
        }
        return body
    }

    private func makeAnthropicBody(messages: [AgentMessage], tools: [AgentToolDefinition]) -> [String: Any] {
        let systemMessages = messages.filter {
            $0.role == .system && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let converted = messages.filter { $0.role != .system }.map { message -> [String: Any] in
            if message.role == .tool {
                let resultContent: Any = message.attachments.isEmpty
                    ? message.content
                    : message.anthropicContent()
                return [
                    "role": "user",
                    "content": [["type": "tool_result", "tool_use_id": message.toolCallID ?? "tool", "content": resultContent]],
                ]
            }
            var content: Any = [["type": "text", "text": message.content]]
            if !message.attachments.isEmpty { content = message.anthropicContent() }
            if message.role == .assistant && !message.toolCalls.isEmpty {
                var blocks: [[String: Any]] = []
                if !message.providerItems.isEmpty {
                    blocks = message.providerItems.map { $0.mapValues { $0.any } }
                } else {
                    if let thinking = message.thinking, !thinking.isEmpty {
                        blocks.append(["type": "thinking", "thinking": thinking, "signature": ""])
                    }
                    if !message.content.isEmpty {
                        blocks.append(["type": "text", "text": message.content])
                    }
                    blocks.append(contentsOf: message.toolCalls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": Self.jsonObject(from: $0.arguments)] })
                }
                content = blocks
            }
            return ["role": message.role == .assistant ? "assistant" : "user", "content": content]
        }
        // High effort spends most of the budget on reasoning before it writes a
        // word, so a fixed 4096 ceiling can end a request with thinking only and
        // no answer. Scale the ceiling with the requested depth.
        var body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": Self.maxTokens(forEffort: configuration.effort),
            "messages": converted,
        ]
        let quirks = configuration.transportSpec?.quirks
        let identity = quirks?.injectAgentIdentity.flatMap { configuration.isOAuth ? $0 : nil }
        var systemBlocks: [[String: Any]] = []
        if let identity { systemBlocks.append(["type": "text", "text": identity]) }
        systemBlocks.append(contentsOf: systemMessages.map { ["type": "text", "text": $0.content] })
        let stableSystemIndex = systemMessages.firstIndex { $0.systemKind == .promptStable }
            .map { $0 + (identity == nil ? 0 : 1) }
        // OAuth (subscription) tokens require Claude Code's identity as the first
        // system block, otherwise Anthropic rejects the request.
        if !systemBlocks.isEmpty {
            // Keep the stable prompt and changing workspace data as separate
            // cache segments. This also preserves the exact OAuth identity as
            // the first system block.
            body["system"] = systemBlocks
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters.any] }
        }
        ToolCloak.apply(to: &body, cloak: quirks?.cloakToolsOnOAuth == true && configuration.isOAuth)
        if !configuration.effort.isEmpty {
            if configuration.isOAuth {
                body["output_config"] = ["effort": configuration.effort]
            } else {
                let budget: Int = {
                    switch configuration.effort {
                    case "max": return 32_000
                    case "xhigh": return 24_000
                    case "high": return 16_000
                    case "medium": return 8_000
                    case "low": return 2_048
                    default: return 2_048
                    }
                }()
                body["thinking"] = ["type": "enabled", "budget_tokens": budget]
            }
        }
        if configuration.fast { body["speed"] = "fast" }
        Self.applyAnthropicCacheBreakpoints(to: &body, stableSystemBlockIndex: stableSystemIndex)
        return body
    }

    /// Capture context once in the canonical transcript, before persistence and
    /// the first request. Subsequent turns must retain the previous snapshot.
    /// makeBody also accepts legacy/direct callers with a dynamic system block.
    static func foldingDynamicPrompt(into messages: [AgentMessage]) -> [AgentMessage] {
        let isDynamic: (AgentMessage) -> Bool = { $0.role == .system && $0.systemKind == .promptDynamic }
        let dynamic = messages.filter(isDynamic).map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let last = messages.lastIndex(where: { $0.role == .user }) else { return messages }
        var result = messages
        if !result[last].promptContextCaptured {
            result[last].content = (dynamic + [result[last].content]).filter { !$0.isEmpty }.joined(separator: "\n\n")
            result[last].promptContextCaptured = true
        }
        return result.filter { !isDynamic($0) }
    }

    /// Marks the reused prefix of an Anthropic request as cacheable: one
    /// `cache_control` breakpoint on the last system block, one on the last
    /// tool, one on the last message. Everything before each breakpoint is
    /// served from the prompt cache on the next turn that keeps the same
    /// account (see RouterController conversation affinity). Below the model's
    /// minimum cacheable length Anthropic silently skips the cache, so sending
    /// this unconditionally is safe.
    static func applyAnthropicCacheBreakpoints(
        to body: inout [String: Any],
        stableSystemBlockIndex: Int? = nil
    ) {
        let ephemeral: [String: Any] = ["type": "ephemeral"]

        switch body["system"] {
        case let text as String where !text.isEmpty:
            body["system"] = [["type": "text", "text": text, "cache_control": ephemeral]]
        case var blocks as [[String: Any]] where !blocks.isEmpty:
            if let stableSystemBlockIndex,
               blocks.indices.contains(stableSystemBlockIndex) {
                blocks[stableSystemBlockIndex]["cache_control"] = ephemeral
            }
            blocks[blocks.count - 1]["cache_control"] = ephemeral
            body["system"] = blocks
        default:
            break
        }

        if var tools = body["tools"] as? [[String: Any]], !tools.isEmpty {
            tools[tools.count - 1]["cache_control"] = ephemeral
            body["tools"] = tools
        }

        if var messages = body["messages"] as? [[String: Any]], !messages.isEmpty {
            let last = messages.count - 1
            var message = messages[last]
            switch message["content"] {
            case let text as String where !text.isEmpty:
                message["content"] = [["type": "text", "text": text, "cache_control": ephemeral]]
            case var blocks as [[String: Any]] where !blocks.isEmpty:
                blocks[blocks.count - 1]["cache_control"] = ephemeral
                message["content"] = blocks
            default:
                break
            }
            messages[last] = message
            body["messages"] = messages
        }
    }

    /// Cloud Code Assist envelope: `{project, model, request}` where `request` is
    /// an ordinary Gemini `generateContent` payload.
    // ponytail: no explicit `cachedContent` — that field needs a CachedContent
    // resource created up front by a separate `cachedContents` POST and refreshed
    // on a TTL, which the router does not manage. Gemini 2.5 implicit caching
    // already discounts a repeated prefix automatically, so the affinity pin
    // still pays off here. Upgrade path: a CachedContentStore keyed like
    // AgentBridge.cacheKey, creating/reusing a resource per project+model.
    private func makeGeminiBody(messages: [AgentMessage], tools: [AgentToolDefinition]) -> [String: Any] {
        var contents: [[String: Any]] = []
        for message in messages where message.role != .system {
            switch message.role {
            case .tool:
                var parts: [[String: Any]] = [["functionResponse": [
                    "name": message.toolCallID ?? "tool",
                    "response": ["result": message.content],
                ]]]
                if !message.attachments.isEmpty {
                    parts.append(contentsOf: message.geminiParts())
                }
                contents.append([
                    "role": "user",
                    "parts": parts,
                ])
            case .assistant:
                var parts: [[String: Any]] = []
                if !message.content.isEmpty { parts.append(["text": message.content]) }
                for call in message.toolCalls {
                    parts.append(["functionCall": ["name": call.name, "args": Self.jsonObject(from: call.arguments)]])
                }
                contents.append(["role": "model", "parts": parts.isEmpty ? [["text": ""]] : parts])
            default:
                contents.append(["role": "user", "parts": message.geminiParts()])
            }
        }

        var inner: [String: Any] = ["contents": contents]
        let systemMessages = messages.filter {
            $0.role == .system && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !systemMessages.isEmpty {
            inner["systemInstruction"] = [
                "role": "user",
                "parts": systemMessages.map { ["text": $0.content] },
            ]
        }
        if !tools.isEmpty {
            inner["tools"] = [["functionDeclarations": tools.map { tool -> [String: Any] in
                ["name": tool.name, "description": tool.description, "parameters": tool.parameters.any]
            }]]
        }
        if !configuration.effort.isEmpty {
            inner["generationConfig"] = ["thinkingConfig": ["thinkingLevel": configuration.effort]]
        }
        var body: [String: Any] = ["model": configuration.model, "request": inner]
        // The project id is discovered once at sign-in and stored on the account.
        if let project = configuration.sessionAccountID, !project.isEmpty { body["project"] = project }
        if configuration.transportSpec?.quirks.antigravityEnvelope == true {
            body["userAgent"] = "antigravity"
            body["requestType"] = "agent"
            body["requestId"] = UUID().uuidString
        }
        return body
    }

    func makeResponsesBody(
        messages: [AgentMessage],
        tools: [AgentToolDefinition],
        cachePolicy: AgentCachePolicy
    ) -> [String: Any] {
        // The Codex backend keeps `instructions` pinned to the Codex CLI prompt;
        // the caller's own system prompt rides along as a leading developer turn.
        let systemMessages = messages.filter {
            $0.role == .system && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let stableSystemMessages = systemMessages.filter { $0.systemKind == .promptStable }
        let changingSystemMessages = systemMessages.filter { $0.systemKind != .promptStable }
        let pinnedInstructions = configuration.transportSpec?.quirks.usesCodexInstructions == true
        var input: [[String: Any]] = []
        // Only worth a developer turn when `instructions` is pinned to the Codex
        // prompt; otherwise the system prompt is already the instructions.
        if pinnedInstructions {
            input.append(contentsOf: systemMessages.map { message in
                ["role": "developer", "content": [["type": "input_text", "text": message.content]]]
            })
        } else {
            // Keep changing workspace/project data after the stable instructions
            // so it does not rewrite the reusable prefix on every turn.
            input.append(contentsOf: changingSystemMessages.map { message in
                ["role": "developer", "content": [["type": "input_text", "text": message.content]]]
            })
        }
        for message in messages where message.role != .system {
            if !message.providerItems.isEmpty {
                input.append(contentsOf: message.providerItems.map { item in item.mapValues { $0.any } })
            } else if message.role == .tool {
                input.append(["type": "function_call_output", "call_id": message.toolCallID ?? "tool", "output": message.content])
                if !message.attachments.isEmpty {
                    // The function output remains a normal text result. The
                    // bytes are a separate provider-only user input, keeping
                    // the canonical tool transcript and the Responses wire
                    // contract both valid.
                    input.append(["role": "user", "content": message.responsesContent()])
                }
            } else if message.role == .assistant && !message.toolCalls.isEmpty {
                if !message.content.isEmpty {
                    input.append(["role": "assistant", "content": [["type": "output_text", "text": message.content]]])
                }
                input.append(contentsOf: message.toolCalls.map { [
                    "type": "function_call",
                    "call_id": $0.id,
                    "name": $0.name,
                    "arguments": $0.arguments,
                ] })
            } else {
                let role = message.role == .assistant ? "assistant" : "user"
                let content: [[String: Any]]
                if role == "assistant" {
                    content = [["type": "output_text", "text": message.content]]
                } else if message.attachments.isEmpty {
                    content = [["type": "input_text", "text": message.content]]
                } else {
                    content = message.responsesContent()
                }
                input.append(["role": role, "content": content])
            }
        }
        var body: [String: Any] = [
            "model": configuration.model,
            "instructions": configuration.transportSpec?.quirks.usesCodexInstructions == true
                ? CodexInstructions.default
                : (stableSystemMessages.map(\.content).joined(separator: "\n\n").isEmpty
                    ? "You are a helpful assistant."
                    : stableSystemMessages.map(\.content).joined(separator: "\n\n")),
            "input": input,
            "store": false,
            // The ChatGPT/Codex backend only serves `/responses` as SSE; a
            // non-streaming request is rejected with HTTP 400.
            "stream": true,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { [
                "type": "function",
                "name": $0.name,
                "description": $0.description,
                "parameters": $0.parameters.any,
            ] }
        }
        if !configuration.effort.isEmpty {
            body["reasoning"] = ["effort": configuration.effort]
        }
        if configuration.fast { body["service_tier"] = "priority" }
        // Responses honours `prompt_cache_key` the same way Chat Completions
        // does: a stable value keeps repeat prefixes on one cache shard.
        if let key = cachePolicy.promptCacheKey, !key.isEmpty {
            body["prompt_cache_key"] = key
        }
        if configuration.supportsNativeCompaction,
           configuration.api == RouterAPIKind.chatGPT.rawValue {
            body["context_management"] = [[
                "type": "compaction",
                "compact_threshold": configuration.compactionPolicy.triggerTokens(window: configuration.contextWindow),
            ]]
        }
        return body
    }
}
