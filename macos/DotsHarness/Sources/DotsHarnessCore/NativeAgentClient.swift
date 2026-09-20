// Copyright (c) 2026 DOTS
// OpenAI-compatible transport used by the native agent loop.

import Foundation
import HarnessPluginKit
import PluginRuntime

public struct AgentConfiguration: Sendable, Equatable {
    public var baseURL: String
    public var model: String
    public var apiKey: String?
    public var provider: String
    public var api: String
    /// Stable account identity for prompt-cache isolation. This is never a
    /// credential; it only prevents two provider accounts from sharing a cache
    /// namespace accidentally.
    public var accountID: String?
    public var sessionAccountID: String?
    public var cacheCapabilities: AgentCacheCapabilities
    /// Registry spec id, used to pull transport headers / quirks. Empty for
    /// direct endpoints configured by hand.
    public var specID: String
    /// "oauth" when `apiKey` holds a bearer OAuth token rather than an API key.
    public var authType: String
    /// Reasoning-effort level for this request. Only sent when non-empty, since
    /// providers reject the parameter on models that don't support it.
    public var effort: String = ""
    /// Fast/priority response speed. Router only sets it for models that support it.
    public var fast = false
    /// Input context window used by the compaction guard when live metadata is
    /// unavailable. RouterController supplies the provider/model-specific value.
    public var contextWindow: Int = AgentContextCompaction.defaultContextWindow
    /// Only enabled by a provider registry entry that explicitly supports the
    /// public Responses compaction contract.
    public var supportsNativeCompaction: Bool = false
    /// Runtime compaction policy. Native Responses compaction and local fallback
    /// use the same threshold so a route switch does not change the safety budget.
    public var compactionPolicy: AgentContextCompactionPolicy = .baseline

    public init(
        baseURL: String,
        model: String,
        apiKey: String? = nil,
        provider: String = "Custom API",
        api: String = "openai-compatible",
        accountID: String? = nil,
        sessionAccountID: String? = nil,
        cacheCapabilities: AgentCacheCapabilities = .unsupported,
        specID: String = "",
        authType: String = "",
        effort: String = "",
        contextWindow: Int = AgentContextCompaction.defaultContextWindow,
        supportsNativeCompaction: Bool = false,
        compactionPolicy: AgentContextCompactionPolicy = .baseline
    ) {
        self.effort = effort
        self.contextWindow = contextWindow
        self.supportsNativeCompaction = supportsNativeCompaction
        self.compactionPolicy = compactionPolicy
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.provider = provider
        self.api = api
        self.accountID = accountID
        self.sessionAccountID = sessionAccountID
        self.cacheCapabilities = cacheCapabilities
        self.specID = specID
        self.authType = authType
    }

    var transportSpec: ProviderSpec.Transport? { ProviderRegistry.shared.spec(specID)?.transport }
    var isOAuth: Bool { authType == "oauth" || authType == "chatgpt" }
}

public struct AgentCacheCapabilities: Sendable, Equatable {
    public var promptCacheKey: Bool
    public var explicitBreakpoint: Bool
    public var usageCacheTokens: Bool
    public var cacheWriteTokens: Bool
    public var responsesTransport: Bool

    public init(
        promptCacheKey: Bool = false,
        explicitBreakpoint: Bool = false,
        usageCacheTokens: Bool = false,
        cacheWriteTokens: Bool = false,
        responsesTransport: Bool = false
    ) {
        self.promptCacheKey = promptCacheKey
        self.explicitBreakpoint = explicitBreakpoint
        self.usageCacheTokens = usageCacheTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.responsesTransport = responsesTransport
    }

    public static let unsupported = AgentCacheCapabilities()
}

public struct AgentCachePolicy: Sendable, Equatable {
    public var promptCacheKey: String?

    public init(promptCacheKey: String? = nil) {
        self.promptCacheKey = promptCacheKey
    }
}

