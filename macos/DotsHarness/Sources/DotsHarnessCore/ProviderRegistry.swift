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

    // Synthesised Codable ignores property default values, so every struct that
    // has optional-in-JSON fields decodes them explicitly with a fallback. This
    // keeps `providers.json` lean.

    public struct Quirks: Codable, Sendable, Equatable {
        public var cloakToolsOnOAuth: Bool = false
        public var injectAgentIdentity: String?

        public init(cloakToolsOnOAuth: Bool = false, injectAgentIdentity: String? = nil) {
            self.cloakToolsOnOAuth = cloakToolsOnOAuth
            self.injectAgentIdentity = injectAgentIdentity
        }

        enum CodingKeys: String, CodingKey { case cloakToolsOnOAuth, injectAgentIdentity }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cloakToolsOnOAuth = try c.decodeIfPresent(Bool.self, forKey: .cloakToolsOnOAuth) ?? false
            injectAgentIdentity = try c.decodeIfPresent(String.self, forKey: .injectAgentIdentity)
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

        enum CodingKeys: String, CodingKey { case baseURL, format, urlSuffix, extraHeaders, quirks }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            baseURL = try c.decode(String.self, forKey: .baseURL)
            format = try c.decode(Format.self, forKey: .format)
            urlSuffix = try c.decodeIfPresent(String.self, forKey: .urlSuffix)
            extraHeaders = try c.decodeIfPresent([String: String].self, forKey: .extraHeaders) ?? [:]
            quirks = try c.decodeIfPresent(Quirks.self, forKey: .quirks) ?? Quirks()
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

        enum CodingKeys: String, CodingKey {
            case clientID, authorizeURL, tokenURL, scopes, redirectURI, callbackPort
            case tokenEncoding, refreshEncoding, manualCodeSeparator, extraAuthorizeParams, extraTokenParams
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clientID = try c.decode(String.self, forKey: .clientID)
            authorizeURL = try c.decode(String.self, forKey: .authorizeURL)
            tokenURL = try c.decode(String.self, forKey: .tokenURL)
            scopes = try c.decode(String.self, forKey: .scopes)
            redirectURI = try c.decode(String.self, forKey: .redirectURI)
            callbackPort = try c.decode(Int.self, forKey: .callbackPort)
            tokenEncoding = try c.decodeIfPresent(Encoding.self, forKey: .tokenEncoding) ?? .form
            refreshEncoding = try c.decodeIfPresent(Encoding.self, forKey: .refreshEncoding) ?? .form
            manualCodeSeparator = try c.decodeIfPresent(String.self, forKey: .manualCodeSeparator)
            extraAuthorizeParams = try c.decodeIfPresent([String: String].self, forKey: .extraAuthorizeParams) ?? [:]
            extraTokenParams = try c.decodeIfPresent([String: String].self, forKey: .extraTokenParams) ?? [:]
        }
    }

    public struct APIKeySpec: Codable, Sendable, Equatable {
        public var header: String = "Authorization"
        public var scheme: Scheme = .bearer
        public var modelsURL: String?

        public init(header: String = "Authorization", scheme: Scheme = .bearer, modelsURL: String? = nil) {
            self.header = header
            self.scheme = scheme
            self.modelsURL = modelsURL
        }

        enum CodingKeys: String, CodingKey { case header, scheme, modelsURL }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            header = try c.decodeIfPresent(String.self, forKey: .header) ?? "Authorization"
            scheme = try c.decodeIfPresent(Scheme.self, forKey: .scheme) ?? .bearer
            modelsURL = try c.decodeIfPresent(String.self, forKey: .modelsURL)
        }
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

    enum CodingKeys: String, CodingKey {
        case id, name, category, logoSymbol, hint, transport, oauth, apiKey, models
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decode(Category.self, forKey: .category)
        logoSymbol = try c.decodeIfPresent(String.self, forKey: .logoSymbol) ?? "sparkles"
        hint = try c.decodeIfPresent(String.self, forKey: .hint) ?? ""
        transport = try c.decode(Transport.self, forKey: .transport)
        oauth = try c.decodeIfPresent(OAuthSpec.self, forKey: .oauth)
        apiKey = try c.decodeIfPresent(APIKeySpec.self, forKey: .apiKey)
        models = try c.decodeIfPresent([ModelSpec].self, forKey: .models) ?? []
    }

    init(
        id: String, name: String, category: Category, logoSymbol: String = "sparkles",
        hint: String = "", transport: Transport, oauth: OAuthSpec? = nil,
        apiKey: APIKeySpec? = nil, models: [ModelSpec] = []
    ) {
        self.id = id; self.name = name; self.category = category; self.logoSymbol = logoSymbol
        self.hint = hint; self.transport = transport; self.oauth = oauth
        self.apiKey = apiKey; self.models = models
    }
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
        do {
            return try JSONDecoder().decode([ProviderSpec].self, from: data)
        } catch {
            FileHandle.standardError.write(Data("ProviderRegistry decode error: \(error)\n".utf8))
            return []
        }
    }

    private static func loadBundled() -> [ProviderSpec] {
        let candidates: [Bundle] = [.module] + Bundle.allBundles
        for bundle in candidates {
            if let url = bundle.url(forResource: "providers", withExtension: "json"),
               let data = try? Data(contentsOf: url) {
                return decode(data)
            }
            // Nested resource bundle (SwiftPM copies it as a sub-bundle).
            if let nested = bundle.url(forResource: "DotsHarness_DotsHarnessCore", withExtension: "bundle"),
               let sub = Bundle(url: nested),
               let url = sub.url(forResource: "providers", withExtension: "json"),
               let data = try? Data(contentsOf: url) {
                return decode(data)
            }
        }
        FileHandle.standardError.write(Data("ProviderRegistry: providers.json not found in any bundle\n".utf8))
        return []
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
