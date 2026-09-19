// Copyright (c) 2026 DOTS
// Native provider metadata and Keychain-backed credentials.

import Foundation
import PluginRuntime
import Security

public struct StoredProviderAccount: Codable, Sendable, Equatable {
    public var id: String
    public var provider: String
    public var name: String
    public var email: String?
    public var sessionAccountID: String?
    public var active: Bool
    public var imageFallbackEnabled: Bool
    public var status: String
    public var authType: String
    public var model: String
    public var baseURL: String
    public var api: String
    public var credentialID: String
    public var refreshCredentialID: String?
    public var priority: Int
    /// Set when this account last reported a rate/quota limit. Routing skips the
    /// account until this passes, then falls back to the usual ordering.
    public var cooldownUntil: Date?
    public var error: String?

    public init(
        id: String = UUID().uuidString,
        provider: String,
        name: String,
        email: String? = nil,
        sessionAccountID: String? = nil,
        active: Bool = true,
        imageFallbackEnabled: Bool = false,
        status: String = "connected",
        authType: String = "apiKey",
        model: String,
        baseURL: String,
        api: String = "openai-compatible",
        credentialID: String,
        refreshCredentialID: String? = nil,
        priority: Int = 0,
        cooldownUntil: Date? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.name = name
        self.email = email
        self.sessionAccountID = sessionAccountID
        self.active = active
        self.imageFallbackEnabled = imageFallbackEnabled
        self.status = status
        self.authType = authType
        self.model = model
        self.baseURL = baseURL
        self.api = api
        self.credentialID = credentialID
        self.refreshCredentialID = refreshCredentialID
        self.priority = priority
        self.cooldownUntil = cooldownUntil
        self.error = error
    }

    enum CodingKeys: String, CodingKey { case id, provider, name, email, sessionAccountID, active, imageFallbackEnabled, status, authType, model, baseURL, api, credentialID, refreshCredentialID, priority, cooldownUntil, error }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            provider: try values.decode(String.self, forKey: .provider),
            name: try values.decode(String.self, forKey: .name),
            email: try values.decodeIfPresent(String.self, forKey: .email),
            sessionAccountID: try values.decodeIfPresent(String.self, forKey: .sessionAccountID),
            active: try values.decodeIfPresent(Bool.self, forKey: .active) ?? true,
            imageFallbackEnabled: try values.decodeIfPresent(Bool.self, forKey: .imageFallbackEnabled) ?? false,
            status: try values.decodeIfPresent(String.self, forKey: .status) ?? "connected",
            authType: try values.decodeIfPresent(String.self, forKey: .authType) ?? "apiKey",
            model: try values.decode(String.self, forKey: .model),
            baseURL: try values.decode(String.self, forKey: .baseURL),
            api: try values.decodeIfPresent(String.self, forKey: .api) ?? RouterAPIKind.openAICompatible.rawValue,
            credentialID: try values.decode(String.self, forKey: .credentialID),
            refreshCredentialID: try values.decodeIfPresent(String.self, forKey: .refreshCredentialID),
            priority: try values.decodeIfPresent(Int.self, forKey: .priority) ?? 0,
            cooldownUntil: try values.decodeIfPresent(Date.self, forKey: .cooldownUntil),
            error: try values.decodeIfPresent(String.self, forKey: .error)
        )
    }
}

public struct StoredCustomEndpoint: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var prefix: String
    public var baseURL: String
    public var api: String
    public var apiType: String
    public var credentialID: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        prefix: String,
        baseURL: String,
        api: String,
        apiType: String,
        credentialID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.prefix = prefix
        self.baseURL = baseURL
        self.api = api
        self.apiType = apiType
        self.credentialID = credentialID
    }
}

public struct StoredProviderState: Codable, Sendable, Equatable {
    public var accounts: [StoredProviderAccount]
    public var endpoints: [StoredCustomEndpoint]
    public var selectedAccountID: String?

    public init(
        accounts: [StoredProviderAccount] = [],
        endpoints: [StoredCustomEndpoint] = [],
        selectedAccountID: String? = nil
    ) {
        self.accounts = accounts
        self.endpoints = endpoints
        self.selectedAccountID = selectedAccountID
    }
}