public struct AgentMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable, Equatable {
        case system
        case user
        case assistant
        case tool
    }

    /// System prompt messages are split so stable policy/tool guidance can stay
    /// at the beginning of a provider prefix while workspace data can change.
    public enum SystemKind: String, Sendable, Codable, Equatable {
        case promptStable
        case promptDynamic
        case compactionSummary
    }

    public var role: Role
    public var content: String
    public var thinking: String?
    public var name: String?
    public var toolCallID: String?
    public var toolCalls: [AgentToolCall]
    public var attachments: [ChatAttachment]
    public var systemKind: SystemKind?
    /// Persisted with the model transcript; never sent as a provider field.
    public var promptContextCaptured: Bool = false
    /// Raw Responses output items are kept only when the same Responses route is
    /// reused. Other transports use the normalized role/tool representation.
    public var providerItems: [JSONObject]

    public init(
        role: Role,
        content: String,
        thinking: String? = nil,
        name: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [AgentToolCall] = [],
        attachments: [ChatAttachment] = [],
        providerItems: [JSONObject] = [],
        systemKind: SystemKind? = nil
    ) {
        self.role = role
        self.content = content
        self.thinking = thinking
        self.name = name
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
        self.attachments = attachments
        self.providerItems = providerItems
        self.systemKind = systemKind
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, thinking, name, toolCallID, toolCalls, attachments, providerItems, systemKind, promptContextCaptured
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(Role.self, forKey: .role) ?? .user
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        toolCalls = try container.decodeIfPresent([AgentToolCall].self, forKey: .toolCalls) ?? []
        attachments = try container.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
        providerItems = try container.decodeIfPresent([JSONObject].self, forKey: .providerItems) ?? []
        systemKind = try container.decodeIfPresent(SystemKind.self, forKey: .systemKind)
        promptContextCaptured = try container.decodeIfPresent(Bool.self, forKey: .promptContextCaptured) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encode(toolCalls, forKey: .toolCalls)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(providerItems, forKey: .providerItems)
        try container.encodeIfPresent(systemKind, forKey: .systemKind)
        try container.encode(promptContextCaptured, forKey: .promptContextCaptured)
    }

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "role": role.rawValue,
            "content": content,
        ]
        if !attachments.isEmpty { object["content"] = openAIContent() }
        if let name { object["name"] = name }
        if let toolCallID { object["tool_call_id"] = toolCallID }
        if !toolCalls.isEmpty {
            object["tool_calls"] = toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.arguments,
                    ],
                ]
            }
        }
        return object
    }

    private func openAIContent() -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        if !content.isEmpty { blocks.append(["type": "text", "text": content]) }
        for attachment in attachments {
            if let data = inlineImageData(attachment) {
                blocks.append([
                    "type": "image_url",
                    "image_url": ["url": "data:" + attachment.mimeType + ";base64," + data.base64EncodedString()],
                ])
            } else {
                blocks.append(["type": "text", "text": attachmentDescription(attachment)])
            }
        }
        return blocks
    }

    func anthropicContent() -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        if !content.isEmpty { blocks.append(["type": "text", "text": content]) }
        for attachment in attachments {
            if let data = inlineImageData(attachment) {
                blocks.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": attachment.mimeType,
                        "data": data.base64EncodedString(),
                    ],
                ])
            } else {
                blocks.append(["type": "text", "text": attachmentDescription(attachment)])
            }
        }
        return blocks
    }

    func responsesContent() -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        if !content.isEmpty { blocks.append(["type": "input_text", "text": content]) }
        for attachment in attachments {
            if let data = inlineImageData(attachment) {
                blocks.append([
                    "type": "input_image",
                    "image_url": "data:" + attachment.mimeType + ";base64," + data.base64EncodedString(),
                ])
            } else {
                blocks.append(["type": "input_text", "text": attachmentDescription(attachment)])
            }
        }
        return blocks
    }

    func geminiParts() -> [[String: Any]] {
        var parts: [[String: Any]] = []
        if !content.isEmpty { parts.append(["text": content]) }
        for attachment in attachments {
            if let data = inlineImageData(attachment) {
                parts.append(["inlineData": ["mimeType": attachment.mimeType, "data": data.base64EncodedString()]])
            } else {
                parts.append(["text": attachmentDescription(attachment)])
            }
        }
        return parts.isEmpty ? [["text": ""]] : parts
    }

    private func inlineImageData(_ attachment: ChatAttachment) -> Data? {
        guard attachment.kind == .image,
              let data = try? Data(contentsOf: attachment.url),
              data.count <= 20 * 1024 * 1024 else { return nil }
        return data
    }

    private func attachmentDescription(_ attachment: ChatAttachment) -> String {
        "Attached " + attachment.kind.rawValue + ": " + attachment.name + " (" + attachment.path + ")"
    }
}

