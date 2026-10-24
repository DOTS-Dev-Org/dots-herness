// Copyright (c) 2026 DOTS
// Data-driven provider registry. Each provider (Claude, Codex/GPT, DeepSeek,
// OpenCode, …) is described by a spec loaded from a bundled `providers.json`,
// optionally overlaid by `<support>/providers.override.json` so new providers
// can ship without an app release. The OAuth engine and the agent transport
// read behaviour from these specs instead of hard-coding per-provider paths.

import Foundation
import PluginRuntime

public struct ProviderMediaSpec: Codable, Sendable, Equatable {
    public var model: String
    public var path: String?
    /// Request shape when it is not the default one for the kind; music knows "elevenlabs".
    public var format: String?

    public init(model: String, path: String? = nil, format: String? = nil) {
        self.model = model
        self.path = path
        self.format = format
    }
}

public struct ProviderMediaCapabilities: Codable, Sendable, Equatable {
    public var image: ProviderMediaSpec?
    public var video: ProviderMediaSpec?
    public var audio: ProviderMediaSpec?
    public var music: ProviderMediaSpec?

    public init(
        image: ProviderMediaSpec? = nil,
        video: ProviderMediaSpec? = nil,
        audio: ProviderMediaSpec? = nil,
        music: ProviderMediaSpec? = nil
    ) {
        self.image = image
        self.video = video
        self.audio = audio
        self.music = music
    }

    public func spec(for kind: MediaKind) -> ProviderMediaSpec? {
        switch kind {
        case .image: return image
        case .video: return video
        case .audio: return audio
        case .music: return music
        }
    }
}

public struct ProviderSpec: Codable, Sendable, Identifiable, Equatable {
    public enum Category: String, Codable, Sendable {
        case oauth
        /// Browser-less sign-in: the user types a short code on the provider's site.
        case oauthDevice
        case apiKey
        case passthrough
    }

    public enum Format: String, Codable, Sendable {
        case openaiChat = "openai-chat"
        case anthropic
        case responses
        /// Google Cloud Code Assist: a Gemini payload wrapped in
        /// `{project, model, request}` and posted to a `:method` style URL.
        case geminiCLI = "gemini-cli"
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
        /// ChatGPT binds every Responses call to an account id; other backends on
        /// the same transport (Grok CLI) reject the header.
        public var requiresSessionAccountID: Bool = false
        /// Send the bundled Codex CLI system prompt as `instructions`. The ChatGPT
        /// backend validates it; other Responses backends take the caller's own.
        public var usesCodexInstructions: Bool = false
        /// Antigravity rides the Code Assist envelope but tags each call with the
        /// IDE's own client fields; plain Gemini Code Assist rejects them.
        public var antigravityEnvelope: Bool = false
        /// Opt-in only for a route that explicitly documents Responses compaction.
        /// The ChatGPT web/Codex route stays off because it is not the public API.
        public var supportsNativeCompaction: Bool = false

        public init(
            cloakToolsOnOAuth: Bool = false,
            injectAgentIdentity: String? = nil,
            requiresSessionAccountID: Bool = false,
            usesCodexInstructions: Bool = false,
            antigravityEnvelope: Bool = false,
            supportsNativeCompaction: Bool = false
        ) {
            self.antigravityEnvelope = antigravityEnvelope
            self.cloakToolsOnOAuth = cloakToolsOnOAuth
            self.injectAgentIdentity = injectAgentIdentity
            self.requiresSessionAccountID = requiresSessionAccountID
            self.usesCodexInstructions = usesCodexInstructions
            self.supportsNativeCompaction = supportsNativeCompaction
        }

