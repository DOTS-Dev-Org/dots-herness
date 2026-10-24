// Copyright (c) 2026 DOTS
// Native provider accounts, routing metadata, and the direct GPT login flow.

import AppKit
import Combine
import CryptoKit
import Foundation
import HarnessPluginKit
import Network
import PluginRuntime

public enum RouterFlow: Equatable {
    case idle
    case browser(provider: String, authURL: String, redirectURI: String, codeVerifier: String, state: String)
    case device(provider: String, userCode: String, verificationURL: String, deviceCode: String, codeVerifier: String?, extra: JSONObject)
}

public struct ConnectionTransition: Equatable, Sendable {
    public let action: String
    public let previousConnectionLabel: String?
    public let currentConnectionLabel: String?
    public let cleanupStatus: String
    public let removedLocalArtifacts: [String]
    public let remoteDataTouched: Bool
    public let userDataPreserved: Bool

    public init(action: String, previousConnectionLabel: String? = nil, currentConnectionLabel: String? = nil, cleanupStatus: String, removedLocalArtifacts: [String] = [], remoteDataTouched: Bool = false, userDataPreserved: Bool = true) {
        self.action = action
        self.previousConnectionLabel = previousConnectionLabel
        self.currentConnectionLabel = currentConnectionLabel
        self.cleanupStatus = cleanupStatus
        self.removedLocalArtifacts = removedLocalArtifacts
        self.remoteDataTouched = remoteDataTouched
        self.userDataPreserved = userDataPreserved
    }
}

@MainActor
public final class RouterController: ObservableObject {
    @Published public var connections: [RouterConnection] = []
    @Published public var tunnel = RouterTunnel.idle
    @Published public var keys: [RouterKey] = []
    @Published public var nodes: [RouterNode] = []
    @Published public var models: [RouterModel] = []
    /// The model the app routes with. Only `select(modelID:)` may change it, so the
    /// value is always empty (nothing chosen yet), the auto sentinel, or an id a
    /// catalog listed. Writing this directly would allow phantom models.
    @Published public internal(set) var selectedModelID: String = ""
    /// A model id that was chosen before any catalog knew it, kept only so it can be
    /// restored once a listing brings it back. Never routed or displayed as chosen.
    var pendingModelID: String?
    var usagePolling: Task<Void, Never>?
    /// Account id → earliest instant its usage may be polled again.
    var usageBackoff: [String: Date] = [:]
    /// Reasoning effort for the selected model. Empty means "provider default".
    @Published public var selectedEffort: String = ""
    /// Fast response speed; only honoured when `supportsFast` for the model.
    @Published public var fastMode = false
    /// Economy keeps the selected model/effort but trims optional output and
    /// model-facing history deterministically.
    @Published public var usageMode: AgentUsageMode = .standard
    /// Automatically try other compatible accounts when a provider reports a
    /// limit. Off by default so a conversation only changes accounts after the
    /// user presses Continue.
    @Published public var autoAccountFailoverAfterLimit = false
    public static let autoAccountFailoverAfterLimitKey = "agent.autoAccountFailoverAfterLimit"
    /// Persistent response prose preference. It is separate from Economy:
    /// changing this changes prose guidance, not the stable cache prefix.
    @Published public var responseStylePreference: AgentResponseStylePreference = .ultra
    /// The model the exploration subagent runs on; empty picks one automatically.
    @Published public var explorationModelID = ""
    /// A working fallback is reused for the rest of the short side-task window,
    /// keyed to the user's current exploration preference without changing it.
    var explorationRouteFallback: (preference: String, model: String, until: Date)?
    public static let explorationModelKey = "agent.explorationModel"
    /// Whether the run may delegate. Off until the user opts in because every side
    /// run creates additional provider requests and context.
    @Published public var subagentsPreference: Bool?
    public static let subagentsKey = "agent.subagentsEnabled"
    public var subagentsEnabled: Bool { subagentsPreference ?? false }
    /// What automatic routing picked for the last request, for the picker to show.
    @Published public internal(set) var lastAutoDecision: ModelDecision?
    /// Set when a request only succeeded after stepping past a provider that was out
    /// of quota, so the run can tell the user its model changed under it.
    @Published public internal(set) var lastFailover: String?
    @Published public var status: String = AppCopy.text("common.idle")
    @Published public var error: String?
    /// Providers whose live `/models` listing failed on the last refresh (`Provider: reason`); their registry models are still shown.
    @Published public var modelListIssues: [String] = []
    /// Live Claude subscription rate-limit usage. In-memory only, no persistence.
    @Published public var claudeUsage: ClaudeUsageState = .idle
    /// Per-account rate-limit picture keyed by account id. In-memory only.
    @Published public var accountUsage: [String: AccountUsageSnapshot] = [:]
    /// When each account's usage was last read. Kept out of `accountUsage` so an unchanged reading does not publish.
    var usageCheckedAt: [String: Date] = [:]
    /// The account and concrete model that actually served the most recent request.
    /// `AgentBridge` reads these to pin the conversation to that account.
    @Published public internal(set) var lastServedAccountID: String?
    @Published public internal(set) var lastServedModelID: String?
    @Published public var flow: RouterFlow = .idle
    @Published public var callbackPaste: String = ""
    @Published public var apiKeyName: String = ""
    @Published public var apiKeyValue: String = ""
    @Published public var selectedKind: RouterProviderKind = RouterCatalog.providers[0]
    @Published public var reachable = true
    @Published public var customName = "Local / Custom"
    @Published public var customPrefix = "custom"
    @Published public var customBaseURL = "http://127.0.0.1:11434/v1"
    @Published public var customAPIKey = ""
    /// Optional: the model to request when the server cannot list its models.
    @Published public var customModel = ""
    /// Optional context window in tokens; empty asks the server, then guesses.
    @Published public var customContextWindow = ""
    /// OpenAI-compatible servers already running on this machine.
    @Published public var detectedServers: [LocalServerDiscovery.Server] = []
    @Published public var customKind: CustomAPIKind = .openai
    @Published public var customAPIType: CustomOpenAIAPIType = .chat
    @Published public var editingNodeID: String?
    public var onConnectionChanged: ((ConnectionTransition) -> Void)?

