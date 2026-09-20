// Copyright (c) 2026 DOTS
// Native provider catalog. Metadata is local and does not require a helper process.

import Foundation
import HarnessPluginKit

public enum RouterAuthKind: String, Sendable, Hashable {
    case oauthBrowser
    case oauthDevice
    case apiKey
    case passthrough
}

public enum RouterAPIKind: String, Sendable, Hashable {
    case openAICompatible = "openai-compatible"
    case anthropic = "anthropic"
    case chatGPT = "chatgpt"
    case geminiCLI = "gemini-cli"
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
    /// Registry spec id. Equal to `id` for catalog providers.
    public var specID: String

    public init(
        id: String,
        name: String,
        kind: RouterAuthKind,
        hint: String,
        baseURL: String,
        defaultModel: String,
        api: RouterAPIKind = .openAICompatible,
        logoSymbol: String = "sparkles",
        specID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.hint = hint
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.api = api
        self.logoSymbol = logoSymbol
        self.specID = specID ?? id
    }

    init(spec: ProviderSpec) {
        self.init(
            id: spec.id,
            name: spec.name,
            kind: RouterCatalog.authKind(for: spec.category),
            hint: spec.hint,
            baseURL: spec.transport.baseURL,
            defaultModel: spec.defaultModel,
            api: RouterCatalog.apiKind(for: spec.transport.format),
            logoSymbol: spec.logoSymbol,
            specID: spec.id
        )
    }
}

public enum RouterCatalog {
    /// UI-facing provider list, derived from the data-driven registry.
    public static var providers: [RouterProviderKind] {
        ProviderRegistry.shared.specs.map(RouterProviderKind.init(spec:))
    }

    public static func spec(for id: String) -> ProviderSpec? { ProviderRegistry.shared.spec(id) }

    static func authKind(for category: ProviderSpec.Category) -> RouterAuthKind {
        switch category {
        case .oauth: return .oauthBrowser
        case .oauthDevice: return .oauthDevice
        case .apiKey: return .apiKey
        case .passthrough: return .passthrough
        }
    }

    static func apiKind(for format: ProviderSpec.Format) -> RouterAPIKind {
        switch format {
        case .openaiChat: return .openAICompatible
        case .anthropic: return .anthropic
        case .responses: return .chatGPT
        case .geminiCLI: return .geminiCLI
        }
    }

    public static func kind(for id: String) -> RouterProviderKind? { providers.first { $0.id == id } }
    public static func label(for id: String) -> String { id.hasPrefix("custom:") ? "Custom API" : kind(for: id)?.name ?? "Provider" }

    public static func modelGroups(for models: [RouterModel]) -> [RouterModelGroup] {
        var order: [String] = []
        var grouped: [String: [RouterModel]] = [:]
        for model in models where !model.id.isEmpty {
            let provider = model.provider.isEmpty ? (model.owner.isEmpty ? "unknown" : model.owner) : model.provider
            if grouped[provider] == nil { order.append(provider) }
            grouped[provider, default: []].append(model)
        }
        return order.compactMap { provider in
            guard let models = grouped[provider], !models.isEmpty else { return nil }
            let kind = self.kind(for: provider)
            return RouterModelGroup(
                provider: provider,
                name: kind?.name ?? models.first?.owner ?? provider,
                logoSymbol: kind?.logoSymbol ?? "sparkles",
                models: models
            )
        }
    }

    public static func modelDisplayName(for model: RouterModel) -> String {
        let declared = model.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDeclaredName = !(declared?.isEmpty ?? true)
        let source = hasDeclaredName ? declared! : (model.id.split(separator: "/").last.map(String.init) ?? model.id)
        let readable = hasDeclaredName ? source : source.replacingOccurrences(of: "-", with: " ")
        let prefixes = [kind(for: model.provider)?.name, model.owner, "Claude", "GPT", "OpenAI", "Gemini", "Grok"]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        let withoutProvider = prefixes.first(where: { prefix in
            readable.count > prefix.count
                && readable.lowercased().hasPrefix(prefix.lowercased())
                && readable.dropFirst(prefix.count).first == " "
        }).map { String(readable.dropFirst($0.count)).trimmingCharacters(in: .whitespacesAndNewlines) } ?? readable
        guard !withoutProvider.isEmpty else { return source }
        guard !hasDeclaredName else { return withoutProvider }
        return withoutProvider.split(separator: " ").map { word in
            switch word.lowercased() {
            case "gpt": return "GPT"
            case "glm": return "GLM"
            case "ai": return "AI"
            default: return word.capitalized
            }
        }.joined(separator: " ")
    }

