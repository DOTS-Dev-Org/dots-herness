// Copyright (c) 2026 DOTS
// Native provider catalog. Metadata is local and does not require a helper process.

import Foundation
import HarnessPluginKit

public enum RouterAuthKind: String, Sendable, Hashable {
    case oauthBrowser
    case oauthDevice
    case apiKey
}

public enum RouterAPIKind: String, Sendable, Hashable {
    case openAICompatible = "openai-compatible"
    case anthropic = "anthropic"
    case chatGPT = "chatgpt"
}

public struct RouterProviderKind: Identifiable, Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var kind: RouterAuthKind
    public var hint: String
    public var baseURL: String
    public var defaultModel: String
    public var api: RouterAPIKind
    public var logoSymbol: String

    public init(
        id: String,
        name: String,
        kind: RouterAuthKind,
        hint: String,
        baseURL: String,
        defaultModel: String,
        api: RouterAPIKind = .openAICompatible,
        logoSymbol: String = "sparkles"
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.hint = hint
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.api = api
        self.logoSymbol = logoSymbol
    }
}

public enum RouterCatalog {
    public static let providers: [RouterProviderKind] = [
        .init(id: "gpt", name: "GPT", kind: .oauthBrowser, hint: "Sign in with ChatGPT", baseURL: "https://chatgpt.com/backend-api/codex", defaultModel: "gpt-4.1-mini", api: .chatGPT, logoSymbol: "sparkles"),
        .init(id: "claude", name: "Claude", kind: .apiKey, hint: "API key", baseURL: "https://api.anthropic.com/v1", defaultModel: "claude-sonnet-4-20250514", api: .anthropic, logoSymbol: "circle.hexagongrid"),
        .init(id: "gemini", name: "Gemini", kind: .apiKey, hint: "API key", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", defaultModel: "gemini-2.5-flash", logoSymbol: "diamond"),
        .init(id: "antigravity", name: "Antigravity", kind: .apiKey, hint: "API key or Custom API", baseURL: "", defaultModel: "", logoSymbol: "arrow.up.forward.circle"),
        .init(id: "iflow", name: "iFlow", kind: .apiKey, hint: "API key or Custom API", baseURL: "", defaultModel: "", logoSymbol: "waveform"),
        .init(id: "github", name: "GitHub Copilot", kind: .apiKey, hint: "API key or Custom API", baseURL: "", defaultModel: "", logoSymbol: "chevron.left.forwardslash.chevron.right"),
        .init(id: "qwen", name: "Qwen", kind: .apiKey, hint: "API key", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", defaultModel: "qwen-plus", logoSymbol: "q.circle"),
        .init(id: "kiro", name: "Kiro", kind: .apiKey, hint: "API key or Custom API", baseURL: "", defaultModel: "", logoSymbol: "k.circle"),
        .init(id: "grok", name: "Grok", kind: .apiKey, hint: "API key", baseURL: "https://api.x.ai/v1", defaultModel: "grok-3-mini", logoSymbol: "bolt.circle"),
        .init(id: "openrouter", name: "OpenRouter", kind: .apiKey, hint: "API key", baseURL: "https://openrouter.ai/api/v1", defaultModel: "openai/gpt-4.1-mini", logoSymbol: "arrow.triangle.branch"),
        .init(id: "openai", name: "OpenAI", kind: .apiKey, hint: "API key", baseURL: "https://api.openai.com/v1", defaultModel: "gpt-4.1-mini", logoSymbol: "hexagon"),
        .init(id: "anthropic", name: "Anthropic", kind: .apiKey, hint: "API key", baseURL: "https://api.anthropic.com/v1", defaultModel: "claude-sonnet-4-20250514", api: .anthropic, logoSymbol: "circle.hexagongrid"),
        .init(id: "glm", name: "GLM", kind: .apiKey, hint: "API key", baseURL: "https://open.bigmodel.cn/api/paas/v4", defaultModel: "glm-4.5", logoSymbol: "g.circle"),
        .init(id: "kimi", name: "Kimi", kind: .apiKey, hint: "API key", baseURL: "https://api.moonshot.cn/v1", defaultModel: "moonshot-v1-8k", logoSymbol: "moon.circle"),
        .init(id: "minimax", name: "MiniMax", kind: .apiKey, hint: "API key", baseURL: "https://api.minimax.io/v1", defaultModel: "MiniMax-Text-01", logoSymbol: "m.circle"),
        .init(id: "deepseek", name: "DeepSeek", kind: .apiKey, hint: "API key", baseURL: "https://api.deepseek.com/v1", defaultModel: "deepseek-chat", logoSymbol: "wave.3.right.circle"),
        .init(id: "groq", name: "Groq", kind: .apiKey, hint: "API key", baseURL: "https://api.groq.com/openai/v1", defaultModel: "llama-3.3-70b-versatile", logoSymbol: "gauge.with.dots.needle.67percent"),
        .init(id: "xai", name: "xAI", kind: .apiKey, hint: "API key", baseURL: "https://api.x.ai/v1", defaultModel: "grok-3-mini", logoSymbol: "xmark.circle"),
        .init(id: "mistral", name: "Mistral", kind: .apiKey, hint: "API key", baseURL: "https://api.mistral.ai/v1", defaultModel: "mistral-small-latest", logoSymbol: "wind"),
        .init(id: "perplexity", name: "Perplexity", kind: .apiKey, hint: "API key", baseURL: "https://api.perplexity.ai", defaultModel: "sonar", logoSymbol: "magnifyingglass"),
        .init(id: "together", name: "Together AI", kind: .apiKey, hint: "API key", baseURL: "https://api.together.xyz/v1", defaultModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo", logoSymbol: "person.3"),
        .init(id: "fireworks", name: "Fireworks", kind: .apiKey, hint: "API key", baseURL: "https://api.fireworks.ai/inference/v1", defaultModel: "accounts/fireworks/models/llama-v3p1-70b-instruct", logoSymbol: "flame"),
        .init(id: "cerebras", name: "Cerebras", kind: .apiKey, hint: "API key", baseURL: "https://api.cerebras.ai/v1", defaultModel: "llama-3.3-70b", logoSymbol: "cpu"),
        .init(id: "cohere", name: "Cohere", kind: .apiKey, hint: "API key", baseURL: "https://api.cohere.com/compatibility/v1", defaultModel: "command-a-03-2025", logoSymbol: "c.circle"),
        .init(id: "nvidia", name: "NVIDIA", kind: .apiKey, hint: "API key", baseURL: "https://integrate.api.nvidia.com/v1", defaultModel: "meta/llama-3.1-70b-instruct", logoSymbol: "triangle"),
        .init(id: "siliconflow", name: "SiliconFlow", kind: .apiKey, hint: "API key", baseURL: "https://api.siliconflow.cn/v1", defaultModel: "deepseek-ai/DeepSeek-V3", logoSymbol: "square.stack.3d.up"),
        .init(id: "nebius", name: "Nebius", kind: .apiKey, hint: "API key", baseURL: "https://api.tokenfactory.nebius.com/v1", defaultModel: "meta-llama/Meta-Llama-3.1-70B-Instruct", logoSymbol: "cloud"),
        .init(id: "chutes", name: "Chutes", kind: .apiKey, hint: "API key", baseURL: "https://llm.chutes.ai/v1", defaultModel: "deepseek-ai/DeepSeek-V3", logoSymbol: "arrow.down.circle"),
        .init(id: "hyperbolic", name: "Hyperbolic", kind: .apiKey, hint: "API key", baseURL: "https://api.hyperbolic.xyz/v1", defaultModel: "meta-llama/Meta-Llama-3.1-70B-Instruct", logoSymbol: "circle.dotted"),
        .init(id: "vertex", name: "Vertex AI", kind: .apiKey, hint: "API key or Custom API", baseURL: "", defaultModel: "", logoSymbol: "cloud.fill"),
    ]

    public static func kind(for id: String) -> RouterProviderKind? { providers.first { $0.id == id } }
    public static func label(for id: String) -> String { id.hasPrefix("custom:") ? "Custom API" : kind(for: id)?.name ?? "Provider" }

    public static func hint(for id: String) -> String {
        let key = "provider.\(id).hint"
        let localized = AppCopy.text(key)
        return localized == key ? (kind(for: id)?.hint ?? "") : localized
    }

    public static func groups(from connections: [RouterConnection]) -> [ProviderAccountGroup] {
        var order: [String] = []
        var map: [String: [RouterConnection]] = [:]
        for connection in connections {
            if map[connection.provider] == nil { order.append(connection.provider) }
            map[connection.provider, default: []].append(connection)
        }
        return order.map { provider in
            ProviderAccountGroup(provider: provider, label: label(for: provider), accounts: map[provider] ?? [])
        }
    }

    public static func uniqueName(desired: String, provider: String, existing: [RouterConnection]) -> String {
        let trimmed = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = trimmed.isEmpty ? label(for: provider) : trimmed
        let taken = Set(existing.filter { $0.provider == provider }.map(\.name))
        if !taken.contains(seed) { return seed }
        var index = 2
        while taken.contains("\(seed) \(index)") { index += 1 }
        return "\(seed) \(index)"
    }
}

public struct ProviderAccountGroup: Identifiable, Sendable, Equatable {
    public var id: String { provider }
    public var provider: String
    public var label: String
    public var accounts: [RouterConnection]
}

public struct RouterConnection: Identifiable, Sendable, Equatable {
    public var id: String
    public var provider: String
    public var name: String
    public var email: String?
    public var active: Bool
    public var status: String
    public var authType: String
    public var error: String?

    public init(from account: StoredProviderAccount) {
        id = account.id; provider = account.provider; name = account.name; email = account.email
        active = account.active; status = account.status; authType = account.authType; error = account.error
    }

    public init(from object: JSONObject) {
        id = object["id"]?.string ?? UUID().uuidString
        provider = object["provider"]?.string ?? object["providerId"]?.string ?? "unknown"
        name = object["name"]?.string ?? object["email"]?.string ?? object["displayName"]?.string ?? AppCopy.text("router.unnamed")
        email = object["email"]?.string
        active = object["isActive"]?.bool ?? false
        status = object["testStatus"]?.string ?? AppCopy.text("router.unknown")
        authType = object["authType"]?.string ?? ""
        error = object["lastError"]?.string
    }
}

public struct RouterTunnel: Sendable, Equatable {
    public var enabled: Bool
    public var running: Bool
    public var tunnelURL: String
    public var publicURL: String
    public var shortId: String
    public var downloading: Bool
    public var progress: Int

    public static let idle = RouterTunnel(enabled: false, running: false, tunnelURL: "", publicURL: "", shortId: "", downloading: false, progress: 0)
    public var shareURL: String { publicURL.isEmpty ? tunnelURL : publicURL }

    public init(enabled: Bool, running: Bool, tunnelURL: String, publicURL: String, shortId: String, downloading: Bool, progress: Int) {
        self.enabled = enabled; self.running = running; self.tunnelURL = tunnelURL; self.publicURL = publicURL; self.shortId = shortId; self.downloading = downloading; self.progress = progress
    }
}

public enum CustomAPIKind: String, CaseIterable, Identifiable, Sendable, Hashable {
    case openai = "openai-compatible"
    case anthropic = "anthropic-compatible"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .openai: return AppCopy.text("custom.openAICompatible")
        case .anthropic: return AppCopy.text("custom.anthropicCompatible")
        }
    }
}

public enum CustomOpenAIAPIType: String, CaseIterable, Identifiable, Sendable, Hashable {
    case chat, responses
    public var id: String { rawValue }
}

public struct RouterNode: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var prefix: String
    public var type: String
    public var apiType: String?
    public var baseURL: String

