// Copyright (c) 2026 DOTS
// Provider request construction: OpenAI, Anthropic, Gemini and Responses bodies.

import Foundation
import HarnessPluginKit
import os
import PluginRuntime

extension NativeAgentClient {
    private static let prewarmedAt = OSAllocatedUnfairLock(initialState: [String: Date]())

    /// Open the provider connection before a prompt is sent, so the first
    /// request does not pay for DNS and the TLS handshake. Carries no
    /// credential and no prompt: a bare HEAD to the origin, on the session the
    /// real request reuses.
    static func prewarm(baseURL: String, session: URLSession = .shared) async {
        guard var components = URLComponents(string: baseURL), let host = components.host,
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else { return }
        components.path = "/"
        components.query = nil
        let key = "\(host):\(components.port ?? 0)"
        // ponytail: fixed 20 s window; idle keep-alive differs per provider, tune if a host drops sooner.
        let due = prewarmedAt.withLock { seen -> Bool in
            if let last = seen[key], Date().timeIntervalSince(last) < 20 { return false }
            seen[key] = Date()
            return true
        }
        guard due, let url = components.url else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        _ = try? await session.data(for: request)
    }

    func makeRequest(
        body: Data,
        accept: String,
        streaming: Bool = false,
        sessionKey: String? = nil,
        anthropicContextEditing: Bool = false
    ) throws -> URLRequest {
        guard let endpoint = endpoint(streaming: streaming) else { throw NativeAgentError(AppCopy.text("agent.invalidEndpoint")) }
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
            if configuration.fast && configuration.usageMode != .economy {
                request.setValue("fast-mode-2026-02-01", forHTTPHeaderField: "anthropic-beta")
            }
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
        if anthropicContextEditing {
            let existing = request.value(forHTTPHeaderField: "anthropic-beta") ?? ""
            var betas = existing.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !betas.contains("context-management-2025-06-27") {
                betas.append("context-management-2025-06-27")
            }
            request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = body
        return request
    }

    /// `streaming` only changes the Gemini method; the other transports ask for
    /// SSE in the body.
    func endpoint(streaming: Bool = false) -> URL? {
        // Code Assist methods hang off the base as `…/v1internal:generateContent`,
        // which is not a path segment — build it by string, not URLComponents.
        if configuration.api == RouterAPIKind.geminiCLI.rawValue {
            let base = configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return URL(string: base + (streaming ? ":streamGenerateContent?alt=sse" : ":generateContent"))
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
        cachePolicy: AgentCachePolicy,
        outputBudget: AgentOutputBudget? = nil
    ) -> [String: Any] {
        // Tool schemas are part of the provider prefix. Plugin discovery order
        // is not, so canonicalize it before every transport body is built.
        let canonicalTools = AgentCacheNamespace.canonicallySorted(tools)
        let providerMessages = AgentContextCompaction.providerContextMessages(messages)
        let replay = configuration.api == RouterAPIKind.chatGPT.rawValue
            ? AgentContextCompaction.responsesReplayMessages(providerMessages) : providerMessages
        let normalizedMessages = EconomyToolOutputPolicy.normalizeMessages(providerMessages)
        let normalizedReplay = EconomyToolOutputPolicy.normalizeMessages(replay)
        let messages = Self.foldingDynamicPrompt(into: normalizedReplay)
        let responseStyle = ResponseStyleResolver.resolve(
            preference: configuration.responseStylePreference,
            prompt: AgentMessage.responseStylePrompt(in: normalizedMessages)
        )
        // Keep model effort user-selected, but always bound the total output
        // tokens so a long reasoning response cannot consume the whole run.
        let budget = outputBudget ?? AgentOutputBudget.resolve(
            configuration: configuration,
            messages: normalizedMessages,
            tools: canonicalTools,
            decision: responseStyle
        )
        if configuration.api == RouterAPIKind.anthropic.rawValue {
            return makeAnthropicBody(messages: messages, tools: canonicalTools, budget: budget, cachePolicy: cachePolicy)
        }
        if configuration.api == RouterAPIKind.chatGPT.rawValue {
            return makeResponsesBody(messages: messages, tools: canonicalTools, cachePolicy: cachePolicy, budget: budget)
        }
        if configuration.api == RouterAPIKind.geminiCLI.rawValue {
            return makeGeminiBody(messages: messages, tools: canonicalTools, budget: budget)
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
        // same cache shard. Servers that reject the optional field are learned
        // by `complete`, so later turns avoid a failed probe.
        if let key = cachePolicy.promptCacheKey, !key.isEmpty {
            body["prompt_cache_key"] = key
        }
        if !canonicalTools.isEmpty {
            body["tools"] = canonicalTools.map { $0.jsonObject() }
            body["tool_choice"] = "auto"
        }
        if !configuration.effort.isEmpty {
            body["reasoning_effort"] = configuration.effort
        }
        body["max_tokens"] = budget.maxOutputTokens
        return body
    }

    private func makeAnthropicBody(
        messages: [AgentMessage],
        tools: [AgentToolDefinition],
        budget: AgentOutputBudget?,
        cachePolicy: AgentCachePolicy
    ) -> [String: Any] {
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
            "max_tokens": budget?.maxOutputTokens ?? Self.maxTokens(forEffort: configuration.effort),
            "messages": converted,
        ]
        if !EndpointCapabilityMemory.contextEditing.isUnsupported(for: configuration) {
            let triggerTokens = configuration.compactionPolicy.triggerTokens(window: configuration.contextWindow)
            body["context_management"] = [
                "edits": [[
                    "type": "clear_tool_uses_20250919",
                    "trigger": ["type": "input_tokens", "value": triggerTokens],
                    "keep": ["type": "tool_uses", "value": 3],
                    // A cleared read_file body would leave the read ledger vouching
                    // for bytes the model no longer sees.
                    "exclude_tools": ["read_file"],
                    "clear_at_least": [
                        "type": "input_tokens",
                        "value": max(1, min(8_192, triggerTokens / 4)),
                    ],
                ]],
            ]
        }
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
            } else if let budget, configuration.supportsLegacyThinkingBudget,
                      let reasoningBudget = budget.providerReasoningBudgetTokens {
                body["thinking"] = [
                    "type": "enabled",
                    "budget_tokens": reasoningBudget,
                ]
            } else if !configuration.supportsLegacyThinkingBudget, budget != nil {
                // New adaptive-thinking Claude models reject the legacy
                // `thinking.budget_tokens` field. Keep the user's selected
                // effort visible through the adaptive output_config surface.
                body["output_config"] = ["effort": configuration.effort]
            } else if budget == nil && configuration.supportsLegacyThinkingBudget {
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
            } else if budget == nil {
                // Capability metadata says this is not a legacy extended-
                // thinking model. Adaptive Claude models use effort/output_config
                // and must not receive thinking.budget_tokens.
                body["output_config"] = ["effort": configuration.effort]
            }
        }
        if configuration.fast && configuration.usageMode != .economy { body["speed"] = "fast" }
        let snapshot = AgentPromptCacheRequestSnapshot(body: body, configuration: configuration, requestStartedAt: Date())
        let prior = cachePolicy.priorBoundary.flatMap { boundary in
            boundary.accepted && snapshot.unchanged(boundary) ? boundary : nil
        }
        Self.applyAnthropicCacheBreakpoints(to: &body, stableSystemBlockIndex: stableSystemIndex,
            ttl: configuration.anthropicCacheTTL, priorBoundary: prior)
        if AgentPromptCacheComparisons.shared.supportsAnthropicDiagnostics(configuration) {
            let previousID = cachePolicy.comparisonResponseID ?? cachePolicy.priorBoundary?.providerResponseID
            body["diagnostics"] = ["previous_message_id": previousID.map { $0 as Any } ?? NSNull()]
        }
        return body
    }