        enum CodingKeys: String, CodingKey {
            case cloakToolsOnOAuth, injectAgentIdentity, requiresSessionAccountID, usesCodexInstructions
            case antigravityEnvelope, supportsNativeCompaction
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cloakToolsOnOAuth = try c.decodeIfPresent(Bool.self, forKey: .cloakToolsOnOAuth) ?? false
            injectAgentIdentity = try c.decodeIfPresent(String.self, forKey: .injectAgentIdentity)
            requiresSessionAccountID = try c.decodeIfPresent(Bool.self, forKey: .requiresSessionAccountID) ?? false
            usesCodexInstructions = try c.decodeIfPresent(Bool.self, forKey: .usesCodexInstructions) ?? false
            antigravityEnvelope = try c.decodeIfPresent(Bool.self, forKey: .antigravityEnvelope) ?? false
            supportsNativeCompaction = try c.decodeIfPresent(Bool.self, forKey: .supportsNativeCompaction) ?? false
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
        /// Present when the provider signs in by device code instead of a browser
        /// redirect (the user types a short code on the provider's site).
        public var deviceCodeURL: String?
        /// Google's CLI client is a "confidential" client: the token and refresh
        /// calls must carry this alongside the client id. It is public by design
        /// (it ships inside the CLI), not a user secret.
        public var clientSecret: String?
        /// Called once after sign-in to discover the Cloud Code Assist project id
        /// that every later request must name.
        public var projectDiscoveryURL: String?
        public var tokenEncoding: Encoding = .form
        public var refreshEncoding: Encoding = .form
        /// Claude returns the authorization code as `code#state`; split on this.
        public var manualCodeSeparator: String?
        /// Provider-specific query items appended to the authorize URL.
        public var extraAuthorizeParams: [String: String] = [:]
        /// Extra form/JSON fields sent with the token + refresh requests.
        public var extraTokenParams: [String: String] = [:]

        enum CodingKeys: String, CodingKey {
            case clientID, clientSecret, authorizeURL, tokenURL, scopes, redirectURI, callbackPort
            case deviceCodeURL, projectDiscoveryURL
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
            deviceCodeURL = try c.decodeIfPresent(String.self, forKey: .deviceCodeURL)
            clientSecret = try c.decodeIfPresent(String.self, forKey: .clientSecret)
            projectDiscoveryURL = try c.decodeIfPresent(String.self, forKey: .projectDiscoveryURL)
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
        /// Reasoning-effort levels this model accepts, low to high. Empty means the
        /// model rejects the effort parameter (e.g. Claude Haiku 4.5), so the
        /// picker hides the control instead of offering a level that 400s.
        public var efforts: [String] = []
        /// Capability/price band used by automatic routing. Absent means "infer
        /// from the model id", which is what live-discovered models get.
        public var tier: ModelTier?
        /// Optional provider-declared input context window. Live model metadata
        /// takes precedence when the endpoint publishes `context_length`.
        public var contextWindow: Int?
        /// Model offers a faster (priority) response mode.
        public var fast = false
        /// Older Anthropic extended-thinking models accept
        /// `thinking.budget_tokens`; adaptive-thinking models reject it.
        public var supportsLegacyThinkingBudget = false

        public init(id: String, name: String? = nil, efforts: [String] = [], tier: ModelTier? = nil, contextWindow: Int? = nil, fast: Bool = false, supportsLegacyThinkingBudget: Bool = false) {
            self.fast = fast
            self.supportsLegacyThinkingBudget = supportsLegacyThinkingBudget
            self.id = id
            self.name = name
            self.efforts = efforts
            self.tier = tier
            self.contextWindow = contextWindow
        }

        enum CodingKeys: String, CodingKey { case id, name, efforts, tier, contextWindow, fast, supportsLegacyThinkingBudget }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            efforts = try c.decodeIfPresent([String].self, forKey: .efforts) ?? []
            tier = try c.decodeIfPresent(ModelTier.self, forKey: .tier)
            contextWindow = try c.decodeIfPresent(Int.self, forKey: .contextWindow)
            fast = try c.decodeIfPresent(Bool.self, forKey: .fast) ?? false
            supportsLegacyThinkingBudget = try c.decodeIfPresent(Bool.self, forKey: .supportsLegacyThinkingBudget) ?? false
        }
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
    public var media: ProviderMediaCapabilities?

    public var defaultModel: String { models.first?.id ?? "" }