public struct AgentToolCall: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct AgentToolDefinition: Sendable, Equatable, Identifiable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public var id: String { name }

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    public func jsonObject() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters.any,
            ],
        ]
    }
}

public struct AgentResponse: Sendable, Equatable {
    public var message: AgentMessage
    public var usage: AgentUsage?
    /// Structured media emitted by the provider. Binary data stays out of the
    /// durable AgentMessage transcript and is materialized by AgentBridge.
    public var media: [MediaPayload]
    /// True when the provider returned an opaque native compaction item that is
    /// now part of `message.providerItems`.
    public var nativeCompactionApplied: Bool
    /// True when a native-compaction request was rejected and the client retried
    /// the same request without the optional native feature.
    public var nativeCompactionFallback: Bool

    public init(
        message: AgentMessage,
        usage: AgentUsage? = nil,
        media: [MediaPayload] = [],
        nativeCompactionApplied: Bool = false,
        nativeCompactionFallback: Bool = false
    ) {
        self.message = message
        self.usage = usage
        self.media = media
        self.nativeCompactionApplied = nativeCompactionApplied
        self.nativeCompactionFallback = nativeCompactionFallback
    }
}

public struct AgentUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedTokens: Int?
    public var cacheWriteTokens: Int?
    /// Providers such as DeepSeek expose the uncached prompt count directly.
    /// Keep it optional: absence means the provider did not expose a complete
    /// hit/miss accounting, not that the miss count was zero.
    public var cacheMissTokens: Int?

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cachedTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        cacheMissTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheMissTokens = cacheMissTokens
    }
}

public struct NativeAgentError: Error, Sendable, LocalizedError, Equatable {
    public var message: String
    public var statusCode: Int?
    public var retryable: Bool
    public var isLimit: Bool
    public var isImageInputUnsupported: Bool
    /// When the provider said it would accept requests again, taken from the rate
    /// limit headers. Nil when it did not say, which is not the same as "never".
    public var retryAt: Date?

    public init(
        _ message: String,
        statusCode: Int? = nil,
        retryable: Bool = false,
        isLimit: Bool = false,
        isImageInputUnsupported: Bool = false,
        retryAt: Date? = nil
    ) {
        self.message = message
        self.statusCode = statusCode
        self.isLimit = isLimit || statusCode == 429
        self.isImageInputUnsupported = isImageInputUnsupported
        self.retryable = self.isLimit ? false : retryable
        self.retryAt = retryAt
    }

    /// Reads the moment a rate-limited provider will serve again. Providers disagree
    /// on the header and on the format: seconds to wait, an HTTP date, or a Unix or
    /// ISO-8601 instant. Anything unparseable is left nil rather than guessed at.
    public static func retryAt(from response: URLResponse?, now: Date = Date()) -> Date? {
        guard let http = response as? HTTPURLResponse else { return nil }
        let names = [
            "retry-after",
            "anthropic-ratelimit-unified-reset",
            "x-ratelimit-reset-requests",
            "x-ratelimit-reset-tokens",
            "x-ratelimit-reset",
        ]
        for name in names {
            guard let raw = (http.value(forHTTPHeaderField: name))?
                .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { continue }
            if let seconds = Double(raw) {
                // Small numbers are a delay; large ones are a Unix timestamp.
                let date = seconds > 10_000_000 ? Date(timeIntervalSince1970: seconds) : now.addingTimeInterval(seconds)
                if date > now { return date }
                continue
            }
            if let date = ISO8601DateFormatter().date(from: raw), date > now { return date }
            let http1 = DateFormatter()
            http1.locale = Locale(identifier: "en_US_POSIX")
            http1.timeZone = TimeZone(identifier: "GMT")
            http1.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = http1.date(from: raw), date > now { return date }
        }
        return nil
    }

    public var errorDescription: String? { message }
}

public struct NativeAgentClient: Sendable {
    public var configuration: AgentConfiguration
    private var session: URLSession