    /// Capture context once in the canonical transcript, before persistence and
    /// the first request. Subsequent turns must retain the previous snapshot.
    /// makeBody also accepts legacy/direct callers with a dynamic system block.
    ///
    /// Only sections that differ from the copy this transcript last captured are
    /// written again: an unchanged rules file or skill list is not repeated on
    /// every turn. A section that went away is closed with a one-line marker.
    /// Earlier messages are never rewritten, and after compaction drops them the
    /// sections are simply captured in full again.
    static func foldingDynamicPrompt(into messages: [AgentMessage]) -> [AgentMessage] {
        let isDynamic: (AgentMessage) -> Bool = { $0.role == .system && $0.systemKind == .promptDynamic }
        let dynamic = messages.filter(isDynamic).map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let last = messages.lastIndex(where: { $0.role == .user }) else { return messages }
        var result = messages
        if !result[last].promptContextCaptured {
            let blocks = changedPromptSections(dynamic.joined(separator: "\n\n"), since: messages[..<last]) ?? dynamic
            result[last].content = (blocks + [result[last].content]).filter { !$0.isEmpty }.joined(separator: "\n\n")
            result[last].promptContextCaptured = true
        }
        return result.filter { !isDynamic($0) }
    }

    static func retiredPromptSection(_ tag: String) -> String {
        "<\(tag)>\nNo longer applies.\n</\(tag)>"
    }