    public init(from endpoint: StoredCustomEndpoint) {
        id = endpoint.id; name = endpoint.name; prefix = endpoint.prefix; type = endpoint.api; apiType = endpoint.apiType; baseURL = endpoint.baseURL
    }

    public init(from object: JSONObject) {
        id = object["id"]?.string ?? UUID().uuidString
        name = object["name"]?.string ?? AppCopy.text("router.custom")
        prefix = object["prefix"]?.string ?? ""
        type = object["type"]?.string ?? "openai-compatible"
        apiType = object["apiType"]?.string
        baseURL = object["baseUrl"]?.string ?? object["baseURL"]?.string ?? ""
    }
}

public struct RouterModel: Identifiable, Sendable, Equatable {
    public var id: String
    public var owner: String
    public var contextWindow: Int?
    public var tools: Bool

    public init(id: String, owner: String = "") { self.id = id; self.owner = owner; contextWindow = nil; tools = false }

    public init(from object: JSONObject) {
        id = object["id"]?.string ?? ""
        owner = object["owned_by"]?.string ?? object["ownedBy"]?.string ?? ""
        contextWindow = object["context_length"]?.int ?? object["contextWindow"]?.int
        tools = object["capabilities"]?["tools"]?.bool ?? false
    }
}

public struct RouterKey: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var key: String
    public var active: Bool

    public init(id: String, name: String, key: String, active: Bool = true) {
        self.id = id; self.name = name; self.key = key; self.active = active
    }
}