    enum CodingKeys: String, CodingKey {
        case id, name, category, logoSymbol, hint, transport, oauth, apiKey, models, media
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
        media = try c.decodeIfPresent(ProviderMediaCapabilities.self, forKey: .media)
    }

    init(
        id: String, name: String, category: Category, logoSymbol: String = "sparkles",
        hint: String = "", transport: Transport, oauth: OAuthSpec? = nil,
        apiKey: APIKeySpec? = nil, models: [ModelSpec] = [],
        media: ProviderMediaCapabilities? = nil
    ) {
        self.id = id; self.name = name; self.category = category; self.logoSymbol = logoSymbol
        self.hint = hint; self.transport = transport; self.oauth = oauth
        self.apiKey = apiKey; self.models = models; self.media = media
    }
}

public final class ProviderRegistry: @unchecked Sendable {
    public static let shared = ProviderRegistry()

    /// Published by `cloudflare/scripts/publish-model-catalog.mjs`.
    public static let remoteCatalogURL = URL(string: "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev/assets/catalog/models.json")!

    /// A remote catalog entry carries model lists and the client user-agent only.
    /// Endpoints, OAuth and credential headers stay bundled, so a tampered
    /// catalog can never redirect a token.
    struct RemoteCatalogEntry: Decodable {
        var id: String
        var models: [ProviderSpec.ModelSpec]?
        var userAgent: String?
    }

    private let lock = NSLock()
    private var loadedSpecs: [ProviderSpec]
    private var byID: [String: ProviderSpec]
    public var specs: [ProviderSpec] { lock.withLock { loadedSpecs } }

    private init() {
        loadedSpecs = Self.load()
        byID = Dictionary(loadedSpecs.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Bundled registry, then the cached remote catalog, then the user's override.
    private static func load() -> [ProviderSpec] {
        var loaded = Self.loadBundled()
        if let data = try? Data(contentsOf: remoteCacheURL),
           let entries = try? JSONDecoder().decode([RemoteCatalogEntry].self, from: data) {
            applyRemote(entries, to: &loaded)
        }
        for override in Self.loadOverride() {
            if let index = loaded.firstIndex(where: { $0.id == override.id }) {
                loaded[index] = override
            } else {
                loaded.append(override)
            }
        }
        return loaded.isEmpty ? Self.fallback : loaded
    }

    static func applyRemote(_ entries: [RemoteCatalogEntry], to specs: inout [ProviderSpec]) {
        for entry in entries {
            guard let index = specs.firstIndex(where: { $0.id == entry.id }) else { continue }
            if let models = entry.models, !models.isEmpty {
                // The published catalog may omit effort levels; keep the bundled ones.
                let bundled = specs[index].models
                specs[index].models = models.map { model in
                    guard model.efforts.isEmpty, let known = bundled.first(where: { $0.id == model.id }) else { return model }
                    var merged = model
                    merged.efforts = known.efforts
                    return merged
                }
            }
            if let userAgent = entry.userAgent, !userAgent.isEmpty,
               specs[index].transport.extraHeaders["user-agent"] != nil {
                specs[index].transport.extraHeaders["user-agent"] = userAgent
            }
        }
    }

    /// Fetches the remote catalog so new models reach installed apps without a
    /// release. Any failure keeps the cached or bundled registry.
    @discardableResult
    public func refreshRemote(session: URLSession = .shared) async -> Bool {
        let request = URLRequest(url: Self.remoteCatalogURL, timeoutInterval: 5)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              (try? JSONDecoder().decode([RemoteCatalogEntry].self, from: data)) != nil else { return false }
        let url = Self.remoteCacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        let loaded = Self.load()
        lock.withLock {
            loadedSpecs = loaded
            byID = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        }
        return true
    }

    public func spec(_ id: String) -> ProviderSpec? { lock.withLock { byID[id] } }

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

    private static var remoteCacheURL: URL {
        SupportPaths.default().root.appendingPathComponent("providers.remote.json")
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
            models: [.init(id: "gpt-5.6-luna", name: nil)],
            media: .init(
                video: .init(model: "sora-2"),
                audio: .init(model: "gpt-4o-mini-tts")
            )
        ),
    ]
}