public enum ProviderStoreError: Error, LocalizedError, Sendable {
    case invalidEndpoint
    case credentialUnavailable
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Enter a valid HTTP or HTTPS endpoint."
        case .credentialUnavailable:
            return "The provider credential is not available in the system keychain."
        case .keychain(let status):
            return "The system keychain rejected the credential (status \(status))."
        }
    }
}

public final class ProviderVault: @unchecked Sendable {
    private let service = "com.dots.herness.providers"

    public init() {}

    public func set(_ value: String, for id: String) throws {
        guard let data = value.data(using: .utf8) else { throw ProviderStoreError.credentialUnavailable }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw ProviderStoreError.keychain(status) }
        } else if updateStatus != errSecSuccess {
            throw ProviderStoreError.keychain(updateStatus)
        }
    }

    public func get(_ id: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ProviderStoreError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw ProviderStoreError.credentialUnavailable
        }
        return value
    }

    public func remove(_ id: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderStoreError.keychain(status)
        }
    }
}

@MainActor
public final class NativeProviderStore {
    public private(set) var state: StoredProviderState
    public let vault: ProviderVault
    private let fileURL: URL

    public init(paths: SupportPaths, vault: ProviderVault = ProviderVault()) {
        paths.ensure()
        self.fileURL = paths.root.appendingPathComponent("provider-state.json")
        self.vault = vault
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(StoredProviderState.self, from: data) {
            self.state = decoded
        } else {
            self.state = StoredProviderState()
        }
        migratePlaintextSecrets()
        migrateRetiredModels()
    }

    /// Providers retire model ids (the Codex backend rejects anything outside its
    /// current list with HTTP 400). An account saved against a retired id would
    /// fail forever, so snap it to the spec's current default on load.
    private func migrateRetiredModels() {
        var changed = false
        for index in state.accounts.indices {
            let account = state.accounts[index]
            guard let spec = RouterCatalog.spec(for: account.provider), !spec.models.isEmpty else { continue }
            guard !spec.models.contains(where: { $0.id == account.model }) else { continue }
            state.accounts[index].model = spec.defaultModel
            changed = true
        }
        if changed { try? save() }
    }

    public func save() throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    @discardableResult
    public func addAccount(
        provider: RouterProviderKind,
        name: String,
        secret: String,
        model: String? = nil,
        baseURL: String? = nil,
        api: String? = nil,
        authType: String = "apiKey",
        email: String? = nil,
        sessionAccountID: String? = nil,
        refreshSecret: String? = nil,
        priority: Int = 0
    ) throws -> StoredProviderAccount {
        let id = UUID().uuidString
        let credentialID = "account.\(id)"
        try vault.set(secret, for: credentialID)
        let refreshCredentialID = refreshSecret.map { _ in "refresh.\(id)" }
        if let refreshSecret, let refreshCredentialID { try vault.set(refreshSecret, for: refreshCredentialID) }
        let account = StoredProviderAccount(
            id: id,
            provider: provider.id,
            name: uniqueName(name, provider: provider.id),
            email: email,
            sessionAccountID: sessionAccountID,
            active: true,
            status: "connected",
            authType: authType,
            model: model ?? provider.defaultModel,
            baseURL: try normalized(baseURL ?? provider.baseURL),
            api: api ?? provider.api.rawValue,
            credentialID: credentialID,
            refreshCredentialID: refreshCredentialID,
            priority: priority
        )
        state.accounts.append(account)
        if state.selectedAccountID == nil { state.selectedAccountID = account.id }
        try save()
        return account
    }

    public func addCustom(
        name: String,
        prefix: String,
        baseURL: String,
        api: String,
        apiType: String,
        secret: String
    ) throws -> StoredCustomEndpoint {
        let normalizedBaseURL = try normalized(baseURL)
        let id = UUID().uuidString
        let credentialID: String? = secret.isEmpty ? nil : "endpoint.\(id)"
        if let credentialID { try vault.set(secret, for: credentialID) }
        let endpoint = StoredCustomEndpoint(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            prefix: sanitizePrefix(prefix.isEmpty ? name : prefix),
            baseURL: normalizedBaseURL,
            api: api,
            apiType: apiType,
            credentialID: credentialID
        )
        state.endpoints.append(endpoint)
        try save()
        return endpoint
    }