    /// Dynamically infers effort levels for models not explicitly listed in `providers.json`,
    /// so new reasoning models automatically receive effort controls without app updates.
    public static func inferredEfforts(for modelID: String, provider: String = "") -> [String] {
        let lower = modelID.lowercased()
        let bare = lower.split(separator: "/").last.map(String.init) ?? lower
        if bare.contains("reasoner") || bare.contains("thinking")
            || bare.hasPrefix("o1") || bare.hasPrefix("o3") || bare.hasPrefix("o4")
            || bare.contains("-r1") || bare.contains("-r2") {
            return ["low", "medium", "high"]
        }
        if provider == "claude" || provider == "anthropic" || bare.hasPrefix("claude-") {
            if bare.contains("haiku") { return [] }
            if bare.contains("opus") || bare.contains("sonnet") || bare.contains("fable") {
                return ["low", "medium", "high", "max"]
            }
        }
        if provider == "gemini" || provider == "gemini-cli" || provider == "antigravity" || bare.hasPrefix("gemini-") {
            return ["low", "medium", "high"]
        }
        if bare.hasPrefix("gpt-5") {
            return ["none", "low", "medium", "high", "xhigh"]
        }
        if bare.hasPrefix("grok-4") {
            return ["low", "medium", "high", "xhigh"]
        }
        return []
    }

    public static func hint(for id: String) -> String {
        let key = "provider.\(id).hint"
        let localized = AppCopy.text(key)
        return localized == key ? (kind(for: id)?.hint ?? "") : localized
    }

    /// Groups accounts by provider, ordering the groups by the lowest `priority`
    /// among their accounts (the provider-priority the Settings reorder UI writes),
    /// insertion order breaking ties.
    public static func groups(from connections: [RouterConnection]) -> [ProviderAccountGroup] {
        var order: [String] = []
        var map: [String: [RouterConnection]] = [:]
        for connection in connections {
            if map[connection.provider] == nil { order.append(connection.provider) }
            map[connection.provider, default: []].append(connection)
        }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return order
            .sorted { lhs, rhs in
                let lp = map[lhs]?.map(\.priority).min() ?? 0
                let rp = map[rhs]?.map(\.priority).min() ?? 0
                if lp != rp { return lp < rp }
                return (rank[lhs] ?? 0) < (rank[rhs] ?? 0)
            }
            .map { provider in
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
    public var imageFallbackEnabled: Bool
    public var status: String
    public var authType: String
    public var priority: Int
    public var error: String?

    public init(from account: StoredProviderAccount) {
        id = account.id; provider = account.provider; name = account.name; email = account.email
        active = account.active; imageFallbackEnabled = account.imageFallbackEnabled; status = account.status; authType = account.authType
        priority = account.priority; error = account.error
    }

    public init(from object: JSONObject) {
        id = object["id"]?.string ?? UUID().uuidString
        provider = object["provider"]?.string ?? object["providerId"]?.string ?? "unknown"
        name = object["name"]?.string ?? object["email"]?.string ?? object["displayName"]?.string ?? AppCopy.text("router.unnamed")
        email = object["email"]?.string
        active = object["isActive"]?.bool ?? false
        imageFallbackEnabled = object["imageFallbackEnabled"]?.bool ?? false
        status = object["testStatus"]?.string ?? AppCopy.text("router.unknown")
        authType = object["authType"]?.string ?? ""
        priority = object["priority"]?.int ?? 0
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
    /// Reasoning-effort levels this model accepts, low to high. Empty hides the
    /// effort control rather than offering a level the provider rejects.
    public var efforts: [String] = []
    public var displayName: String?
    /// Provider spec id that resolved this model. Routing needs it because a
    /// model discovered from a live listing is not in the static registry.
    public var provider: String = ""
    /// Registry-declared tier. `nil` means automatic routing infers one from the id.
    public var tier: ModelTier?
    /// Registry-declared fast (priority) mode support.
    public var fast = false

    public init(
        id: String,
        owner: String = "",
        contextWindow: Int? = nil,
        efforts: [String] = [],
        displayName: String? = nil,
        provider: String = "",
        tier: ModelTier? = nil,
        fast: Bool = false
    ) {
        self.fast = fast
        self.id = id
        self.owner = owner
        self.contextWindow = contextWindow
        tools = false
        self.efforts = efforts
        self.displayName = displayName
        self.provider = provider
        self.tier = tier
    }

    public init(from object: JSONObject) {
        id = object["id"]?.string ?? ""
        owner = object["owned_by"]?.string ?? object["ownedBy"]?.string ?? ""
        contextWindow = object["context_length"]?.int ?? object["contextWindow"]?.int
        tools = object["capabilities"]?["tools"]?.bool ?? false
    }
}

public struct RouterModelGroup: Identifiable, Sendable, Equatable {
    public var id: String { provider }
    public let provider: String
    public let name: String
    public let logoSymbol: String
    public let models: [RouterModel]

    public init(provider: String, name: String, logoSymbol: String, models: [RouterModel]) {
        self.provider = provider
        self.name = name
        self.logoSymbol = logoSymbol
        self.models = models
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
