// Copyright (c) 2026 DOTS
// OpenAI-compatible transport used by the native agent loop.

import Foundation
import HarnessPluginKit

public struct AgentConfiguration: Sendable, Equatable {
    public var baseURL: String
    public var model: String
    public var apiKey: String?
    public var provider: String
    public var api: String
    public var sessionAccountID: String?
    public var cacheCapabilities: AgentCacheCapabilities
    /// Registry spec id, used to pull transport headers / quirks. Empty for
    /// direct endpoints configured by hand.
    public var specID: String
    /// "oauth" when `apiKey` holds a bearer OAuth token rather than an API key.
    public var authType: String

    public init(
        baseURL: String,
        model: String,
        apiKey: String? = nil,
        provider: String = "Custom API",
        api: String = "openai-compatible",
        sessionAccountID: String? = nil,
        cacheCapabilities: AgentCacheCapabilities = .unsupported,
        specID: String = "",
        authType: String = ""
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.provider = provider
        self.api = api
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

public struct AgentMessage: Sendable, Equatable {
    public enum Role: String, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    public var role: Role
    public var content: String
    public var name: String?
    public var toolCallID: String?
    public var toolCalls: [AgentToolCall]

    public init(
        role: Role,
        content: String,
        name: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [AgentToolCall] = []
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "role": role.rawValue,
            "content": content,
        ]
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
}

public struct AgentToolCall: Sendable, Equatable, Identifiable {
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

    public init(message: AgentMessage, usage: AgentUsage? = nil) {
        self.message = message
        self.usage = usage
    }
}

public struct AgentUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedTokens: Int?
    public var cacheWriteTokens: Int?

    public init(inputTokens: Int, outputTokens: Int, cachedTokens: Int? = nil, cacheWriteTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

public struct NativeAgentError: Error, Sendable, LocalizedError, Equatable {
    public var message: String
    public var statusCode: Int?
    public var retryable: Bool

    public init(_ message: String, statusCode: Int? = nil, retryable: Bool = false) {
        self.message = message
        self.statusCode = statusCode
        self.retryable = retryable
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
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw NativeAgentError(AppCopy.text("agent.encodeRequestFailed"))
        }

        guard let endpoint else { throw NativeAgentError(AppCopy.text("agent.invalidEndpoint")) }
        var request = URLRequest(url: endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = configuration.apiKey, !apiKey.isEmpty {
            if configuration.api == RouterAPIKind.anthropic.rawValue && !configuration.isOAuth {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        if configuration.api == RouterAPIKind.anthropic.rawValue {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if configuration.api == RouterAPIKind.chatGPT.rawValue {
            guard let accountID = configuration.sessionAccountID, !accountID.isEmpty else {
                throw NativeAgentError("The GPT session account is unavailable.")
            }
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
            request.setValue("codex", forHTTPHeaderField: "OAI-Product-Sku")
            request.setValue("responses=v1", forHTTPHeaderField: "OpenAI-Beta")
            request.setValue("dots_harness", forHTTPHeaderField: "originator")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "session_id")
        }
        // Registry-supplied transport headers (spoof / beta flags). Applied last
        // so a provider spec can override the defaults above.
        for (key, value) in configuration.transportSpec?.extraHeaders ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = data

        do {
            let (responseData, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let value = (try? JSONCodec.parse(responseData)) ?? .null
            guard (200..<300).contains(status) else {
                throw NativeAgentError(
                    Self.errorMessage(from: value, status: status),
                    statusCode: status,
                    retryable: Self.isRetryable(status)
                )
            }
            var result = try Self.response(from: value)
            if configuration.transportSpec?.quirks.cloakToolsOnOAuth == true, configuration.isOAuth {
                result.message.toolCalls = result.message.toolCalls.map {
                    AgentToolCall(id: $0.id, name: ToolCloak.restore($0.name), arguments: $0.arguments)
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

    private var endpoint: URL? {
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

    private func makeBody(
        messages: [AgentMessage],
        tools: [AgentToolDefinition],
        cachePolicy: AgentCachePolicy
    ) -> [String: Any] {
        if configuration.api == RouterAPIKind.anthropic.rawValue {
            return makeAnthropicBody(messages: messages, tools: tools)
        }
        if configuration.api == RouterAPIKind.chatGPT.rawValue {
            return makeResponsesBody(messages: messages, tools: tools)
        }
        var body: [String: Any] = ["model": configuration.model, "messages": messages.map { $0.jsonObject() }, "temperature": 0.2]
        if configuration.cacheCapabilities.promptCacheKey,
           let key = cachePolicy.promptCacheKey,
           !key.isEmpty {
            body["prompt_cache_key"] = key
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { $0.jsonObject() }
            body["tool_choice"] = "auto"
        }
        return body
    }

    private func makeAnthropicBody(messages: [AgentMessage], tools: [AgentToolDefinition]) -> [String: Any] {
        let system = messages.first(where: { $0.role == .system })?.content
        let converted = messages.filter { $0.role != .system }.map { message -> [String: Any] in
            if message.role == .tool {
                return [
                    "role": "user",
                    "content": [["type": "tool_result", "tool_use_id": message.toolCallID ?? "tool", "content": message.content]],
                ]
            }
            var content: Any = message.content
            if message.role == .assistant && !message.toolCalls.isEmpty {
                content = ([message.content.isEmpty ? nil : ["type": "text", "text": message.content] as [String: Any]?].compactMap { $0 })
                    + message.toolCalls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": Self.jsonObject(from: $0.arguments)] }
            }
            return ["role": message.role == .assistant ? "assistant" : "user", "content": content]
        }
        var body: [String: Any] = ["model": configuration.model, "max_tokens": 4096, "messages": converted]
        let quirks = configuration.transportSpec?.quirks
        // OAuth (subscription) tokens require Claude Code's identity as the first
        // system block, otherwise Anthropic rejects the request.
        if let identity = quirks?.injectAgentIdentity, configuration.isOAuth {
            let user = (system?.isEmpty == false) ? "\n\n\(system!)" : ""
            body["system"] = identity + user
        } else if let system, !system.isEmpty {
            body["system"] = system
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters.any] }
        }
        if quirks?.cloakToolsOnOAuth == true, configuration.isOAuth {
            ToolCloak.apply(to: &body)
        }
        return body
    }

    private func makeResponsesBody(messages: [AgentMessage], tools: [AgentToolDefinition]) -> [String: Any] {
        let system = messages.first(where: { $0.role == .system })?.content ?? "You are a helpful assistant."
        var input: [[String: Any]] = []
        for message in messages where message.role != .system {
            if message.role == .tool {
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
                let type = role == "assistant" ? "output_text" : "input_text"
                input.append(["role": role, "content": [["type": type, "text": message.content]]])
            }
        }
        var body: [String: Any] = [
            "model": configuration.model,
            "instructions": system,
            "input": input,
            "store": false,
            "stream": false,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { [
                "type": "function",
                "name": $0.name,
                "description": $0.description,
                "parameters": $0.parameters.any,
            ] }
        }
        return body
    }

    private static func response(from value: JSONValue) throws -> AgentResponse {
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
            let usage = value["usage"]?.object.map { AgentUsage(inputTokens: $0["input_tokens"]?.int ?? 0, outputTokens: $0["output_tokens"]?.int ?? 0) }
            return AgentResponse(message: AgentMessage(role: .assistant, content: text, toolCalls: calls), usage: usage)
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
            let usage = value["usage"]?.object.map { AgentUsage(inputTokens: $0["input_tokens"]?.int ?? 0, outputTokens: $0["output_tokens"]?.int ?? 0) }
            return AgentResponse(message: AgentMessage(role: .assistant, content: blocks.textBlocks, toolCalls: toolCalls), usage: usage)
        }
        guard let choice = value["choices"]?.firstObject,
              let messageObject = choice["message"]?.object else {
            throw NativeAgentError(AppCopy.text("agent.noMessage"))
        }

        let content = messageObject["content"]?.textBlocks() ?? ""
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
                inputTokens: $0["prompt_tokens"]?.int ?? 0,
                outputTokens: $0["completion_tokens"]?.int ?? 0,
                cachedTokens: $0["prompt_tokens_details"]?["cached_tokens"]?.int,
                cacheWriteTokens: $0["prompt_tokens_details"]?["cache_write_tokens"]?.int
            )
        }
        return AgentResponse(
            message: AgentMessage(role: .assistant, content: content, toolCalls: toolCalls),
            usage: usage
        )
    }

    private static func errorMessage(from value: JSONValue, status: Int) -> String {
        if let message = value["error"]?["message"]?.string ?? value["message"]?.string,
           !message.isEmpty {
            return message
        }
        return AppCopy.format("agent.requestFailed", status)
    }

    private static func isRetryable(_ status: Int) -> Bool { status == 408 || status == 409 || status == 425 || status == 429 || (500..<600).contains(status) }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet].contains(error.code)
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
