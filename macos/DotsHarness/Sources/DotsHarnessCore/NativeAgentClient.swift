// Copyright (c) 2026 DOTS
// OpenAI-compatible transport used by the native agent loop.

import Foundation
import HarnessPluginKit
import PluginRuntime

/// Remembers an endpoint that explicitly rejected an optional request field so
/// a compatible route does not pay for the same failed request on every turn.
/// This is process-local capability memory, not prompt or credential storage.
final class EndpointCapabilityMemory: @unchecked Sendable {
    static let promptCache = EndpointCapabilityMemory()
    static let streamUsage = EndpointCapabilityMemory()
    static let nativeCompaction = EndpointCapabilityMemory()
    static let contextEditing = EndpointCapabilityMemory()

    private let lock = NSLock()
    private var unsupportedEndpoints = Set<String>()

    func isUnsupported(for configuration: AgentConfiguration) -> Bool {
        let key = Self.key(for: configuration)
        lock.lock()
        defer { lock.unlock() }
        return unsupportedEndpoints.contains(key)
    }

    func markUnsupported(for configuration: AgentConfiguration) {
        let key = Self.key(for: configuration)
        lock.lock()
        unsupportedEndpoints.insert(key)
        lock.unlock()
    }

    private static func key(for configuration: AgentConfiguration) -> String {
        configuration.api + "|" + configuration.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

public struct NativeAgentClient: Sendable {
    public var configuration: AgentConfiguration
    var session: URLSession

    public init(configuration: AgentConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func complete(
        messages: [AgentMessage],
        tools: [AgentToolDefinition] = [],
        cachePolicy: AgentCachePolicy = AgentCachePolicy(),
        onDelta: StreamDeltaHandler? = nil
    ) async throws -> AgentResponse {
        return try await complete(
            messages: messages,
            tools: tools,
            cachePolicy: cachePolicy,
            outputBudget: nil,
            retryCount: 0,
            onDelta: onDelta
        )
    }

    private func complete(
        messages: [AgentMessage],
        tools: [AgentToolDefinition],
        cachePolicy: AgentCachePolicy,
        outputBudget: AgentOutputBudget?,
        retryCount: Int,
        onDelta: StreamDeltaHandler? = nil
    ) async throws -> AgentResponse {
        if configuration.api == RouterAPIKind.claudeCLI.rawValue {
            return try await ClaudeCLIClient.complete(messages: messages, configuration: configuration,
                                                      workspace: AgentRunScope.workspace, onDelta: onDelta)
        }
        if configuration.api == RouterAPIKind.anthropic.rawValue,
           configuration.anthropicCacheTTL == .oneHour,
           !AgentPromptCacheComparisons.shared.supportsLongTTL(configuration) {
            var fallback = self
            fallback.configuration.anthropicCacheTTL = .fiveMinutes
            return try await fallback.complete(messages: messages, tools: tools, cachePolicy: cachePolicy,
                                               outputBudget: outputBudget, retryCount: retryCount, onDelta: onDelta)
        }
        let responseStyle = ResponseStyleResolver.resolve(
            preference: configuration.responseStylePreference,
            prompt: AgentMessage.responseStylePrompt(in: messages)
        )
        // Every request gets an output ceiling, including Standard mode. A
        // maximum reasoning setting without max_output_tokens can otherwise
        // spend the entire remaining context window on one response.
        let effectiveBudget = outputBudget ?? AgentOutputBudget.resolve(
            configuration: configuration,
            messages: messages,
            tools: tools,
            decision: responseStyle
        )
        var effectiveCachePolicy = cachePolicy
        if EndpointCapabilityMemory.promptCache.isUnsupported(for: configuration) {
            effectiveCachePolicy.promptCacheKey = nil
        }
        // The cache key is shared by conversations; boundaries are per conversation.
        let boundaryScope = cachePolicy.comparisonScope ?? cachePolicy.promptCacheKey
        effectiveCachePolicy.priorBoundary = cachePolicy.priorBoundary
            ?? AgentPromptCacheComparisons.shared.previousBoundary(configuration, key: boundaryScope)
        if AgentPromptCacheComparisons.shared.supports(configuration) {
            effectiveCachePolicy.comparisonResponseID = cachePolicy.comparisonResponseID
                ?? AgentPromptCacheComparisons.shared.previous(configuration, key: cachePolicy.comparisonScope ?? cachePolicy.promptCacheKey)
        } else {
            effectiveCachePolicy.comparisonResponseID = nil
        }
        if AgentPromptCacheComparisons.shared.supportsAnthropicDiagnostics(configuration) {
            effectiveCachePolicy.comparisonResponseID = cachePolicy.comparisonResponseID
                ?? effectiveCachePolicy.priorBoundary?.providerResponseID
                ?? AgentPromptCacheComparisons.shared.previous(configuration, key: cachePolicy.comparisonScope ?? cachePolicy.promptCacheKey)
        }
        var body = makeBody(
            messages: messages,
            tools: tools,
            cachePolicy: effectiveCachePolicy,
            outputBudget: effectiveBudget
        )
        let cacheSnapshot = AgentPromptCacheRequestSnapshot(body: body, configuration: configuration, requestStartedAt: Date())
        // Only a caller that shows the reply as it is written asks for SSE; the
        // finished stream is folded back into a buffered reply below. Responses
        // always streams, so it needs no flag here.
        let api = configuration.api
        let streamsAnthropic = onDelta != nil && api == RouterAPIKind.anthropic.rawValue
        let streamsGemini = onDelta != nil && api == RouterAPIKind.geminiCLI.rawValue
        let streamsChat = onDelta != nil && !streamsAnthropic && !streamsGemini && api != RouterAPIKind.chatGPT.rawValue
        if streamsAnthropic || streamsChat { body["stream"] = true }
        // Without this a streamed chat completion carries no usage at all.
        if streamsChat, !EndpointCapabilityMemory.streamUsage.isUnsupported(for: configuration) {
            body["stream_options"] = ["include_usage": true]
        }
        // Prompt caches match the prefix byte for byte; sorted keys keep tool
        // schemas identical across requests and app restarts.
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys) else {
            throw NativeAgentError(AppCopy.text("agent.encodeRequestFailed"))
        }

        let request = try makeRequest(
            body: data,
            accept: api == RouterAPIKind.chatGPT.rawValue || streamsAnthropic || streamsGemini ? "text/event-stream" : "application/json",
            streaming: streamsGemini,
            // ChatGPT's session routing remains useful even if this endpoint
            // rejects the optional JSON field; only suppress the body hint.
            sessionKey: configuration.api == RouterAPIKind.chatGPT.rawValue
                ? cachePolicy.promptCacheKey
                : effectiveCachePolicy.promptCacheKey,
            anthropicContextEditing: api == RouterAPIKind.anthropic.rawValue
                && body["context_management"] != nil
        )

        // One more attempt after an optional request field was marked unsupported.
        func retry(_ cachePolicy: AgentCachePolicy) async throws -> AgentResponse {
            try await complete(messages: messages, tools: tools, cachePolicy: cachePolicy,
                               outputBudget: outputBudget, retryCount: retryCount, onDelta: onDelta)
        }

        do {
            let (responseData, response, firstTokenMilliseconds) = try await streamedData(
                for: request, body: body, cachePolicy: cachePolicy, onDelta: onDelta)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let value = (try? JSONCodec.parse(responseData)) ?? .null
            guard (200..<300).contains(status) else {
                let message = Self.errorMessage(from: value, status: status)
                let imageUnsupported = messages.contains { message in
                    message.attachments.contains { $0.kind == .image }
                }
                    && VisionProviderCapability.isImageInputUnsupported(
                        message: message,
                        statusCode: status
                    )
                // Classify this before the Responses compaction fallback. An
                // image-capability failure is a provider decision, not a
                // malformed compaction request, and must not cause a second
                // image-bearing request before Vision gets a chance to run.
                if imageUnsupported {
                    throw NativeAgentError(
                        message,
                        statusCode: status,
                        retryable: Self.isRetryable(status),
                        isImageInputUnsupported: true
                    )
                }
                // `prompt_cache_key` goes to every OpenAI-style route; a strict
                // server that rejects unknown fields gets one fallback request,
                // then the endpoint stays in the process-local unsupported set.
                let lowerMessage = message.lowercased()
                    + " " + (value["error"]?["param"]?.string ?? "").lowercased()
                if [400, 422].contains(status),
                   lowerMessage.contains("prompt_cache_breakpoint"),
                   AgentPromptCacheComparisons.shared.supportsExplicitBreakpoint(configuration) {
                    AgentPromptCacheComparisons.shared.rejectExplicitBreakpoint(configuration)
                    return try await retry(cachePolicy)
                }
                if [400, 422].contains(status), body["stream_options"] != nil, lowerMessage.contains("stream_options") {
                    EndpointCapabilityMemory.streamUsage.markUnsupported(for: configuration)
                    return try await retry(cachePolicy)
                }
                if [400, 422].contains(status), configuration.api == RouterAPIKind.anthropic.rawValue,
                   body["diagnostics"] != nil,
                   (lowerMessage.contains("diagnostics") || lowerMessage.contains("previous_message_id")) {
                    AgentPromptCacheComparisons.shared.rejectAnthropicDiagnostics(configuration)
                    return try await retry(cachePolicy)
                }
                if [400, 422].contains(status), body["prompt_cache_options"] != nil,
                   (lowerMessage.contains("prompt_cache_options") || lowerMessage.contains("comparison_response_id")) {
                    if lowerMessage.contains("comparison_response_id") {
                        AgentPromptCacheComparisons.shared.reject(configuration)
                    } else if lowerMessage.contains(".ttl") || lowerMessage.contains(".mode") {
                        AgentPromptCacheComparisons.shared.rejectImplicitOptions(configuration)
                    } else {
                        AgentPromptCacheComparisons.shared.reject(configuration)
                        AgentPromptCacheComparisons.shared.rejectImplicitOptions(configuration)
                    }
                    var fallbackPolicy = cachePolicy
                    if !AgentPromptCacheComparisons.shared.supports(configuration) {
                        fallbackPolicy.comparisonResponseID = nil
                    }
                    return try await retry(fallbackPolicy)
                }
                if [400, 422].contains(status), configuration.api == RouterAPIKind.anthropic.rawValue,
                   configuration.anthropicCacheTTL == .oneHour,
                   message.lowercased().contains("ttl") {
                    AgentPromptCacheComparisons.shared.rejectLongTTL(configuration)
                    var fallback = self
                    fallback.configuration.anthropicCacheTTL = .fiveMinutes
                    return try await fallback.complete(messages: messages, tools: tools, cachePolicy: cachePolicy,
                                                       outputBudget: outputBudget, retryCount: retryCount, onDelta: onDelta)
                }
                if [400, 422].contains(status),
                   body["prompt_cache_key"] != nil,
                   message.lowercased().contains("prompt_cache_key") {
                    EndpointCapabilityMemory.promptCache.markUnsupported(for: configuration)
                    return try await retry(cachePolicy)
                }
                if [400, 422].contains(status),
                   api == RouterAPIKind.anthropic.rawValue,
                   body["context_management"] != nil,
                   Self.isAnthropicContextEditingRejection(message) {
                    EndpointCapabilityMemory.contextEditing.markUnsupported(for: configuration)
                    return try await retry(cachePolicy)
                }
                if [400, 422].contains(status),
                   configuration.supportsNativeCompaction,
                   Self.isNativeCompactionRejection(message) {
                    EndpointCapabilityMemory.nativeCompaction.markUnsupported(for: configuration)
                    var fallback = configuration
                    fallback.supportsNativeCompaction = false
                    var result = try await NativeAgentClient(configuration: fallback, session: session).complete(
                        messages: messages,
                        tools: tools,
                        cachePolicy: cachePolicy,
                        onDelta: onDelta
                    )
                    result.nativeCompactionFallback = true
                    return result
                }
                throw NativeAgentError(
                    message,
                    statusCode: status,
                    retryable: Self.isRetryable(status),
                    isLimit: Self.limitKind(from: value, status: status) != nil,
                    retryAt: NativeAgentError.retryAt(from: response),
                    isContextWindowExceeded: Self.contextWindowOverflow(from: value)
                )
            }
            var result: AgentResponse
            if configuration.api == RouterAPIKind.chatGPT.rawValue {
                // Public Responses endpoints and compatible gateways may return
                // either the normal JSON response or a completed SSE stream.
                result = value["output"] != nil ? try Self.response(from: value) : try Self.responseFromSSE(responseData)
            } else if value != JSONValue.null || responseData.range(of: Data("data:".utf8)) == nil {
                // Asked to stream or not, an endpoint may still answer with one JSON body.
                result = api == RouterAPIKind.geminiCLI.rawValue ? try Self.geminiResponse(from: value) : try Self.response(from: value)
            } else if api == RouterAPIKind.geminiCLI.rawValue {
                result = try Self.geminiResponseFromSSE(responseData)
            } else if api == RouterAPIKind.anthropic.rawValue {
                result = try Self.anthropicResponseFromSSE(responseData)
            } else {
                result = try Self.chatCompletionFromSSE(responseData)
            }
            if configuration.api == RouterAPIKind.chatGPT.rawValue {
                let responseToolNames = ToolCloak.responsesNameMap(
                    for: tools.map(\.name) + messages.flatMap { $0.toolCalls.map(\.name) }
                )
                let originalNameByWireName = Dictionary(uniqueKeysWithValues: responseToolNames.map {
                    ($0.value, $0.key)
                })
                result.message.toolCalls = result.message.toolCalls.map { call in
                    AgentToolCall(
                        id: call.id,
                        name: originalNameByWireName[call.name] ?? call.name,
                        arguments: call.arguments
                    )
                }
            }
            if (configuration.usageMode == .economy || responseStyle.isShort),
               result.incompleteReason?.lowercased() == "max_output_tokens",
               retryCount == 0,
               !responseStyle.isHardLimit {
                if let reasoningTokens = result.usage?.reasoningTokens {
                    AgentOutputBudgetStore.shared.record(configuration: configuration, reasoningTokens: reasoningTokens)
                }
                let base = outputBudget ?? AgentOutputBudget.resolve(
                    configuration: configuration,
                    messages: messages,
                    tools: tools,
                    decision: responseStyle
                )
                var retry = try await complete(
                    messages: messages,
                    tools: tools,
                    cachePolicy: cachePolicy,
                    outputBudget: base.expanded(for: configuration),
                    retryCount: 1
                )
                retry.retryUsage = result.usage
                return retry
            }
            if let reasoningTokens = result.usage?.reasoningTokens {
                AgentOutputBudgetStore.shared.record(configuration: configuration, reasoningTokens: reasoningTokens)
            }
            result.effectiveOutputBudget = effectiveBudget
            result.retryCount = retryCount
            result.firstTokenMilliseconds = firstTokenMilliseconds
            AgentPromptCacheComparisons.shared.record(configuration, key: cachePolicy.comparisonScope ?? cachePolicy.promptCacheKey,
                                                      id: result.providerResponseID)
            if configuration.api == RouterAPIKind.anthropic.rawValue {
                result.effectiveCacheTTLSeconds = configuration.anthropicCacheTTL.seconds
                let cloaked = configuration.transportSpec?.quirks.cloakToolsOnOAuth == true && configuration.isOAuth
                result.message.toolCalls = result.message.toolCalls.map {
                    AgentToolCall(id: $0.id, name: ToolCloak.restore($0.name, cloaked: cloaked), arguments: $0.arguments)
                }
            }
            let (evidence, boundary) = cacheSnapshot.evaluate(response: result, prior: effectiveCachePolicy.priorBoundary)
            result.cacheReuseEvidence = evidence
            result.proposedCacheBoundary = boundary
            result.effectiveCacheTTLSeconds = cacheSnapshot.effectiveTTLSeconds
            AgentPromptCacheComparisons.shared.recordBoundary(configuration, key: boundaryScope, boundary: boundary)
            return result
        } catch {
            throw Self.requestError(error)
        }
    }

    /// Cancellation stays cancellation; anything else becomes a `NativeAgentError`.
    private static func requestError(_ error: Error) -> Error {
        if error is NativeAgentError { return error }
        if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
            return CancellationError()
        }
        return NativeAgentError(error.localizedDescription, retryable: isRetryable(error), isNetworkFailure: isRetryable(error))
    }

    private static func isNativeCompactionRejection(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("context_management")
            || lowercased.contains("compact_threshold")
            || lowercased.contains("compaction")
    }

    private static func isAnthropicContextEditingRejection(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("context_management")
            || lowercased.contains("context-management")
            || lowercased.contains("clear_tool_uses")
    }

    /// Uses the selected Responses model's built-in image-generation tool.
    /// The tool returns the finished PNG as base64 in an image-generation call.
    public func generateImage(prompt: String, paths: SupportPaths) async throws -> ChatMedia {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw NativeAgentError(AppCopy.text("media.promptMissing"))
        }
        guard configuration.api == RouterAPIKind.chatGPT.rawValue else {
            throw NativeAgentError(AppCopy.format("media.unsupported", MediaKind.image.displayName))
        }

        var body = makeResponsesBody(
            messages: [AgentMessage(role: .user, content: prompt)],
            tools: [],
            cachePolicy: AgentCachePolicy()
        )
        body["tools"] = [["type": "image_generation"]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw NativeAgentError(AppCopy.text("agent.encodeRequestFailed"))
        }
        let request = try makeRequest(body: data, accept: "text/event-stream")

        do {
            let (responseData, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let value = (try? JSONCodec.parse(responseData)) ?? .null
            guard (200..<300).contains(status) else {
                throw NativeAgentError(
                    Self.errorMessage(from: value, status: status),
                    statusCode: status,
                    retryable: Self.isRetryable(status),
                    isLimit: Self.limitKind(from: value, status: status) != nil,
                    retryAt: NativeAgentError.retryAt(from: response)
                )
            }
            let encoded = try Self.imageBase64FromResponse(responseData)
            let raw = encoded.components(separatedBy: ",").last ?? encoded
            guard let imageData = Data(base64Encoded: raw, options: .ignoreUnknownCharacters) else {
                throw NativeAgentError(AppCopy.text("media.invalidOutput"))
            }
            return try MediaGenerationClient.save(imageData, kind: .image, paths: paths)
        } catch {
            throw Self.requestError(error)
        }
    }
}

extension JSONValue {
    var firstObject: JSONObject? {
        guard case .array(let values) = self else { return nil }
        return values.first?.object
    }
}

extension Array where Element == JSONValue {
    var textBlocks: String { map { $0["text"]?.string ?? "" }.joined() }
}