    public let store: NativeProviderStore
    let modelCatalogCacheURL: URL
    public let imageAdapters: ProviderImageAdapterRegistry
    var gateway: ProviderGateway?
    let cloudTunnel: CloudTunnelProcess
    let oauthSession: URLSession
    var callbackListener: NWListener?
    var callbackConnection: NWConnection?
    var callbackPort = 1455
    var lastModelRefresh: Date?
    /// Live listings go stale as providers ship and retire models; re-fetch after this long.
    static let modelRefreshInterval: TimeInterval = 6 * 3600
    var modelRefreshTask: Task<Void, Never>?
    var claudeResetReturnObserver: AnyCancellable?
    var pendingClaudeResetAccountID: String?
    /// Effort resolved for the in-flight automatic route, including a supported
    /// user override when one was selected.
    var autoEffortOverride: String?

    public init(
        baseURL: String = "",
        paths: SupportPaths = .default(),
        imageAdapters: ProviderImageAdapterRegistry? = nil,
        oauthSession: URLSession = .shared,
        providerStore: NativeProviderStore? = nil
    ) {
        _ = baseURL
        store = providerStore ?? NativeProviderStore(paths: paths)
        modelCatalogCacheURL = paths.root.appendingPathComponent("provider-models.json")
        self.imageAdapters = imageAdapters ?? ProviderImageAdapterRegistry()
        BuiltInProviderImageAdapters.register(on: self.imageAdapters)
        self.oauthSession = oauthSession
        cloudTunnel = CloudTunnelProcess(runtimeURL: paths.runtime)
        gateway = try? ProviderGateway { [weak self] request in
            await self?.gatewayResponse(request) ?? .json(["error": ["message": "Gateway is unavailable"]], status: 503)
        }
        refreshState()
        observeClaudeResetReturn()
    }
}

public enum RouterTestError: Error, LocalizedError, Sendable {
    case http(Int)
    case message(String)
    public var errorDescription: String? {
        switch self { case .http(let code): return "Provider returned HTTP \(code)."; case .message(let message): return message }
    }
}