    /// The `<tag>…</tag>` blocks a captured context starts with, in order, and
    /// whether they were the whole text. Section bodies cannot contain a section
    /// tag (`PromptSection.defuse`), so the first closing tag ends the block.
    static func leadingPromptSections(_ text: String) -> (sections: [(tag: String, block: String)], complete: Bool, rest: Substring) {
        // `<tag( trust="x")?>\n…\n</tag>`, scanned by hand: the equivalent Swift Regex
        // cost ~0.1 s per 30 KB captured turn, and this runs several times a step.
        var sections: [(tag: String, block: String)] = []
        var rest = Substring(text)
        while rest.first == "<", let close = rest.firstIndex(of: ">") {
            let opening = rest[rest.index(after: rest.startIndex)..<close]
            let tag = opening.prefix { $0 == "_" || ("a"..."z").contains($0) }
            let attribute = opening.dropFirst(tag.count)
            guard !tag.isEmpty,
                  attribute.isEmpty || Self.isTrustAttribute(attribute),
                  rest[close...].dropFirst().first == "\n",
                  let end = rest.range(of: "\n</\(tag)>", range: rest.index(close, offsetBy: 2)..<rest.endIndex) else { break }
            sections.append((String(tag), String(rest[..<end.upperBound])))
            rest = rest[end.upperBound...].drop(while: \.isNewline)
        }
        return (sections, rest.isEmpty, rest)
    }

    private static func isTrustAttribute(_ text: Substring) -> Bool {
        guard text.hasPrefix(" trust=\""), text.hasSuffix("\""), text.count > 9 else { return false }
        return text.dropFirst(8).dropLast().allSatisfy { ("a"..."z").contains($0) }
    }

    /// What each context section has cost this transcript. A section is captured
    /// again whenever its text changes and no copy is ever removed, so the copies
    /// are re-read on every later request: this is where a section that moves too
    /// often shows up. Largest first.
    static func promptSectionChurn(in messages: [AgentMessage]) -> [(tag: String, captures: Int, characters: Int)] {
        var totals: [String: (captures: Int, characters: Int)] = [:]
        for message in messages where message.role == .user && message.promptContextCaptured {
            for section in leadingPromptSections(message.content).sections {
                totals[section.tag, default: (0, 0)].captures += 1
                totals[section.tag, default: (0, 0)].characters += section.block.utf8.count
            }
        }
        return totals
            .map { (tag: $0.key, captures: $0.value.captures, characters: $0.value.characters) }
            .sorted { $0.characters != $1.characters ? $0.characters > $1.characters : $0.tag < $1.tag }
    }

    /// The Settings rendering of `promptSectionChurn`; empty for a fresh chat.
    static func promptSectionChurnReport(in messages: [AgentMessage]) -> String {
        let churn = promptSectionChurn(in: messages)
        guard !churn.isEmpty else { return "" }
        let total = churn.reduce(0) { $0 + $1.characters }
        return (["── captured into this conversation (every copy stays in history and is read again on each request)"]
            + churn.map { "<\($0.tag)> · \($0.captures)× · \($0.characters) chars · ~\(max(1, $0.characters / 4)) tokens" }
            + ["── total · \(total) chars · ~\(max(1, total / 4)) tokens"])
            .joined(separator: "\n")
    }