    public func updateCustom(
        endpoint: StoredCustomEndpoint,
        name: String,
        prefix: String,
        baseURL: String,
        api: String,
        apiType: String,
        secret: String?
    ) throws {
        guard let index = state.endpoints.firstIndex(where: { $0.id == endpoint.id }) else { throw ProviderStoreError.invalidEndpoint }
        let normalizedBaseURL = try normalized(baseURL)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ProviderStoreError.invalidEndpoint }
        let sanitized = sanitizePrefix(prefix.isEmpty ? trimmedName : prefix)
        var credentialID = state.endpoints[index].credentialID
        if let secret {
            if secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let credentialID { try vault.remove(credentialID) }
                credentialID = nil
            } else {
                credentialID = credentialID ?? ("endpoint." + endpoint.id)
                try vault.set(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: credentialID!)
            }
        }
        state.endpoints[index] = StoredCustomEndpoint(id: endpoint.id, name: trimmedName, prefix: sanitized, baseURL: normalizedBaseURL, api: api, apiType: apiType, credentialID: credentialID)
        for accountIndex in state.accounts.indices where state.accounts[accountIndex].provider == ("custom:" + endpoint.id) {
            state.accounts[accountIndex].name = trimmedName
            state.accounts[accountIndex].model = sanitized + "/"
            state.accounts[accountIndex].baseURL = normalizedBaseURL
            state.accounts[accountIndex].api = api == CustomAPIKind.anthropic.rawValue ? RouterAPIKind.anthropic.rawValue : RouterAPIKind.openAICompatible.rawValue
            if let secret {
                if secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try vault.remove(state.accounts[accountIndex].credentialID) }
                else { try vault.set(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: state.accounts[accountIndex].credentialID) }
            }
        }
        try save()
    }

    @discardableResult
    public func addCustomAccount(
        endpoint: StoredCustomEndpoint,
        secret: String
    ) throws -> StoredProviderAccount {
        let id = UUID().uuidString
        let credentialID = "account.\(id)"
        if !secret.isEmpty { try vault.set(secret, for: credentialID) }
        let account = StoredProviderAccount(
            id: id,
            provider: "custom:\(endpoint.id)",
            name: endpoint.name,
            active: true,
            status: "connected",
            authType: "custom",
            model: "\(endpoint.prefix)/",
            baseURL: endpoint.baseURL,
            api: endpoint.api == CustomAPIKind.anthropic.rawValue ? RouterAPIKind.anthropic.rawValue : RouterAPIKind.openAICompatible.rawValue,
            credentialID: credentialID
        )
        state.accounts.append(account)
        if state.selectedAccountID == nil { state.selectedAccountID = account.id }
        try save()
        return account
    }

    public func credential(for account: StoredProviderAccount) throws -> String? {
        try vault.get(account.credentialID)
    }

    public func refreshCredential(for account: StoredProviderAccount) throws -> String? {
        guard let id = account.refreshCredentialID else { return nil }
        return try vault.get(id)
    }

    public func credential(for endpoint: StoredCustomEndpoint) throws -> String? {
        guard let id = endpoint.credentialID else { return nil }
        return try vault.get(id)
    }

    public func replaceCredential(for account: StoredProviderAccount, with value: String) throws {
        try vault.set(value, for: account.credentialID)
    }

    public func replaceRefreshCredential(for account: StoredProviderAccount, with value: String) throws {
        guard let id = account.refreshCredentialID else { return }
        try vault.set(value, for: id)
    }

    public func updateSessionAccountID(for account: StoredProviderAccount, with value: String) throws {
        guard let index = state.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        state.accounts[index].sessionAccountID = value
        try save()
    }

    public func setActive(_ accountID: String, _ active: Bool) throws {
        guard let index = state.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        state.accounts[index].active = active
        try save()
    }

    public func setImageFallback(_ accountID: String, _ enabled: Bool) throws {
        guard let index = state.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        state.accounts[index].imageFallbackEnabled = enabled
        try save()
    }

    public func setSelected(_ accountID: String?) throws {
        state.selectedAccountID = accountID
        try save()
    }

    public func removeAccount(_ account: StoredProviderAccount) throws {
        try vault.remove(account.credentialID)
        if let refreshCredentialID = account.refreshCredentialID { try vault.remove(refreshCredentialID) }
        state.accounts.removeAll { $0.id == account.id }
        if state.selectedAccountID == account.id { state.selectedAccountID = state.accounts.first?.id }
        try save()
    }

    public func removeEndpoint(_ endpoint: StoredCustomEndpoint) throws {
        if let id = endpoint.credentialID { try vault.remove(id) }
        state.endpoints.removeAll { $0.id == endpoint.id }
        let accountIDs = state.accounts.filter { $0.provider == "custom:\(endpoint.id)" }
        for account in accountIDs {
            try vault.remove(account.credentialID)
            if let refreshID = account.refreshCredentialID { try vault.remove(refreshID) }
        }
        state.accounts.removeAll { $0.provider == "custom:\(endpoint.id)" }
        if accountIDs.contains(where: { $0.id == state.selectedAccountID }) { state.selectedAccountID = state.accounts.first?.id }
        try save()
    }

    public func setPriority(_ accountID: String, _ priority: Int) throws {
        guard let index = state.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        state.accounts[index].priority = priority
        try save()
    }

    /// Records (or clears, with `nil`) a rate/quota cooldown for one account.
    public func setCooldown(_ accountID: String, until date: Date?) throws {
        guard let index = state.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        guard state.accounts[index].cooldownUntil != date else { return }
        state.accounts[index].cooldownUntil = date
        try save()
    }

    public func shareKey() throws -> String? { try vault.get("share.key") }

    public func createShareKey() throws -> String {
        let bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        let value = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try vault.set(value, for: "share.key")
        return value
    }

    private func uniqueName(_ desired: String, provider: String) -> String {
        let seed = desired.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? RouterCatalog.label(for: provider)
            : desired.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(state.accounts.filter { $0.provider == provider }.map(\.name))
        if !taken.contains(seed) { return seed }
        var index = 2
        while taken.contains("\(seed) \(index)") { index += 1 }
        return "\(seed) \(index)"
    }

    private func migratePlaintextSecrets() {
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        do {
            var changed = false
            for item in root["accounts"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String,
                      let secret = Self.plaintextSecret(item),
                      let index = state.accounts.firstIndex(where: { $0.id == id }) else { continue }
                if state.accounts[index].credentialID.isEmpty { state.accounts[index].credentialID = "account." + id }
                try vault.set(secret, for: state.accounts[index].credentialID)
                guard try vault.get(state.accounts[index].credentialID) == secret else { throw ProviderStoreError.credentialUnavailable }
                changed = true
            }
            for item in root["endpoints"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String,
                      let secret = Self.plaintextSecret(item),
                      let index = state.endpoints.firstIndex(where: { $0.id == id }) else { continue }
                if state.endpoints[index].credentialID == nil { state.endpoints[index].credentialID = "endpoint." + id }
                try vault.set(secret, for: state.endpoints[index].credentialID!)
                guard try vault.get(state.endpoints[index].credentialID!) == secret else { throw ProviderStoreError.credentialUnavailable }
                changed = true
            }
            if changed { try save() }
        } catch {
            // Keep the source JSON intact until every migrated value is verified.
        }
    }

    private static func plaintextSecret(_ object: [String: Any]) -> String? {
        for key in ["apiKey", "api_key", "secret", "token"] {
            if let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return nil
    }

    private func normalized(_ value: String) throws -> String {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host != nil, components.user == nil, components.password == nil else {
            throw ProviderStoreError.invalidEndpoint
        }
        var path = components.path
        while path.hasSuffix("/v1/v1") { path = String(path.dropLast(3)) }
        components.path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? ""
            : "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? value
    }

    private func sanitizePrefix(_ value: String) -> String {
        let kept = value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(kept).split(separator: "-").joined(separator: "-")
        return String(collapsed.prefix(24))
    }
}