    public init(configuration: AgentConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func complete(
        messages: [AgentMessage],
        tools: [AgentToolDefinition] = [],
        cachePolicy: AgentCachePolicy = AgentCachePolicy()
    ) async throws -> AgentResponse {
        let body = makeBody(messages: messages, tools: tools, cachePolicy: cachePolicy)
        // Prompt caches match the prefix byte for byte; sorted keys keep tool
        // schemas identical across requests and app restarts.
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys) else {
            throw NativeAgentError(AppCopy.text("agent.encodeRequestFailed"))
        }

        let request = try makeRequest(
            body: data,
            accept: configuration.api == RouterAPIKind.chatGPT.rawValue ? "text/event-stream" : "application/json",
            sessionKey: cachePolicy.promptCacheKey
        )

        do {
            let (responseData, response) = try await session.data(for: request)
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
                // server that rejects unknown fields gets the same request again
                // without it.
                // ponytail: retried on every turn for such a server; remember the
                // rejection per endpoint if one turns up in practice.
                if [400, 422].contains(status),
                   body["prompt_cache_key"] != nil,
                   message.lowercased().contains("prompt_cache_key") {
                    return try await complete(messages: messages, tools: tools, cachePolicy: AgentCachePolicy())
                }
                if status == 400, configuration.supportsNativeCompaction {
                    var fallback = configuration
                    fallback.supportsNativeCompaction = false
                    var result = try await NativeAgentClient(configuration: fallback, session: session).complete(
                        messages: messages,
                        tools: tools,
                        cachePolicy: cachePolicy
                    )
                    result.nativeCompactionFallback = true
                    return result
                }
                throw NativeAgentError(
                    message,
                    statusCode: status,
                    retryable: Self.isRetryable(status),
                    isLimit: Self.limitKind(from: value, status: status) != nil,
                    retryAt: NativeAgentError.retryAt(from: response)
                )
            }
            var result: AgentResponse
            if configuration.api == RouterAPIKind.chatGPT.rawValue {
                result = try Self.responseFromSSE(responseData)
            } else if configuration.api == RouterAPIKind.geminiCLI.rawValue {
                result = try Self.geminiResponse(from: value)
            } else {
                result = try Self.response(from: value)
            }
            if configuration.api == RouterAPIKind.anthropic.rawValue {
                let cloaked = configuration.transportSpec?.quirks.cloakToolsOnOAuth == true && configuration.isOAuth
                result.message.toolCalls = result.message.toolCalls.map {
                    AgentToolCall(id: $0.id, name: ToolCloak.restore($0.name, cloaked: cloaked), arguments: $0.arguments)
                }
            }
            return result
        } catch let error as NativeAgentError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw NativeAgentError(error.localizedDescription, retryable: Self.isRetryable(error))
        }
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
        } catch let error as NativeAgentError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw NativeAgentError(error.localizedDescription, retryable: Self.isRetryable(error))
        }
    }

    private func makeRequest(body: Data, accept: String, sessionKey: String? = nil) throws -> URLRequest {
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

    private var endpoint: URL? {
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
        var body: [String: Any] = ["model": configuration.model, "messages": messages.map { $0.jsonObject() }, "temperature": 0.2]
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
                return [
                    "role": "user",
                    "content": [["type": "tool_result", "tool_use_id": message.toolCallID ?? "tool", "content": message.content]],
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
                contents.append([
                    "role": "user",
                    "parts": [["functionResponse": [
                        "name": message.toolCallID ?? "tool",
                        "response": ["result": message.content],
                    ]]],
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

    private func makeResponsesBody(
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
                    cacheMissTokens: $0["prompt_cache_miss_tokens"]?.int
                )
            }
            let media = blocks.flatMap(Self.mediaPayloads)
            return AgentResponse(
                message: AgentMessage(role: .assistant, content: text, toolCalls: calls, providerItems: providerItems),
                usage: usage,
                media: media,
                nativeCompactionApplied: blocks.contains { $0["type"]?.string == "compaction" }
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
            let usage = value["usage"]?.object.map {
                AgentUsage(
                    inputTokens: $0["input_tokens"]?.int ?? 0,
                    outputTokens: $0["output_tokens"]?.int ?? 0,
                    cachedTokens: $0["cache_read_input_tokens"]?.int,
                    cacheWriteTokens: $0["cache_creation_input_tokens"]?.int,
                    cacheMissTokens: $0["prompt_cache_miss_tokens"]?.int
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
                media: blocks.flatMap(Self.mediaPayloads)
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
                cacheMissTokens: $0["prompt_cache_miss_tokens"]?.int
            )
        }
        return AgentResponse(
            message: AgentMessage(role: .assistant, content: content, thinking: reasoning, toolCalls: toolCalls),
            usage: usage,
            media: Self.mediaPayloads(from: messageObject["content"] ?? .null)
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
        var finalResponse: JSONValue?
        var textAcc = ""
        var thinkingAcc = ""
        var callOrder: [String] = []
        var calls: [String: (name: String, args: String)] = [:]
        var providerItems: [JSONObject] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty, payload != "[DONE]",
                  let event = try? JSONCodec.parse(Data(payload.utf8)) else { continue }
            switch event["type"]?.string ?? "" {
            case "response.output_text.delta":
                textAcc += event["delta"]?.string ?? ""
            case "response.reasoning_text.delta":
                thinkingAcc += event["delta"]?.string ?? ""
            case "response.completed", "response.incomplete":
                finalResponse = event["response"]
            case "response.output_item.done":
                guard let item = event["item"]?.object else { break }
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
            case "response.failed", "error":
                let message = event["message"]?.string
                    ?? event["error"]?["message"]?.string
                    ?? event["response"]?["error"]?["message"]?.string
                    ?? "The Codex stream reported an error."
                let status = event["status"]?.int
                    ?? event["error"]?["status"]?.int
                    ?? event["response"]?["status"]?.int
                    ?? event["response"]?["error"]?["status"]?.int
                    ?? 502
                throw NativeAgentError(
                    message,
                    statusCode: status,
                    isLimit: Self.limitKind(from: event, status: status) != nil
                )
            default:
                break
            }
        }

        // Some Responses servers include the opaque compaction item only in
        // response.completed.output. Preserve it even when text deltas already
        // made the stream non-empty, so the fallback below is not skipped.
        if let finalResponse,
           case .array(let output) = finalResponse["output"] {
            for item in output where item["type"]?.string == "compaction" {
                guard let object = item.object,
                      !providerItems.contains(where: { $0 == object }) else { continue }
                providerItems.append(object)
            }
        }

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
                cacheMissTokens: $0["prompt_cache_miss_tokens"]?.int
            )
        }

        if textAcc.isEmpty, toolCalls.isEmpty, providerItems.isEmpty {
            // Nothing in the stream — fall back to the terminal payload for
            // backends that do populate `output` there.
            if let finalResponse, case .array(let output) = finalResponse["output"], !output.isEmpty {
                return try response(from: finalResponse)
            }
            throw NativeAgentError(AppCopy.text("agent.noMessage"))
        }
        let media = providerItems.flatMap { Self.mediaPayloads(from: .object($0)) }
        return AgentResponse(
            message: AgentMessage(role: .assistant, content: textAcc, thinking: thinkingAcc.isEmpty ? nil : thinkingAcc, toolCalls: toolCalls, providerItems: providerItems),
            usage: usage,
            media: media,
            nativeCompactionApplied: providerItems.contains { $0["type"]?.string == "compaction" }
        )
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
                let message = event["message"]?.string
                    ?? event["error"]?["message"]?.string
                    ?? event["response"]?["error"]?["message"]?.string
                    ?? "The image generation stream reported an error."
                let status = event["status"]?.int
                    ?? event["error"]?["status"]?.int
                    ?? event["response"]?["status"]?.int
                    ?? event["response"]?["error"]?["status"]?.int
                    ?? 502
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
                outputTokens: $0["candidatesTokenCount"]?.int ?? 0,
                cachedTokens: $0["cachedContentTokenCount"]?.int
            )
        }
        return AgentResponse(
            message: AgentMessage(role: .assistant, content: text, thinking: thinking, toolCalls: calls),
            usage: usage,
            media: parts.flatMap(Self.mediaPayloads)
        )
    }

    /// Extracts only provider-native media blocks. Plain markdown/URLs in text
    /// are intentionally ignored so a model cannot cause an unsolicited
    /// download merely by mentioning an image URL.
    static func mediaPayloads(from value: JSONValue) -> [MediaPayload] {
        var payloads: [MediaPayload] = []
        if let payload = mediaPayload(from: value) {
            payloads.append(payload)
        }

        switch value {
        case .array(let values):
            for value in values { payloads.append(contentsOf: mediaPayloads(from: value)) }
        case .object:
            for key in ["output", "content", "parts", "candidates", "response"] {
                if let nested = value[key] {
                    payloads.append(contentsOf: mediaPayloads(from: nested))
                }
            }
        case .null, .bool, .number, .string:
            break
        }
        return payloads
    }

    private static func mediaPayload(from value: JSONValue) -> MediaPayload? {
        let type = value["type"]?.string?.lowercased() ?? ""
        let nested = value["image_url"] ?? value["audio_url"] ?? value["video_url"] ?? value["source"] ?? value["inlineData"] ?? value["fileData"] ?? .null
        let nestedObject = nested.object
        let mimeType = (
            value["mimeType"]?.string
                ?? value["mime_type"]?.string
                ?? value["media_type"]?.string
                ?? nestedObject?["mimeType"]?.string
                ?? nestedObject?["media_type"]?.string
                ?? inferredMIMEType(for: type)
        )?.lowercased()

        guard let mimeType, let kind = mediaKind(mimeType: mimeType, type: type) else { return nil }

        let rawBase64 = value["b64_json"]?.string
            ?? value["blob"]?.string
            ?? value["result"]?.string
            ?? nestedObject?["data"]?.string
            ?? (nested.string.flatMap { type.contains("image") || type.contains("audio") || type.contains("video") ? $0 : nil })
        if let rawBase64 {
            let encoded = rawBase64.components(separatedBy: ",").last ?? rawBase64
            if let data = Data(base64Encoded: encoded), !data.isEmpty {
                return MediaPayload(kind: kind, mimeType: mimeType, data: data)
            }
        }

        let rawURL = value["url"]?.string
            ?? value["file_url"]?.string
            ?? value["uri"]?.string
            ?? nestedObject?["url"]?.string
            ?? nestedObject?["fileUri"]?.string
        if let rawURL, let url = URL(string: rawURL),
           ["http", "https"].contains(url.scheme?.lowercased()) {
            return MediaPayload(kind: kind, mimeType: mimeType, url: url)
        }
        return nil
    }

    private static func mediaKind(mimeType: String, type: String) -> MediaKind? {
        if mimeType.hasPrefix("image/") || type.contains("image") { return .image }
        if mimeType.hasPrefix("video/") || type.contains("video") { return .video }
        if mimeType.hasPrefix("audio/") || type.contains("audio") { return .audio }
        return nil
    }

    private static func inferredMIMEType(for type: String) -> String? {
        if type.contains("image") { return "image/png" }
        if type.contains("video") { return "video/mp4" }
        if type.contains("audio") { return "audio/mpeg" }
        return nil
    }

    private static func errorMessage(from value: JSONValue, status: Int) -> String {
        if let message = value["error"]?["message"]?.string ?? value["message"]?.string,
           !message.isEmpty {
            return message
        }
        return AppCopy.format("agent.requestFailed", status)
    }

    private static func limitKind(from value: JSONValue, status: Int) -> String? {
        if status == 429 { return "rate" }
        let message = [
            value["error"]?["message"]?.string,
            value["error"]?["type"]?.string,
            value["error"]?["code"]?.string,
            value["response"]?["error"]?["message"]?.string,
            value["response"]?["error"]?["type"]?.string,
            value["response"]?["error"]?["code"]?.string,
            value["message"]?.string,
            value["type"]?.string,
            value["code"]?.string,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        if message.contains("rate limit") || message.contains("rate-limit") || message.contains("rate_limit") { return "rate" }
        if message.contains("quota") { return "quota" }
        if message.contains("credit") { return "credits" }
        if message.contains("usage limit") || message.contains("usage-limit") || message.contains("usage_limit") || message.contains("provider limit") || message.contains("provider_limit") { return "usage" }
        if message.contains("insufficient balance") || message.contains("insufficient_balance") || message.contains("insufficient funds") { return "balance" }
        return nil
    }

    private static func isRetryable(_ status: Int) -> Bool { status == 408 || status == 409 || status == 425 || status == 429 || (500..<600).contains(status) }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet].contains(error.code)
    }

    /// Output ceiling for an Anthropic request. Thinking is billed against the
    /// same budget as the answer, so deeper effort needs more room.
    static func maxTokens(forEffort effort: String) -> Int {
        switch effort {
        case "max": return 32_000
        case "xhigh": return 24_000
        case "high": return 16_000
        default: return 8_192
        }
    }

    private static func jsonObject(from string: String) -> Any {
        guard let data = string.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return object
    }
}

private extension JSONValue {
    var firstObject: JSONObject? {
        guard case .array(let values) = self else { return nil }
        return values.first?.object
    }
}

private extension Array where Element == JSONValue {
    var textBlocks: String { map { $0["text"]?.string ?? "" }.joined() }
}