    /// nil when `dynamic` is not made of sections (a legacy or direct caller):
    /// the caller then captures it whole, as before.
    private static func changedPromptSections(_ dynamic: String, since history: ArraySlice<AgentMessage>) -> [String]? {
        let current = leadingPromptSections(dynamic)
        guard current.complete, !current.sections.isEmpty else { return nil }
        var copies: [String: [String]] = [:]
        for message in history where message.role == .user && message.promptContextCaptured {
            for section in leadingPromptSections(message.content).sections {
                copies[section.tag, default: []].append(section.block)
            }
        }
        let captured = copies.compactMapValues(\.last)
        let live = Set(current.sections.map(\.tag))
        let retired = captured.keys.sorted()
            .filter { !live.contains($0) && captured[$0] != retiredPromptSection($0) }
            .map(retiredPromptSection)
        return current.sections.compactMap { section in
            if section.tag == "task_history" { return taskHistoryAdditions(section.block, captured: copies[section.tag] ?? []) }
            return captured[section.tag] != section.block ? section.block : nil
        } + retired
    }

    static let taskHistoryAdditionsMarker =
        "(Additions to the task_history captured earlier in this conversation; its earlier entries still hold.)"
    static let taskHistoryBacklogMarker =
        "(Additions to the task_history captured earlier in this conversation; its earlier entries still hold, except the backlog below, which replaces the earlier one.)"

