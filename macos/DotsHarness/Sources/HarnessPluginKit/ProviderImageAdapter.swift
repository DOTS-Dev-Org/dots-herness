import Foundation

public struct ProviderImageRoute: Sendable, Equatable {
    public var accountID: String
    public var providerID: String
    public var baseURL: String
    public var api: String
    public var model: String
    public var authType: String
    public var sessionAccountID: String?

    public init(
        accountID: String,
        providerID: String,
        baseURL: String,
        api: String,
        model: String,
        authType: String = "",
        sessionAccountID: String? = nil
    ) {
        self.accountID = accountID
        self.providerID = providerID
        self.baseURL = baseURL
        self.api = api
        self.model = model
        self.authType = authType
        self.sessionAccountID = sessionAccountID
    }
}

public enum ProviderImageAuthentication: Sendable, Equatable {
    case none
    case bearer
    case rawHeader(String)
}

public struct ProviderImageRequest: Sendable, Equatable {
    public var url: URL
    public var body: Data
    public var headers: [String: String]
    public var authentication: ProviderImageAuthentication

    public init(
        url: URL,
        body: Data,
        headers: [String: String] = [:],
        authentication: ProviderImageAuthentication = .bearer
    ) {
        self.url = url
        self.body = body
        self.headers = headers
        self.authentication = authentication
    }
}

public struct ProviderImageOutput: Sendable, Equatable {
    public var data: Data
    public var mimeType: String

    public init(data: Data, mimeType: String = "image/png") {
        self.data = data
        self.mimeType = mimeType
    }
}

public enum ProviderImageFailureKind: String, Sendable, Equatable {
    case auth
    case network
    case rateLimit
    case server
    case safety
    case invalidOutput
    case other
}

public struct ProviderImageFailure: Sendable, Equatable {
    public var kind: ProviderImageFailureKind
    public var message: String

    public init(kind: ProviderImageFailureKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public enum ProviderImageResult: Sendable, Equatable {
    case generated(ProviderImageOutput)
    case unsupported(String)
    case failed(ProviderImageFailure)
}

public enum ProviderImageCapability: String, Sendable, Equatable {
    case supported
    case unsupported
}

public protocol ProviderImageAdapter: AnyObject {
    var id: String { get }
    var isFallbackOnly: Bool { get }
    func matches(_ route: ProviderImageRoute) -> Bool
    func prepareImageRequest(prompt: String, model: String, route: ProviderImageRoute) throws -> ProviderImageRequest
    func parseImageResponse(data: Data, status: Int, headers: [String: String]) -> ProviderImageResult
}

public extension ProviderImageAdapter {
    var isFallbackOnly: Bool { false }
}

public enum ProviderImageAdapterRegistryError: Error, LocalizedError, Sendable, Equatable {
    case untrustedPlugin

    public var errorDescription: String? {
        switch self {
        case .untrustedPlugin: return "Only trusted native plugins can register network image adapters."
        }
    }
}

@MainActor
public final class ProviderImageAdapterRegistry {
    private struct Entry {
        var owner: String
        var adapter: any ProviderImageAdapter
    }

    private var entries: [Entry] = []
    private var capabilities: [String: ProviderImageCapability] = [:]

    public init() {}

    public func register(
        _ adapter: any ProviderImageAdapter,
        owner: String,
        trust: PluginTrust
    ) throws -> () {
        guard trust != .untrusted else { throw ProviderImageAdapterRegistryError.untrustedPlugin }
        entries.removeAll { $0.owner == owner && $0.adapter.id == adapter.id }
        capabilities.keys
            .filter { $0.contains("|\(adapter.id)|") }
            .forEach { capabilities.removeValue(forKey: $0) }
        entries.append(Entry(owner: owner, adapter: adapter))
    }

    public func unregister(owner: String) {
        let removedIDs = entries.filter { $0.owner == owner }.map { $0.adapter.id }
        entries.removeAll { $0.owner == owner }
        for id in removedIDs {
            capabilities.keys
                .filter { $0.contains("|\(id)|") }
                .forEach { capabilities.removeValue(forKey: $0) }
        }
    }

    public func adapter(for route: ProviderImageRoute, includeFallbackOnly: Bool = false) -> (any ProviderImageAdapter)? {
        entries.reversed().first {
            $0.adapter.matches(route) && (includeFallbackOnly || !$0.adapter.isFallbackOnly)
        }?.adapter
    }

    public func capability(for route: ProviderImageRoute, adapterID: String) -> ProviderImageCapability? {
        capabilities[key(for: route, adapterID: adapterID)]
    }

    public func record(_ capability: ProviderImageCapability, for route: ProviderImageRoute, adapterID: String) {
        capabilities[key(for: route, adapterID: adapterID)] = capability
    }

    public func hasRegisteredAdapter(for route: ProviderImageRoute) -> Bool {
        adapter(for: route) != nil
    }

    public var registeredAdapterIDs: [String] {
        Array(Set(entries.map { $0.adapter.id })).sorted()
    }

    private func key(for route: ProviderImageRoute, adapterID: String) -> String {
        "\(route.accountID)|\(route.baseURL)|\(adapterID)|\(route.model)"
    }
}
