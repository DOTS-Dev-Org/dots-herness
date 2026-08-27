// Copyright (c) 2026 DOTS
// Data-driven provider registry. Each provider (Claude, Codex/GPT, DeepSeek,
// OpenCode, …) is described by a spec loaded from a bundled `providers.json`,
// optionally overlaid by `<support>/providers.override.json` so new providers
// can ship without an app release. The OAuth engine and the agent transport
// read behaviour from these specs instead of hard-coding per-provider paths.

import Foundation
import PluginRuntime

public struct ProviderSpec: Codable, Sendable, Identifiable, Equatable {
    public enum Category: String, Codable, Sendable {
        case oauth
        case apiKey
        case passthrough
    }

    public enum Format: String, Codable, Sendable {
        case openaiChat = "openai-chat"
        case anthropic
        case responses
    }

    public enum Encoding: String, Codable, Sendable {
        case json
        case form
    }

    public enum Scheme: String, Codable, Sendable {
        case raw
        case bearer
    }

    public struct Quirks: Codable, Sendable, Equatable {
        public var cloakToolsOnOAuth: Bool = false
        public var injectAgentIdentity: String?

        public init(cloakToolsOnOAuth: Bool = false, injectAgentIdentity: String? = nil) {
            self.cloakToolsOnOAuth = cloakToolsOnOAuth
            self.injectAgentIdentity = injectAgentIdentity
        }
    }

    public struct Transport: Codable, Sendable, Equatable {
        public var baseURL: String
        public var format: Format
        public var urlSuffix: String?
        public var extraHeaders: [String: String] = [:]
        public var quirks: Quirks = Quirks()

        public init(
            baseURL: String,
            format: Format,
            urlSuffix: String? = nil,
            extraHeaders: [String: String] = [:],
            quirks: Quirks = Quirks()
        ) {
            self.baseURL = baseURL
            self.format = format
            self.urlSuffix = urlSuffix
            self.extraHeaders = extraHeaders
            self.quirks = quirks
        }
    }

    public struct OAuthSpec: Codable, Sendable, Equatable {
        public var clientID: String
        public var authorizeURL: String
        public var tokenURL: String
        public var scopes: String
        public var redirectURI: String
        public var callbackPort: Int
        public var tokenEncoding: Encoding = .form
        public var refreshEncoding: Encoding = .form
        /// Claude returns the authorization code as `code#state`; split on this.
        public var manualCodeSeparator: String?
        /// Provider-specific query items appended to the authorize URL.
        public var extraAuthorizeParams: [String: String] = [:]
        /// Extra form/JSON fields sent with the token + refresh requests.
        public var extraTokenParams: [String: String] = [:]
    }

    public struct APIKeySpec: Codable, Sendable, Equatable {
        public var header: String = "Authorization"
        public var scheme: Scheme = .bearer
        public var modelsURL: String?
    }

    public struct ModelSpec: Codable, Sendable, Equatable {
        public var id: String
        public var name: String?
    }

    public var id: String
    public var name: String
    public var category: Category
    public var logoSymbol: String = "sparkles"
    public var hint: String = ""
    public var transport: Transport
    public var oauth: OAuthSpec?
    public var apiKey: APIKeySpec?
    public var models: [ModelSpec] = []

    public var defaultModel: String { models.first?.id ?? "" }
}

public final class ProviderRegistry: @unchecked Sendable {
    public static let shared = ProviderRegistry()

    public private(set) var specs: [ProviderSpec]
    private let byID: [String: ProviderSpec]

    private init() {
        var loaded = Self.loadBundled()
        for override in Self.loadOverride() {
            if let index = loaded.firstIndex(where: { $0.id == override.id }) {
                loaded[index] = override
            } else {
                loaded.append(override)
            }
        }
        if loaded.isEmpty { loaded = Self.fallback }
        specs = loaded
        byID = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func spec(_ id: String) -> ProviderSpec? { byID[id] }

    private static func decode(_ data: Data) -> [ProviderSpec] {
        (try? JSONDecoder().decode([ProviderSpec].self, from: data)) ?? []
    }

    private static func loadBundled() -> [ProviderSpec] {
        guard let url = Bundle.module.url(forResource: "providers", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }

    private static func loadOverride() -> [ProviderSpec] {
        let url = SupportPaths.default().root.appendingPathComponent("providers.override.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }

    /// Minimal safety net if the bundled resource is ever missing.
    private static let fallback: [ProviderSpec] = [
        ProviderSpec(
            id: "openai", name: "OpenAI", category: .apiKey, logoSymbol: "hexagon", hint: "API key",
            transport: .init(baseURL: "https://api.openai.com/v1", format: .openaiChat),
            apiKey: .init(header: "Authorization", scheme: .bearer),
            models: [.init(id: "gpt-4.1-mini", name: nil)]
        ),
    ]
}