    /// task_history is recalled for each request, so its text moves every turn while
    /// most entries repeat. Only entries the transcript has not seen since its last
    /// full copy are captured. The backlog is state rather than recall: when it
    /// changed, the new backlog is captured whole (an empty one as "None") under a
    /// marker saying it replaces the earlier one. nil when nothing is new.
    static func taskHistoryAdditions(_ block: String, captured copies: [String]) -> String? {
        func body(_ block: String) -> [String] { Array(block.components(separatedBy: "\n").dropFirst().dropLast()) }
        // An entry is a line plus its indented continuation lines ("  Files: …").
        func entries(_ lines: [String]) -> [String] {
            var result: [String] = []
            for line in lines where !line.isEmpty {
                if line.hasPrefix(" "), !result.isEmpty { result[result.count - 1] += "\n" + line } else { result.append(line) }
            }
            return result
        }
        func backlogRange(_ entries: [String]) -> Range<Int> {
            guard let start = entries.firstIndex(where: { $0.hasPrefix("## Unfinished work") }) else { return entries.endIndex..<entries.endIndex }
            return start..<(entries[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? entries.endIndex)
        }
        func backlog(_ copy: String) -> [String] { let all = entries(body(copy)); return Array(all[backlogRange(all)]) }
        let none = ["## Unfinished work (backlog)", "- None"]
        let markers = [taskHistoryAdditionsMarker, taskHistoryBacklogMarker]
        guard copies.last != retiredPromptSection("task_history"),
              let base = copies.lastIndex(where: { !markers.contains(body($0).first ?? "") }) else { return block }
        // The backlog the transcript last stated: the full copy's, unless an addition replaced it.
        let stated = copies[(base + 1)...].map(backlog).last { !$0.isEmpty } ?? backlog(copies[base])
        var current = entries(body(block))
        let range = backlogRange(current)
        let currentBacklog = range.isEmpty ? none : Array(current[range])
        current.removeSubrange(range)
        let replaced = currentBacklog == (stated.isEmpty ? none : stated) ? [] : currentBacklog
        let seen = Set(copies[base...].flatMap { entries(body($0)) })
        var kept: [String] = []
        var heading: String?
        for entry in current {
            if entry.hasPrefix("## ") { heading = entry; continue }
            guard !seen.contains(entry) else { continue }
            if let pending = heading { kept.append(pending); heading = nil }
            kept.append(entry)
        }
        kept += replaced
        guard !kept.isEmpty else { return nil }
        let lines = block.components(separatedBy: "\n")
        let marker = replaced.isEmpty ? taskHistoryAdditionsMarker : taskHistoryBacklogMarker
        return ([lines[0], marker] + kept + [lines[lines.count - 1]]).joined(separator: "\n")
    }

    /// At most four distinct markers: tools, invariant system, last accepted
    /// request tail, and the current tail. The prior tail avoids the provider's
    /// backward-search window when a tool loop appends many content blocks.
    /// Everything before each breakpoint is
    /// served from the prompt cache on the next turn that keeps the same
    /// account (see RouterController conversation affinity). Below the model's
    /// minimum cacheable length Anthropic silently skips the cache, so sending
    /// this unconditionally is safe.
    static func applyAnthropicCacheBreakpoints(
        to body: inout [String: Any],
        stableSystemBlockIndex: Int? = nil,
        ttl: AgentPromptCacheTTL = .oneHour,
        priorBoundary: AgentPromptCacheBoundary? = nil
    ) {
        let ephemeral: [String: Any] = ["type": "ephemeral", "ttl": ttl.rawValue]

        switch body["system"] {
        case let text as String where !text.isEmpty:
            body["system"] = [["type": "text", "text": text, "cache_control": ephemeral]]
        case var blocks as [[String: Any]] where !blocks.isEmpty:
            for index in blocks.indices { blocks[index].removeValue(forKey: "cache_control") }
            let stable = stableSystemBlockIndex.flatMap { blocks.indices.contains($0) ? $0 : nil }
                ?? blocks.count - 1
            blocks[stable]["cache_control"] = ephemeral
            body["system"] = blocks
        default:
            break
        }

        if var tools = body["tools"] as? [[String: Any]], !tools.isEmpty {
            for index in tools.indices { tools[index].removeValue(forKey: "cache_control") }
            tools[tools.count - 1]["cache_control"] = ephemeral
            body["tools"] = tools
        }

        if var messages = body["messages"] as? [[String: Any]], !messages.isEmpty {
            for index in messages.indices {
                if var blocks = messages[index]["content"] as? [[String: Any]] {
                    for i in blocks.indices { blocks[i].removeValue(forKey: "cache_control") }
                    messages[index]["content"] = blocks
                }
            }
            func mark(_ messageIndex: Int, blockIndex: Int) {
                guard messages.indices.contains(messageIndex) else { return }
                if let text = messages[messageIndex]["content"] as? String, !text.isEmpty, blockIndex == 0 {
                    messages[messageIndex]["content"] = [["type": "text", "text": text, "cache_control": ephemeral]]
                } else if var blocks = messages[messageIndex]["content"] as? [[String: Any]],
                          blocks.indices.contains(blockIndex),
                          !["thinking", "redacted_thinking"].contains(blocks[blockIndex]["type"] as? String ?? "") {
                    blocks[blockIndex]["cache_control"] = ephemeral
                    messages[messageIndex]["content"] = blocks
                }
            }
            if let priorBoundary, let blockCount = priorBoundary.contentBlockCount {
                mark(priorBoundary.messageCount - 1, blockIndex: blockCount - 1)
            }
            if let last = messages.indices.reversed().first(where: {
                AgentPromptCacheRequestSnapshot.cacheableContentBlock(in: messages[$0]) != nil
            }), let block = AgentPromptCacheRequestSnapshot.cacheableContentBlock(in: messages[last]) {
                mark(last, blockIndex: block)
            }
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
    private func makeGeminiBody(
        messages: [AgentMessage],
        tools: [AgentToolDefinition],
        budget: AgentOutputBudget?
    ) -> [String: Any] {
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
        if !configuration.effort.isEmpty || budget != nil {
            var generation: [String: Any] = [:]
            if !configuration.effort.isEmpty {
                generation["thinkingConfig"] = ["thinkingLevel": configuration.effort]
            }
            if let budget { generation["maxOutputTokens"] = budget.maxOutputTokens }
            inner["generationConfig"] = generation
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
        cachePolicy: AgentCachePolicy,
        budget: AgentOutputBudget? = nil
    ) -> [String: Any] {
        // The Codex backend keeps `instructions` pinned to the Codex CLI prompt;
        // the caller's own system prompt rides along as a leading developer turn.
        let responseToolNames = ToolCloak.responsesNameMap(
            for: tools.map(\.name) + messages.flatMap { $0.toolCalls.map(\.name) }
        )
        let systemMessages = messages.filter {
            $0.role == .system && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let stableSystemMessages = systemMessages.filter { $0.systemKind == .promptStable }
        let changingSystemMessages = systemMessages.filter { $0.systemKind != .promptStable }
        let pinnedInstructions = configuration.transportSpec?.quirks.usesCodexInstructions == true
        let explicitStable = AgentPromptCacheComparisons.shared.supportsExplicitBreakpoint(configuration)
        var input: [[String: Any]] = []
        // Only worth a developer turn when `instructions` is pinned to the Codex
        // prompt; otherwise the system prompt is already the instructions.
        if explicitStable {
            input.append(contentsOf: stableSystemMessages.map { message in
                ["role": "developer", "content": [["type": "input_text", "text": message.content]]]
            })
            if !input.isEmpty, var content = input[input.count - 1]["content"] as? [[String: Any]], !content.isEmpty {
                content[content.count - 1]["prompt_cache_breakpoint"] = ["mode": "explicit"]
                input[input.count - 1]["content"] = content
            }
            input.append(contentsOf: changingSystemMessages.map { message in
                ["role": "developer", "content": [["type": "input_text", "text": message.content]]]
            })
        } else if pinnedInstructions {
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
                input.append(contentsOf: message.providerItems.map { item in
                    var wire = item.mapValues { $0.any }
                    if item["type"]?.string == "function_call",
                       let call = message.toolCalls.first(where: { $0.id == item["call_id"]?.string }) {
                        wire["name"] = responseToolNames[call.name] ?? call.name
                    }
                    return wire
                })
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
                    "name": responseToolNames[$0.name] ?? $0.name,
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
                : (explicitStable || stableSystemMessages.map(\.content).joined(separator: "\n\n").isEmpty
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
                "name": responseToolNames[$0.name] ?? $0.name,
                "description": $0.description,
                "parameters": $0.parameters.any,
            ] }
        }
        if !configuration.effort.isEmpty {
            body["reasoning"] = ["effort": configuration.effort]
        }
        if let budget {
            body["max_output_tokens"] = budget.maxOutputTokens
            // Low is the default output verbosity; an explicit Detailed preference
            // leaves the provider's default verbosity intact. Economy still forces low.
            if configuration.usageMode == .economy
                || configuration.responseStylePreference != .detailed {
                body["text"] = ["verbosity": "low"]
            }
        }
        if configuration.fast && configuration.usageMode != .economy { body["service_tier"] = "priority" }
        // Keys keep account/conversation accounting separate; newer models route automatically.
        if let key = cachePolicy.promptCacheKey, !key.isEmpty {
            body["prompt_cache_key"] = key
        }
        var cacheOptions: [String: Any] = [:]
        if AgentPromptCacheComparisons.shared.supportsImplicitOptions(configuration) {
            cacheOptions["mode"] = "implicit"
            cacheOptions["ttl"] = "30m"
        }
        if AgentPromptCacheComparisons.shared.supports(configuration), let comparison = cachePolicy.comparisonResponseID {
            cacheOptions["comparison_response_id"] = comparison
        }
        if !cacheOptions.isEmpty { body["prompt_cache_options"] = cacheOptions }
        if configuration.supportsNativeCompaction,
           !configuration.disableNativeCompactionForRequest,
           !EndpointCapabilityMemory.nativeCompaction.isUnsupported(for: configuration),
           configuration.api == RouterAPIKind.chatGPT.rawValue {
            let threshold = configuration.compactionPolicy.triggerTokens(window: configuration.contextWindow)
            body["context_management"] = [[
                "type": "compaction",
                "compact_threshold": threshold,
            ]]
        }
        return body
    }
}
