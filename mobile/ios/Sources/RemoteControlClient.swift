import Foundation
import Security
import UIKit

enum RemoteJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: RemoteJSONValue])
    case array([RemoteJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: RemoteJSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([RemoteJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { return value }; return nil }
    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
}

struct ControlEvent: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let sequence: Int64
    let workspaceId: String
    let sessionId: String?
    let timestamp: Date
    let kind: String
    let payload: [String: RemoteJSONValue]
    let artifactId: String?
    let redacted: Bool
}

struct Bootstrap: Codable, Sendable {
    let protocolVersion: Int
    let workspaceId: String
    let workspace: String
    let revision: Int64
    let conversationId: String?
    let provider: String?
    let model: String?
    let status: String
    let isBusy: Bool
    let accessMode: String
    let capabilities: [String]
}

struct PairingResult: Codable, Sendable {
    let deviceId: String
    let deviceName: String
    let token: String
    let workspaceId: String
}

struct WorkspaceFile: Codable, Identifiable, Hashable, Sendable {
    let path: String
    let bytes: Int64
    let sha256: String
    let mode: Int
    var id: String { path }
}

struct ExcludedFile: Codable, Identifiable, Equatable, Sendable {
    let path: String
    let reason: String
    var id: String { path }
}

struct WorkspaceSnapshot: Codable, Sendable {
    let version: Int
    let workspaceId: String
    let workspace: String
    let revision: Int64
    let baseCommitSha: String?
    let files: [WorkspaceFile]
    let excluded: [ExcludedFile]
    let createdAt: Date
}

struct CommandResponse: Codable, Sendable {
    let commandId: String
    let status: String
    let httpStatus: Int?
    let approvalId: String?
    let result: RemoteJSONValue?
    let error: String?
}

struct PairRequest: Encodable { let code: String; let deviceName: String }
struct ControlCommand: Encodable {
    let id: String
    let workspaceId: String
    let sessionId: String?
    let kind: String
    let expectedRevision: Int64?
    let payload: [String: RemoteJSONValue]
}

private struct PairingPayload {
    let endpoint: String
    let code: String

    init?(url: URL) {
        guard url.scheme?.lowercased() == "herness", url.host?.lowercased() == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, items.count == 2,
              Set(items.map(\.name)) == Set(["endpoint", "code"]),
              let endpoint = components.queryItems?.first(where: { $0.name == "endpoint" })?.value,
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else { return nil }
        self.init(endpoint: endpoint, code: code)
    }

    init?(endpoint: String, code: String) {
        let normalized = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              code.count == 6,
              code.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else { return nil }
        self.endpoint = normalized
        self.code = code
    }
}

@MainActor
final class RemoteControlClient: ObservableObject {
    @Published var endpoint = ""
    @Published private(set) var token = ""
    @Published private(set) var bootstrap: Bootstrap?
    @Published private(set) var snapshot: WorkspaceSnapshot?
    @Published private(set) var events: [ControlEvent] = []
    @Published private(set) var isConnecting = false
    @Published private(set) var isPairing = false
    @Published private(set) var isGuest = UserDefaults.standard.bool(forKey: "herness.guest") || UserDefaults.standard.bool(forKey: "worksOffline")
    @Published var errorMessage: String?
    @Published var pairingEndpoint = ""
    @Published var pairingCode = ""

    private let session = URLSession(configuration: .default)
    private let secure = SecureStore()
    private var eventTask: Task<Void, Never>?
    private var lastSequence: Int64 = 0
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }()

    init() {
        endpoint = secure.read("endpoint") ?? ""
        token = secure.read("token") ?? ""
        if !endpoint.isEmpty, !token.isEmpty { Task { await connect() } }
    }

    var isPaired: Bool { !endpoint.isEmpty && !token.isEmpty }
    var workspaceID: String { bootstrap?.workspaceId ?? snapshot?.workspaceId ?? "" }

    func pair() async {
        guard let payload = PairingPayload(endpoint: pairingEndpoint, code: pairingCode) else {
            errorMessage = "Enter a valid HTTPS endpoint and six-digit code."
            return
        }
        await pair(payload)
    }

    private func pair(_ payload: PairingPayload) async {
        guard !isPairing else { return }
        guard let url = URL(string: payload.endpoint + "/v1/control/pair/complete") else { errorMessage = ClientError.invalidEndpoint.localizedDescription; return }
        isPairing = true
        defer { isPairing = false }
        do {
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try encoder.encode(PairRequest(code: payload.code, deviceName: UIDevice.current.name))
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data)
            let result = try decoder.decode(PairingResult.self, from: data)
            endpoint = payload.endpoint; token = result.token; isGuest = false; UserDefaults.standard.set(false, forKey: "herness.guest"); UserDefaults.standard.set(false, forKey: "worksOffline")
            secure.write(endpoint, key: "endpoint"); secure.write(token, key: "token")
            await connect()
        } catch { errorMessage = error.localizedDescription }
    }

    func consumePairURL(_ url: URL) {
        guard let payload = PairingPayload(url: url) else {
            errorMessage = "This QR code is not a valid HerNess pairing code."
            return
        }
        pairingEndpoint = payload.endpoint
        pairingCode = payload.code
        Task { await pair(payload) }
    }

    func continueAsGuest() {
        isGuest = true
        UserDefaults.standard.set(true, forKey: "herness.guest")
        UserDefaults.standard.set(true, forKey: "worksOffline")
        errorMessage = nil
    }

    func leaveGuest() {
        isGuest = false
        UserDefaults.standard.set(false, forKey: "herness.guest")
        UserDefaults.standard.set(false, forKey: "worksOffline")
    }

    func connect() async {
        guard let url = endpointURL("/v1/control/bootstrap") else { errorMessage = ClientError.invalidEndpoint.localizedDescription; return }
        isConnecting = true; defer { isConnecting = false }
        do {
            let (data, response) = try await request(url: url)
            try validate(response, data: data)
            bootstrap = try decoder.decode(Bootstrap.self, from: data)
            errorMessage = nil
            startEvents()
        } catch { errorMessage = error.localizedDescription }
    }

    func requestSnapshot() async {
        guard let url = endpointURL("/v1/control/snapshot/request") else { errorMessage = ClientError.invalidEndpoint.localizedDescription; return }
        do { let (data, response) = try await request(url: url, method: "POST"); try validate(response, data: data); snapshot = try decoder.decode(WorkspaceSnapshot.self, from: data) }
        catch { errorMessage = error.localizedDescription }
    }

    func readFile(_ path: String) async throws -> String {
        let data = try await readFileData(path)
        guard let text = String(data: data, encoding: .utf8) else { throw ClientError.binaryFile }
        return text
    }

    func readFileData(_ path: String) async throws -> Data {
        guard var components = URLComponents(url: try endpointURLOrThrow("/v1/control/file"), resolvingAgainstBaseURL: false) else { throw ClientError.invalidEndpoint }
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        let (data, response) = try await request(url: components.url!)
        try validate(response, data: data)
        return data
    }

    func artifactText(_ id: String) async throws -> String {
        let data = try await artifactData(id)
        guard let text = String(data: data, encoding: .utf8) else { throw ClientError.binaryFile }
        return text
    }

    func artifactData(_ id: String) async throws -> Data {
        guard var components = URLComponents(url: try endpointURLOrThrow("/v1/control/artifact"), resolvingAgainstBaseURL: false) else { throw ClientError.invalidEndpoint }
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        let (data, response) = try await request(url: components.url!)
        try validate(response, data: data)
        return data
    }

    @discardableResult
    func command(kind: String, payload: [String: RemoteJSONValue], expectedRevision: Int64? = nil) async throws -> CommandResponse {
        guard let url = endpointURL("/v1/control/commands"), !workspaceID.isEmpty else { throw ClientError.invalidEndpoint }
        let value = ControlCommand(id: UUID().uuidString, workspaceId: workspaceID, sessionId: bootstrap?.conversationId, kind: kind, expectedRevision: expectedRevision, payload: payload)
        let (data, response) = try await request(url: url, method: "POST", body: try encoder.encode(value))
        if let commandResponse = try? decoder.decode(CommandResponse.self, from: data), commandResponse.status == "conflict" { return commandResponse }
        try validate(response, data: data)
        return try decoder.decode(CommandResponse.self, from: data)
    }

    func savePhoneSecret(_ value: String, key: String) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { secure.delete("phone.\(key)") } else { secure.write(value, key: "phone.\(key)") }
    }

    func phoneSecret(_ key: String) -> String { secure.read("phone.\(key)") ?? "" }

    func disconnect() {
        eventTask?.cancel(); eventTask = nil; token = ""; endpoint = ""; bootstrap = nil; isGuest = false; UserDefaults.standard.set(false, forKey: "herness.guest"); UserDefaults.standard.set(false, forKey: "worksOffline"); secure.delete("endpoint"); secure.delete("token")
    }

    private func request(url: URL, method: String = "GET", body: Data? = nil) async throws -> (Data, URLResponse) {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.host != nil else { throw ClientError.invalidEndpoint }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }; return try await session.data(for: request)
    }

    private func endpointURL(_ path: String) -> URL? {
        let normalized = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: normalized), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.host != nil else { return nil }
        return URL(string: normalized + path)
    }

    private func endpointURLOrThrow(_ path: String) throws -> URL {
        guard let url = endpointURL(path) else { throw ClientError.invalidEndpoint }
        return url
    }

    private func startEvents() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let url = endpointURL("/v1/control/events?after=\(lastSequence)"), var request = URLRequest(url: url) as URLRequest? else { return }
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue(String(lastSequence), forHTTPHeaderField: "Last-Event-ID")
                    let (bytes, response) = try await session.bytes(for: request); guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ClientError.server("Event stream refused") }
                    var eventData = ""
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            if let data = eventData.data(using: .utf8), let event = try? decoder.decode(ControlEvent.self, from: data) { lastSequence = max(lastSequence, event.sequence); events.append(event); if events.count > 500 { events.removeFirst(events.count - 500) } }
                            eventData = ""
                        } else if line.hasPrefix("data: ") { eventData = String(line.dropFirst(6)) }
                    }
                } catch {
                    if !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
                }
            }
        }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw ClientError.server(String(data: data, encoding: .utf8) ?? "Remote request failed") }
    }
}

enum ClientError: LocalizedError {
    case invalidEndpoint, binaryFile, pathOutsideWorkspace, server(String)
    var errorDescription: String? { switch self { case .invalidEndpoint: return "The remote endpoint is invalid."; case .binaryFile: return "This file is not UTF-8 text."; case .pathOutsideWorkspace: return "That path is outside the workspace."; case .server(let message): return message } }
}

/// Keychain-backed store shared by the remote client and the on-phone agent.
final class SecureStore {
    private let service = "com.dots.herness.mobile"
    init() {}
    func read(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }; return String(data: data, encoding: .utf8)
    }
    func write(_ value: String, key: String) { let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]; SecItemDelete(query as CFDictionary); var item = query; item[kSecValueData as String] = Data(value.utf8); SecItemAdd(item as CFDictionary, nil) }
    func delete(_ key: String) { let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]; SecItemDelete(query as CFDictionary) }
}
