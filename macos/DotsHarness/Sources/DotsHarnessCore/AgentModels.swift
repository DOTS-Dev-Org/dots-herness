// Copyright (c) 2026 DOTS
// Provider-neutral agent request/response models and errors.

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
        // Chat Completions does not accept multimodal content on a `tool`
        // message. `makeBody` emits the tool result first and a provider-only
        // user message containing the attachment immediately after it.
        if !attachments.isEmpty, role != .tool { object["content"] = openAIContent() }
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

    func openAIContent() -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        if !content.isEmpty { blocks.append(["type": "text", "text": content]) }
        for attachment in attachments {
            if let data = inlineImageData(attachment) {
                blocks.append([
                    "type": "image_url",
                    "image_url": ["url": "data:" + attachment.mimeType + ";base64," + data.base64EncodedString()],
                ])
            } else if let data = inlineFileData(attachment) {
                blocks.append([
                    "type": "file",
                    "file": [
                        "filename": attachment.name,
                        "file_data": "data:" + attachment.mimeType + ";base64," + data.base64EncodedString(),
                    ],
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
            } else if isPDF(attachment), let data = inlineFileData(attachment) {
                blocks.append([
                    "type": "document",
                    "source": [
                        "type": "base64",
                        "media_type": "application/pdf",
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
            } else if let data = inlineFileData(attachment) {
                blocks.append([
                    "type": "input_file",
                    "filename": attachment.name,
                    "file_data": "data:" + attachment.mimeType + ";base64," + data.base64EncodedString(),
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
              let source = attachment.providerURL,
              let data = try? Data(contentsOf: source),
              data.count <= 20 * 1024 * 1024 else { return nil }
        return data
    }

    private func inlineFileData(_ attachment: ChatAttachment) -> Data? {
        guard attachment.kind == .file,
              let source = attachment.providerURL,
              let data = try? Data(contentsOf: source),
              data.count <= 50 * 1024 * 1024 else { return nil }
        return data
    }

    private func isPDF(_ attachment: ChatAttachment) -> Bool {
        attachment.mimeType.caseInsensitiveCompare("application/pdf") == .orderedSame
            || attachment.name.lowercased().hasSuffix(".pdf")
    }

    private func attachmentDescription(_ attachment: ChatAttachment) -> String {
        guard attachment.providerURL != nil else {
            return "source_missing: attachment_id: " + attachment.id
                + "; historical_revision_preserved; latest_revision_unavailable"
        }
        return "unsupported_attachment_kind: " + attachment.kind.rawValue
            + "; attachment_id: " + attachment.id
            + "; name: " + attachment.name
            + ". The host did not silently drop this attachment, but this provider route does not support its wire format."
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
