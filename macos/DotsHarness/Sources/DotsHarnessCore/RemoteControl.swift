// Copyright (c) 2026 DOTS
// Native remote-control gateway for the macOS host.

import CryptoKit
import Combine
import Darwin
import Foundation
import Network
import PluginRuntime
import Security

public enum RemoteAccessMode: String, Codable, Sendable {
    case ask
    case approve
    case full
}

public enum RemoteJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: RemoteJSONValue])
    case array([RemoteJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let object = try? value.decode([String: RemoteJSONValue].self) { self = .object(object) }
        else if let array = try? value.decode([RemoteJSONValue].self) { self = .array(array) }
        else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { return value }; return nil }
    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    var int: Int? { if case .number(let value) = self { return Int(value) }; return nil }
    var strings: [String]? { if case .array(let values) = self { return values.compactMap(\.string) }; return nil }
}

public struct RemoteControlEvent: Codable, Sendable, Equatable {
    public let id: String
    public let sequence: Int64
    public let workspaceId: String
    public let sessionId: String?
    public let timestamp: Date
    public let kind: String
    public let payload: [String: RemoteJSONValue]
    public let artifactId: String?
    public let redacted: Bool
}

public struct RemotePairingInfo: Codable, Sendable, Equatable {
    public let endpoint: String
    public let code: String
    public let payload: String
    public let expiresAt: Date
}

public struct RemotePairingResult: Codable, Sendable, Equatable {
    public let deviceId: String
    public let deviceName: String
    public let token: String
    public let workspaceId: String
}

public struct RemotePairingDevice: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let createdAt: Date
    public let revoked: Bool
}

public struct RemoteBootstrap: Codable, Sendable {
    public let protocolVersion: Int
    public let scope: String
    public let workspaceId: String
    public let workspace: String
    public let revision: Int64
    public let conversationId: String?
    public let provider: String?
    public let model: String?
    public let status: String
    public let isBusy: Bool
    public let accessMode: RemoteAccessMode
    public let capabilities: [String]
    public let devices: [RemotePairingDevice]
    public let projectID: String?
}

public struct RemoteProjectDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let workspaceId: String
    public let branch: String?
    let workspacePath: String

    enum CodingKeys: String, CodingKey { case id, name, workspaceId, branch }

    public init(id: String, name: String, workspaceId: String, branch: String? = nil, workspacePath: String) {
        self.id = id
        self.name = name
        self.workspaceId = workspaceId
        self.branch = branch
        self.workspacePath = workspacePath
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        workspaceId = try values.decode(String.self, forKey: .workspaceId)
        branch = try values.decodeIfPresent(String.self, forKey: .branch)
        workspacePath = ""
    }
}

private struct RemoteProjectsResponse: Codable, Sendable {
    let protocolVersion: Int
    let projectID: String?
    let projects: [RemoteProjectDescriptor]
}

private struct RemoteProjectSelection: Codable, Sendable {
    let projectID: String
    let workspaceId: String
}

public struct RemoteWorkspaceFile: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let bytes: Int64
    public let sha256: String
    public let mode: Int
    public var id: String { path }
}

public struct RemoteExcludedPath: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let reason: String
    public var id: String { path }
}

public struct RemoteWorkspaceSnapshot: Codable, Sendable {
    public let version: Int
    public let workspaceId: String
    public let workspace: String
    public let revision: Int64
    public let baseCommitSha: String?
    public let files: [RemoteWorkspaceFile]
    public let excluded: [RemoteExcludedPath]
    public let createdAt: Date
}

public struct RemoteFileWriteResult: Codable, Sendable {
    public let written: Bool
    public let conflict: Bool
    public let path: String
    public let sha256: String
    public let currentSha256: String?
    public let message: String
}

public struct RemoteArtifactInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let kind: String
    public let bytes: Int64
    public let createdAt: Date
}

public final class RemoteEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private var history: [RemoteControlEvent] = []
    private var sequence: Int64 = 0
    private var streams: [UUID: AsyncStream<RemoteControlEvent>.Continuation] = [:]

    public init(root: URL) {
        self.root = root.appendingPathComponent("remote-artifacts", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    @discardableResult
    public func publish(
        _ kind: String,
        workspaceId: String,
        sessionId: String? = nil,
        payload: [String: RemoteJSONValue] = [:],
        artifactId: String? = nil,
        redacted: Bool = false
    ) -> RemoteControlEvent {
        let sanitized = Self.sanitize(payload)
        lock.lock(); defer { lock.unlock() }
        sequence += 1
        let event = RemoteControlEvent(
            id: UUID().uuidString,
            sequence: sequence,
            workspaceId: workspaceId,
            sessionId: sessionId,
            timestamp: Date(),
            kind: kind,
            payload: sanitized.payload,
            artifactId: artifactId,
            redacted: redacted || sanitized.redacted
        )
        history.append(event)
        if history.count > 2_000 { history.removeFirst(history.count - 2_000) }
        streams.values.forEach { _ = $0.yield(event) }
        return event
    }

    private static func sanitize(_ payload: [String: RemoteJSONValue]) -> (payload: [String: RemoteJSONValue], redacted: Bool) {
        var changed = false
        let values = payload.reduce(into: [String: RemoteJSONValue]()) { result, item in
            result[item.key] = sanitize(key: item.key, value: item.value, changed: &changed)
        }
        return (values, changed)
    }

    private static func sanitize(key: String, value: RemoteJSONValue, changed: inout Bool) -> RemoteJSONValue {
        if isSensitiveKey(key) {
            changed = true
            return .string("[redacted]")
        }
        switch value {
        case .string(let text):
            let safe = sanitizeText(text)
            if safe != text { changed = true }
            return .string(safe)
        case .object(let object):
            let nested = sanitize(object)
            if nested.redacted { changed = true }
            return .object(nested.payload)
        case .array(let array):
            return .array(array.map { sanitize(key: key, value: $0, changed: &changed) })
        default:
            return value
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "").lowercased()
        return ["apikey", "token", "accesstoken", "refreshtoken", "secret", "password", "authorization"].contains(normalized)
            || normalized.contains("credential")
    }

    private static func sanitizeText(_ value: String) -> String {
        let pattern = #"(?i)(api[_ -]?key|access[_ -]?token|refresh[_ -]?token|client[_ -]?secret|password|authorization)\s*[:=]\s*\S+|\bBearer\s+\S+|\b(?:sk|ghp|github_pat|xox[baprs])[-_][A-Za-z0-9_-]{12,}\b"#
        return value.range(of: pattern, options: .regularExpression) == nil ? value : "[redacted]"
    }

    @discardableResult
    public func publishText(
        _ kind: String,
        workspaceId: String,
        sessionId: String?,
        text: String,
        payload: [String: RemoteJSONValue] = [:]
    ) -> RemoteControlEvent {
        let bytes = text.utf8.count
        let artifactId = saveArtifact(kind: kind, text: text)
        var data = payload
        data["bytes"] = .number(Double(bytes))
        data["preview"] = .string("Output captured in a local artifact.")
        let truncated = bytes > 50 * 1024 * 1024 || text.localizedCaseInsensitiveContains("[truncated]")
        data["truncated"] = .bool(truncated)
        if truncated { data["warning"] = .string("Output limit reached. Open the full artifact for the captured output.") }
        return publish(kind, workspaceId: workspaceId, sessionId: sessionId, payload: data, artifactId: artifactId)
    }

    public func stream(after: Int64, workspaceId: String) -> AsyncStream<RemoteControlEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            history.filter { $0.sequence > after && $0.workspaceId == workspaceId }.forEach { _ = continuation.yield($0) }
            streams[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.streams.removeValue(forKey: id)
                self?.lock.unlock()
            }
        }
    }

    public func artifactURL(_ id: String) -> URL? {
        guard id.count > 0, id.allSatisfy({ $0.isNumber || $0 == "-" || $0.isLetter }) else { return nil }
        let url = root.appendingPathComponent(id).appendingPathExtension("artifact")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func artifactList() -> [RemoteArtifactInfo] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "artifact" }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            let kind = (try? String(contentsOf: url.appendingPathExtension("meta"), encoding: .utf8)) ?? "artifact"
            return RemoteArtifactInfo(id: url.deletingPathExtension().lastPathComponent, kind: kind, bytes: Int64(values.fileSize ?? 0), createdAt: values.contentModificationDate ?? Date())
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public func saveArtifact(kind: String, data: Data) -> String {
        let id = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let url = root.appendingPathComponent(id).appendingPathExtension("artifact")
        try? data.prefix(50 * 1024 * 1024).write(to: url)
        try? Data(kind.utf8).write(to: url.appendingPathExtension("meta"))
        return id
    }

    private func saveArtifact(kind: String, text: String) -> String { saveArtifact(kind: kind, data: Data(text.utf8)) }
}

private final class RemoteKeychain: @unchecked Sendable {
    private let service = "com.dots.herness.remote-control"

    func write(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw RouterTestError.message("The macOS Keychain is unavailable.") }
    }

    func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

private final class RemotePairingStore: @unchecked Sendable {
    private struct Device: Codable {
        let id: String
        let name: String
        let createdAt: Date
        var revoked: Bool
    }
    private struct Persisted: Codable { var devices: [Device] }
    private let lock = NSLock()
    private let file: URL
    private let keychain = RemoteKeychain()
    private var workspaceId: String
    private var devices: [Device]
    private var challenge: (endpoint: String, code: String, expiresAt: Date)?

    init(root: URL, workspaceId: String) {
        file = root.appendingPathComponent("remote-control.json")
        self.workspaceId = workspaceId
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder.remote.decode(Persisted.self, from: data) { devices = saved.devices } else { devices = [] }
    }

    func setWorkspaceId(_ value: String) { lock.lock(); workspaceId = value; lock.unlock() }

    func begin(endpoint: String) -> RemotePairingInfo {
        let code = String(format: "%06d", Int.random(in: 100_000...999_999))
        let expires = Date().addingTimeInterval(300)
        lock.lock(); challenge = (endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")), code, expires); lock.unlock()
        let payload = "herness://pair?endpoint=\(endpoint.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? endpoint)&code=\(code)"
        return RemotePairingInfo(endpoint: endpoint, code: code, payload: payload, expiresAt: expires)
    }

    func complete(code: String, name: String?) -> RemotePairingResult? {
        lock.lock(); defer { lock.unlock() }
        guard let challenge, challenge.expiresAt > Date(), challenge.code == code.trimmingCharacters(in: .whitespacesAndNewlines) else { self.challenge = nil; return nil }
        self.challenge = nil
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let token = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let safeName = String((name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? name! : "Phone").prefix(80))
        devices.append(Device(id: id, name: safeName, createdAt: Date(), revoked: false))
        try? keychain.write(token, account: "remote.device.\(id)")
        save()
        return RemotePairingResult(deviceId: id, deviceName: safeName, token: token, workspaceId: workspaceId)
    }

    func authenticate(_ token: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let hash = digest(token)
        return devices.first(where: { !$0.revoked && keychain.read(account: "remote.device.\($0.id)").map(Self.digest) == hash })?.id
    }

    func list() -> [RemotePairingDevice] {
        lock.lock(); defer { lock.unlock() }
        return devices.map { RemotePairingDevice(id: $0.id, name: $0.name, createdAt: $0.createdAt, revoked: $0.revoked) }
    }

    func revoke(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return false }
        devices[index].revoked = true
        keychain.delete(account: "remote.device.\(id)")
        save()
        return true
    }

    private func save() { try? JSONEncoder.remote.encode(Persisted(devices: devices)).write(to: file, options: .atomic) }
    private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func digest(_ value: String) -> String { Self.digest(value) }
}

private struct RemoteHTTPResponse {
    let status: Int
    let contentType: String
    let body: Data
}

private struct RemoteHTTPRequest {
    let method: String
    let target: String
    let path: String
    let headers: [String: String]
    let body: Data
}

@MainActor
public final class RemoteControlHost {
    public static let port: UInt16 = 18_768
    /// Remote build/deploy commands run outside any chat, so their read/write
    /// ledger gets its own scope instead of borrowing the selected conversation.
    nonisolated static let ledgerScope = "remote-control"
    public let events: RemoteEventHub
    public private(set) var pairing: RemotePairingInfo?
    public private(set) var publicEndpoint: String?
    public var accessMode: RemoteAccessMode { access }
    public var localEndpoint: String { "http://127.0.0.1:\(Self.port)" }
    public var preferredEndpoint: String { "http://\(Self.preferredHost()):\(Self.port)" }
    public var isRunning: Bool { listener != nil }

    private let bridge: AgentBridge
    private let paths: SupportPaths
    private let pairingStore: RemotePairingStore
    private let tunnel: CloudTunnelProcess
    private let previewTunnel: CloudTunnelProcess
    private var projectsProvider: (() -> [RemoteProjectDescriptor])?
    private var selectedProjects: [String: String] = [:]
    private var terminalSessions: [String: TerminalSession] = [:]
    private var previewTunnelPort: Int?
    private var previewTunnelURL: String?
    private var listener: NWListener?
    private var workspacePath: String
    private var revision: Int64 = 0
    private var access: RemoteAccessMode = .ask
    private var pending: [String: (command: RemoteCommand, deviceId: String)] = [:]

    public init(bridge: AgentBridge, paths: SupportPaths, events: RemoteEventHub, workspacePath: String, projectsProvider: (() -> [RemoteProjectDescriptor])? = nil) {
        self.bridge = bridge
        self.paths = paths
        self.events = events
        self.workspacePath = workspacePath
        self.projectsProvider = projectsProvider
        self.pairingStore = RemotePairingStore(root: paths.root, workspaceId: Self.workspaceID(workspacePath))
        self.tunnel = CloudTunnelProcess(runtimeURL: paths.runtime)
        self.previewTunnel = CloudTunnelProcess(runtimeURL: paths.runtime.appendingPathComponent("preview-tunnel", isDirectory: true))
    }

    public func setWorkspacePath(_ value: String) {
        workspacePath = value
        pairingStore.setWorkspaceId(Self.workspaceID(workspace))
    }

    public func setProjectsProvider(_ provider: (() -> [RemoteProjectDescriptor])?) {
        projectsProvider = provider
    }

    private func projects() -> [RemoteProjectDescriptor] {
        let supplied = (projectsProvider?() ?? []).filter { !$0.id.isEmpty && !$0.workspacePath.isEmpty }
        if !supplied.isEmpty { return supplied }
        let path = workspace
        return [RemoteProjectDescriptor(id: "default", name: URL(fileURLWithPath: path).lastPathComponent, workspaceId: Self.workspaceID(path), workspacePath: path)]
    }

    private func selectedProject(for deviceID: String, requestedID: String? = nil) -> RemoteProjectDescriptor {
        let all = projects()
        let id = requestedID ?? selectedProjects[deviceID]
        return all.first(where: { $0.id == id }) ?? all[0]
    }

    public func start() {
        guard listener == nil else { return }
        do {
            guard let port = NWEndpoint.Port(rawValue: Self.port) else { throw RouterTestError.message("Invalid remote-control port") }
            let listener = try NWListener(using: NWParameters.tcp, on: port)
            listener.newConnectionHandler = { [weak self] (connection: NWConnection) in
                connection.start(queue: DispatchQueue.global(qos: .userInitiated))
                Task { @MainActor [weak self] in self?.receive(connection, buffer: Data()) }
            }
            listener.stateUpdateHandler = { [weak self] (state: NWListener.State) in
                if case .failed(let error) = state {
                    Task { @MainActor [weak self] in self?.events.publish("gateway.failed", workspaceId: Self.workspaceID(self?.workspace ?? ""), payload: ["message": .string(error.localizedDescription)]) }
                }
            }
            listener.start(queue: DispatchQueue.global(qos: .userInitiated))
            self.listener = listener
            pairing = pairingStore.begin(endpoint: preferredEndpoint)
            publish("gateway.started", ["endpoint": .string(preferredEndpoint)])
        } catch {
            publish("gateway.failed", ["message": .string(error.localizedDescription)])
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        tunnel.stop()
        previewTunnel.stop()
        previewTunnelPort = nil
        previewTunnelURL = nil
        terminalSessions.values.forEach { $0.stop() }
        terminalSessions.removeAll()
    }

    public func beginPairing() -> RemotePairingInfo {
        let value = pairingStore.begin(endpoint: publicEndpoint ?? preferredEndpoint)
        pairing = value
        publish("pairing.ready", ["endpoint": .string(value.endpoint), "code": .string(value.code)])
        return value
    }

    public func enableCloudTunnel() async throws -> String {
        if listener == nil { start() }
        let endpoint = try await tunnel.start(gatewayPort: Int(Self.port))
        publicEndpoint = endpoint
        pairing = pairingStore.begin(endpoint: endpoint)
        publish("tunnel.ready", ["endpoint": .string(endpoint)])
        return endpoint
    }

    public func disableCloudTunnel() { tunnel.stop(); publicEndpoint = nil; _ = beginPairing() }

    public func publish(_ kind: String, _ payload: [String: RemoteJSONValue] = [:], workspaceOverride: String? = nil) {
        let root = workspaceOverride.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? workspace
        events.publish(kind, workspaceId: Self.workspaceID(root), sessionId: bridge.selected?.id, payload: scopedPayload(payload, workspace: root))
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, complete, error in
            var data = buffer
            if let chunk { data.append(chunk) }
            if error != nil || complete || Self.requestComplete(data) {
                Task { @MainActor [weak self] in self?.handle(data, on: connection) }
            } else if data.count < 8 * 1024 * 1024 {
                Task { @MainActor [weak self] in self?.receive(connection, buffer: data) }
            } else {
                connection.cancel()
            }
        }
    }

    private func handle(_ data: Data, on connection: NWConnection) {
        guard let request = Self.parse(data) else {
            Task { @MainActor [weak self] in
                await self?.send(.init(status: 400, contentType: "application/json", body: Data(#"{"error":"Invalid HTTP request"}"#.utf8)), on: connection)
            }
            return
        }
        Task { @MainActor [weak self] in
            await self?.route(request, on: connection)
        }
    }

    private func route(_ request: RemoteHTTPRequest, on connection: NWConnection) async {
        if request.path == "/v1/control/pair/complete", request.method == "POST" {
            guard let body = try? JSONDecoder.remote.decode(PairRequest.self, from: request.body), let result = pairingStore.complete(code: body.code, name: body.deviceName) else {
                await send(RemoteHTTPResponse(status: 401, contentType: "application/json", body: Data(#"{"error":"Pairing code is invalid or expired."}"#.utf8)), on: connection)
                return
            }
            await sendJSON(result, status: 200, on: connection)
            publish("device.paired", ["deviceId": .string(result.deviceId), "deviceName": .string(result.deviceName)])
            return
        }

        guard let token = request.headers["authorization"]?.split(separator: " ", maxSplits: 1).last.map(String.init), let deviceId = pairingStore.authenticate(token) else {
            await send(RemoteHTTPResponse(status: 401, contentType: "application/json", body: Data(#"{"error":"A valid device token is required."}"#.utf8)), on: connection)
            return
        }
        if request.method == "GET", request.path == "/v2/control/projects" {
            let all = projects()
            await sendJSON(RemoteProjectsResponse(protocolVersion: 2, projectID: selectedProject(for: deviceId).id, projects: all), status: 200, on: connection)
            return
        }
        if request.method == "POST", request.path == "/v2/control/projects/select" {
            guard let body = try? JSONDecoder.remote.decode([String: String].self, from: request.body),
                  let projectID = body["projectID"],
                  let project = projects().first(where: { $0.id == projectID }) else {
                await sendJSON(MessageResponse(error: "Project not found."), status: 404, on: connection)
                return
            }
            selectedProjects[deviceId] = project.id
            await sendJSON(RemoteProjectSelection(projectID: project.id, workspaceId: project.workspaceId), status: 200, on: connection)
            publish(
                "project.selected",
                ["projectID": .string(project.id), "deviceId": .string(deviceId)],
                workspaceOverride: project.workspacePath
            )
            return
        }
        let projectScoped = request.path.hasPrefix("/v2/control/")
        let routePath = projectScoped ? "/v1/control/" + String(request.path.dropFirst("/v2/control/".count)) : request.path
        switch (request.method, routePath) {
        case ("GET", "/v1/control/bootstrap"):
            await sendJSON(bootstrap(deviceID: deviceId, projectScoped: projectScoped), status: 200, on: connection)
        case ("GET", "/v1/control/events"):
            await streamEvents(request, deviceID: deviceId, projectScoped: projectScoped, on: connection)
        case ("GET", "/v1/control/file"):
            await readFile(request, deviceID: deviceId, projectScoped: projectScoped, on: connection)
        case ("GET", let path) where path.hasPrefix("/v1/control/files/"):
            await readFile(request, deviceID: deviceId, projectScoped: projectScoped, on: connection)
        case ("GET", "/v1/control/artifact"):
            await readArtifact(request, on: connection)
        case ("GET", let path) where path.hasPrefix("/v1/control/artifacts/"):
            await readArtifact(request, on: connection)
        case ("GET", "/v1/control/artifacts"):
            await sendJSON(events.artifactList(), status: 200, on: connection)
        case ("POST", "/v1/control/snapshot/request"):
            await sendJSON(await snapshot(deviceID: deviceId, projectScoped: projectScoped), status: 200, on: connection)
        case ("POST", "/v1/control/commands"):
            let response = await dispatch(request, deviceId: deviceId, projectScoped: projectScoped)
            if let command = try? JSONDecoder.remote.decode(RemoteCommand.self, from: request.body) {
                let requestedProjectID = command.projectID ?? command.payload["projectID"]?.string
                let auditWorkspace = projectScoped ? selectedProject(for: deviceId, requestedID: requestedProjectID).workspacePath : nil
                publish("audit.command", ["commandId": .string(command.id), "deviceId": .string(deviceId), "kind": .string(command.kind), "status": .string(response.status), "httpStatus": .number(Double(response.httpStatus))], workspaceOverride: auditWorkspace)
            }
            await sendJSON(response, status: response.httpStatus, on: connection)
        default:
            await sendJSON(MessageResponse(error: "Control route not found."), status: 404, on: connection)
        }
    }

    private func dispatch(_ request: RemoteHTTPRequest, deviceId: String, projectScoped: Bool) async -> CommandResponse {
        guard let command = try? JSONDecoder.remote.decode(RemoteCommand.self, from: request.body) else { return .failed(400, "Invalid command or workspace.") }
        let requestedProjectID = projectScoped ? (command.projectID ?? command.payload["projectID"]?.string) : nil
        let targetWorkspace = projectScoped ? selectedProject(for: deviceId, requestedID: requestedProjectID).workspacePath : workspace
        guard command.workspaceId == Self.workspaceID(targetWorkspace) else { return .failed(400, "Invalid command or workspace.") }
        if let expected = command.expectedRevision, expected != revision { return .failed(409, "The workspace revision changed. Current revision: \(revision).") }
        switch command.kind {
        case "prompt":
            let text = command.payload["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return .failed(400, "Prompt text is required.") }
            let mode = PromptMode(rawValue: command.payload["mode"]?.string ?? "queue") ?? .queue
            let plan = command.payload["planMode"]?.bool ?? false
            Task { @MainActor [weak self] in await self?.bridge.send(text: text, mode: mode, planMode: plan) }
            return .accepted(command.id, "queued")
        case "continue":
            Task { @MainActor [weak self] in await self?.bridge.continueCurrentRun(text: command.payload["text"]?.string) }
            return .accepted(command.id, "continued")
        case "stop", "cancel":
            bridge.stopCurrentRun()
            return .accepted(command.id, "stopped")
        case "approval":
            bridge.answerApproval(
                command.payload["answer"]?.string ?? "rejected",
                in: command.payload["conversationId"]?.string
            )
            return .accepted(command.id, "approval-forwarded")
        case "question":
            bridge.answerQuestions(
                command.payload["answers"]?.strings ?? [command.payload["answer"]?.string ?? ""],
                in: command.payload["conversationId"]?.string
            )
            return .accepted(command.id, "answer-forwarded")
        case "permission":
            access = RemoteAccessMode(rawValue: command.payload["mode"]?.string?.replacingOccurrences(of: " ", with: "").lowercased() ?? "ask") ?? .ask
            publish("access.changed", ["mode": .string(access.rawValue)])
            return .accepted(command.id, access.rawValue)
        case "approve":
            return await approve(command)
        case "terminal_session":
            let action = command.payload["action"]?.string?.lowercased() ?? "status"
            if ["read", "status", "stop"].contains(action) {
                return terminalSession(command, deviceId: deviceId, workspace: targetWorkspace)
            }
            guard access != .ask else {
                let approvalId = UUID().uuidString
                pending[approvalId] = (command, deviceId)
                publish("approval.required", ["approvalId": .string(approvalId), "commandId": .string(command.id), "kind": .string(command.kind), "summary": .string(commandSummary(command))], workspaceOverride: targetWorkspace)
                return .pending(command.id, approvalId)
            }
            return terminalSession(command, deviceId: deviceId, workspace: targetWorkspace)
        case "preview_tunnel":
            let action = command.payload["action"]?.string?.lowercased() ?? "status"
            if ["stop", "status"].contains(action) {
                return previewTunnelCommand(command, workspace: targetWorkspace)
            }
            guard access != .ask else {
                let approvalId = UUID().uuidString
                pending[approvalId] = (command, deviceId)
                publish("approval.required", ["approvalId": .string(approvalId), "commandId": .string(command.id), "kind": .string(command.kind), "summary": .string(commandSummary(command))], workspaceOverride: targetWorkspace)
                return .pending(command.id, approvalId)
            }
            return await startPreviewTunnel(command, workspace: targetWorkspace)
        case "write_file", "run_command", "build", "deploy", "computer_use", "native_browser":
            guard access != .ask else {
                let approvalId = UUID().uuidString
                pending[approvalId] = (command, deviceId)
                publish("approval.required", ["approvalId": .string(approvalId), "commandId": .string(command.id), "kind": .string(command.kind), "summary": .string(commandSummary(command))], workspaceOverride: targetWorkspace)
                return .pending(command.id, approvalId)
            }
            return await executeSensitive(command, workspace: targetWorkspace, deviceId: deviceId)
        case "revoke_device":
            let id = command.payload["deviceId"]?.string ?? ""
            guard pairingStore.revoke(id) else { return .failed(404, "Device not found.") }
            let keys = terminalSessions.keys.filter { $0.hasPrefix(id + ":") }
            for key in keys { terminalSessions.removeValue(forKey: key)?.stop() }
            return .accepted(command.id, "revoked")
        default:
            return .failed(400, "Unsupported control command.")
        }
    }

    private func approve(_ command: RemoteCommand) async -> CommandResponse {
        guard let approvalId = command.payload["approvalId"]?.string, let item = pending.removeValue(forKey: approvalId) else { return .failed(404, "Approval request not found.") }
        let answer = command.payload["answer"]?.string?.lowercased() ?? "rejected"
        let projectID = item.command.projectID ?? item.command.payload["projectID"]?.string
        let targetWorkspace = selectedProject(for: item.deviceId, requestedID: projectID).workspacePath
        guard ["allow", "allowed-once", "approved", "full"].contains(answer) else {
            publish("approval.resolved", ["approvalId": .string(approvalId), "allowed": .bool(false)], workspaceOverride: targetWorkspace)
            return .accepted(command.id, "rejected")
        }
        if answer == "full" { access = .full }
        let result = await executeSensitive(item.command, workspace: targetWorkspace, deviceId: item.deviceId)
        publish("approval.resolved", ["approvalId": .string(approvalId), "allowed": .bool(true)], workspaceOverride: targetWorkspace)
        return result
    }

    private func executeSensitive(_ command: RemoteCommand, workspace: String, deviceId: String) async -> CommandResponse {
        let workspaceURL = URL(fileURLWithPath: workspace, isDirectory: true)
        do {
            if command.kind == "write_file" {
                let path = command.payload["path"]?.string ?? ""
                let content = command.payload["content"]?.string ?? ""
                let expected = command.payload["expectedSha256"]?.string
                let result = try await Task.detached(priority: .userInitiated) {
                    try RemoteWorkspaceMac.write(content: content, path: path, workspace: workspaceURL, expectedSha256: expected)
                }.value
                if result.conflict { return .conflict(command.id, result) }
                publish("file.changed", ["path": .string(path), "sha256": .string(result.sha256), "operation": .string("write")], workspaceOverride: workspace)
                return .ok(command.id, result)
            }
            if command.kind == "computer_use" {
                guard bridge.isComputerUseEnabled else {
                    return .failed(403, "Computer Use is disabled on this desktop. Enable it in Settings → Computer Use.")
                }
                var arguments: [String: Any] = [:]
                for (key, value) in command.payload {
                    switch value {
                    case .string(let text): arguments[key] = text
                    case .number(let number): arguments[key] = number
                    case .bool(let flag): arguments[key] = flag
                    default: break
                    }
                }
                let output = try await ComputerUseService.execute(arguments: arguments, workspace: workspaceURL)
                publish("computeruse.action", ["commandId": .string(command.id), "action": .string(command.payload["action"]?.string ?? "")], workspaceOverride: workspace)
                return .ok(command.id, output)
            }
            if command.kind == "terminal_session" {
                return terminalSession(command, deviceId: deviceId, workspace: workspace)
            }
            if command.kind == "preview_tunnel" {
                return await startPreviewTunnel(command, workspace: workspace)
            }
            if command.kind == "native_browser" {
                var arguments: [String: Any] = [:]
                for (key, value) in command.payload {
                    switch value {
                    case .string(let text): arguments[key] = text
                    case .number(let number): arguments[key] = number
                    case .bool(let flag): arguments[key] = flag
                    default: break
                    }
                }
                let output = try await NativeBrowserService.shared.execute(arguments: arguments, workspace: workspaceURL)
                publish("browser.action", ["commandId": .string(command.id), "action": .string(command.payload["action"]?.string ?? "")], workspaceOverride: workspace)
                return .ok(command.id, ["output": .string(output), "outputPreview": .string(String(output.prefix(700)))])
            }
            let shell = command.payload["command"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !shell.isEmpty else { return .failed(400, "Command text is required.") }
            publish(command.kind == "deploy" ? "deploy.progress" : "build.started", ["commandId": .string(command.id), "kind": .string(command.kind), "phase": .string("started")], workspaceOverride: workspace)
            let arguments: [String: RemoteJSONValue] = ["command": .string(shell)]
            let call = AgentToolCall(id: command.id, name: "run_command", arguments: try JSONEncoder.remote.encodeToString(arguments))
            let eventHub = events
            let workspaceId = Self.workspaceID(workspace)
            let sessionId = bridge.selected?.id
            let commandId = command.id
            let commandKind = command.kind
            let terminalPayload = scopedPayload([
                "commandId": .string(commandId),
                "kind": .string(commandKind),
            ], workspace: workspace)
            let policy = bridge.sandboxPolicy
            // A remote build or deploy is the longest-running thing this host can
            // be asked to do, so it cannot hold the thread that draws the app.
            let output = await Task.detached(priority: .userInitiated) {
                WorkspaceTools.execute(
                    call,
                    workspace: workspaceURL,
                    conversationID: Self.ledgerScope,
                    sandboxPolicy: policy,
                    onOutput: { chunk in
                        eventHub.publish("terminal.output", workspaceId: workspaceId, sessionId: sessionId, payload: terminalPayload)
                    }
                )
            }.value
            let artifact = events.publishText(command.kind == "deploy" ? "deploy.progress" : "build.output", workspaceId: Self.workspaceID(workspace), sessionId: bridge.selected?.id, text: output, payload: scopedPayload(["commandId": .string(command.id), "kind": .string(command.kind), "phase": .string("output")], workspace: workspace))
            var outputArtifactId: String?
            if command.kind == "build", let artifactPath = command.payload["artifactPath"]?.string, !artifactPath.isEmpty {
                let data = try await Task.detached(priority: .userInitiated) {
                    try RemoteWorkspaceMac.readArtifact(path: artifactPath, workspace: workspaceURL)
                }.value
                outputArtifactId = events.saveArtifact(kind: "build-artifact", data: data)
                events.publish("artifact.ready", workspaceId: Self.workspaceID(workspace), sessionId: bridge.selected?.id, payload: scopedPayload(["path": .string(artifactPath), "bytes": .number(Double(data.count))], workspace: workspace), artifactId: outputArtifactId)
            }
            let bytes = output.utf8.count
            let deployFailed = command.kind == "deploy" && output.contains("Command exited with status ")
            publish(command.kind == "deploy" ? (deployFailed ? "deploy.failed" : "deploy.completed") : "build.completed", ["commandId": .string(command.id), "kind": .string(command.kind), "bytes": .number(Double(bytes)), "artifactId": .string(artifact.artifactId ?? ""), "outputArtifactId": outputArtifactId.map(RemoteJSONValue.string) ?? .null, "truncated": .bool(bytes > 50 * 1024 * 1024)], workspaceOverride: workspace)
            return .ok(command.id, ["outputPreview": String(output.prefix(700)), "artifactId": artifact.artifactId ?? "", "outputArtifactId": outputArtifactId ?? ""])
        } catch {
            publish("build.failed", ["commandId": .string(command.id), "message": .string(error.localizedDescription)], workspaceOverride: workspace)
            return .failed(400, error.localizedDescription)
        }
    }

    private func terminalSession(_ command: RemoteCommand, deviceId: String, workspace: String) -> CommandResponse {
        let action = command.payload["action"]?.string?.lowercased() ?? "status"
        let key = deviceId + ":" + Self.workspaceID(workspace)
        if action == "start" {
            if terminalSessions[key]?.isRunning != true {
                let policy = bridge.sandboxPolicy.flatMap { $0.workspaceURL.standardizedFileURL.path == URL(fileURLWithPath: workspace).standardizedFileURL.path ? $0 : nil }
                let session = TerminalSession(workspacePath: workspace, sandboxPolicy: policy)
                session.start()
                terminalSessions[key] = session
                publish("terminal.session.started", ["sessionId": .string(session.id.uuidString)], workspaceOverride: workspace)
            }
        }
        guard let session = terminalSessions[key] else {
            if action == "stop" { return .accepted(command.id, "stopped") }
            return .ok(command.id, ["running": .bool(false), "output": .string(""), "sessionId": .string("")])
        }
        switch action {
        case "read", "status": break
        case "send":
            let input = command.payload["input"]?.string ?? ""
            guard !input.isEmpty else { return .failed(400, "Terminal input is required.") }
            session.sendInput(input)
        case "stop":
            session.stop()
            terminalSessions.removeValue(forKey: key)
            publish("terminal.session.stopped", ["sessionId": .string(session.id.uuidString)], workspaceOverride: workspace)
            return .accepted(command.id, "stopped")
        case "start": break
        default: return .failed(400, "Unsupported terminal session action.")
        }
        return .ok(command.id, [
            "sessionId": .string(session.id.uuidString),
            "running": .bool(session.isRunning),
            "output": .string(String(session.output.suffix(40_000))),
        ])
    }

    private func previewTunnelCommand(_ command: RemoteCommand, workspace: String) -> CommandResponse {
        let action = command.payload["action"]?.string?.lowercased() ?? "status"
        if action == "stop" {
            previewTunnel.stop()
            previewTunnelPort = nil
            previewTunnelURL = nil
            publish("preview.tunnel.stopped", workspaceOverride: workspace)
            return .accepted(command.id, "stopped")
        }
        return .ok(command.id, [
            "running": .bool(previewTunnelPort != nil),
            "port": previewTunnelPort.map { .number(Double($0)) } ?? .null,
            "url": previewTunnelURL.map(RemoteJSONValue.string) ?? .null,
        ])
    }

    private func startPreviewTunnel(_ command: RemoteCommand, workspace: String) async -> CommandResponse {
        let port = command.payload["port"]?.int ?? 0
        guard (1...65_535).contains(port) else { return .failed(400, "Enter a development server port between 1 and 65535.") }
        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)")!, timeoutInterval: 2)
            request.httpMethod = "HEAD"
            _ = try await URLSession.shared.data(for: request)
            let url = try await previewTunnel.start(gatewayPort: port)
            previewTunnelPort = port
            previewTunnelURL = url
            publish("preview.tunnel.ready", ["url": .string(url), "port": .number(Double(port))], workspaceOverride: workspace)
            return .ok(command.id, ["url": .string(url), "port": .number(Double(port)), "public": .bool(true)])
        } catch {
            previewTunnelPort = nil
            previewTunnelURL = nil
            return .failed(400, error.localizedDescription)
        }
    }

    private func bootstrap(deviceID: String, projectScoped: Bool) -> RemoteBootstrap {
        let selected = bridge.selected
        let project = projectScoped ? selectedProject(for: deviceID) : nil
        let path = project?.workspacePath ?? workspace
        return RemoteBootstrap(protocolVersion: projectScoped ? 2 : 1, scope: "project", workspaceId: Self.workspaceID(path), workspace: path, revision: revision, conversationId: selected?.id, provider: bridge.connection?.provider, model: bridge.connection?.model, status: bridge.status, isBusy: bridge.isBusy, accessMode: access, capabilities: ["events", "prompt", "continue", "stop", "approval", "files", "snapshot", "artifacts", "write", "terminal", "terminal_sessions", "preview_tunnel", "native_browser", "build", "deploy"], devices: pairingStore.list(), projectID: project?.id)
    }

    private func snapshot(deviceID: String, projectScoped: Bool) async -> RemoteWorkspaceSnapshot {
        let path = projectScoped ? selectedProject(for: deviceID).workspacePath : workspace
        revision += 1
        let workspaceId = Self.workspaceID(path)
        let snapshotRevision = revision
        let result = await Task.detached(priority: .userInitiated) {
            RemoteWorkspaceMac.snapshot(workspace: path, workspaceId: workspaceId, revision: snapshotRevision)
        }.value
        publish("snapshot.ready", ["revision": .number(Double(revision)), "files": .number(Double(result.files.count)), "excluded": .number(Double(result.excluded.count))], workspaceOverride: path)
        return result
    }

    private func readFile(_ request: RemoteHTTPRequest, deviceID: String, projectScoped: Bool, on connection: NWConnection) async {
        let path = Self.query(request.target, "path").isEmpty && request.path.hasPrefix("/v1/control/files/") ? String(request.path.dropFirst("/v1/control/files/".count).removingPercentEncoding ?? "") : Self.query(request.target, "path")
        let root = projectScoped ? selectedProject(for: deviceID).workspacePath : workspace
        // A 50 MB transfer limit is far too much to read on the thread that draws
        // the app, so the disk work stays off the main actor.
        do {
            let workspaceURL = URL(fileURLWithPath: root)
            let body = try await Task.detached(priority: .userInitiated) {
                try RemoteWorkspaceMac.read(path: path, workspace: workspaceURL)
            }.value
            await send(RemoteHTTPResponse(status: 200, contentType: "application/octet-stream", body: body), on: connection)
        }
        catch { await sendJSON(MessageResponse(error: error.localizedDescription), status: 400, on: connection) }
    }

    private func readArtifact(_ request: RemoteHTTPRequest, on connection: NWConnection) async {
        let id = Self.query(request.target, "id").isEmpty && request.path.hasPrefix("/v1/control/artifacts/") ? String(request.path.dropFirst("/v1/control/artifacts/".count).removingPercentEncoding ?? "") : Self.query(request.target, "id")
        guard let url = events.artifactURL(id) else { await sendJSON(MessageResponse(error: "Artifact not found."), status: 404, on: connection); return }
        let body = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        guard let data = body else { await sendJSON(MessageResponse(error: "Artifact not found."), status: 404, on: connection); return }
        await send(RemoteHTTPResponse(status: 200, contentType: "application/octet-stream", body: data), on: connection)
    }

    private func streamEvents(_ request: RemoteHTTPRequest, deviceID: String, projectScoped: Bool, on connection: NWConnection) async {
        let after = Int64(Self.query(request.target, "after")) ?? Int64(request.headers["last-event-id"] ?? "0") ?? 0
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\n"
        do {
            try await sendData(Data(header.utf8), on: connection)
            let root = projectScoped ? selectedProject(for: deviceID).workspacePath : workspace
            for await event in events.stream(after: after, workspaceId: Self.workspaceID(root)) {
                let data = try JSONEncoder.remote.encode(event)
                try await sendData(Data("id: \(event.sequence)\nevent: \(event.kind)\ndata: ".utf8) + data + Data("\n\n".utf8), on: connection)
            }
        } catch { connection.cancel() }
    }

    private func sendJSON<T: Encodable>(_ value: T, status: Int, on connection: NWConnection) async { guard let data = try? JSONEncoder.remote.encode(value) else { connection.cancel(); return }; await send(RemoteHTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data), on: connection) }
    private func send(_ response: RemoteHTTPResponse, on connection: NWConnection) async { let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 409: "Conflict", 500: "Error"][response.status] ?? "Error"; let header = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"; try? await sendData(Data(header.utf8) + response.body, on: connection); connection.cancel() }
    private func sendData(_ data: Data, on connection: NWConnection) async throws { try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in connection.send(content: data, completion: .contentProcessed { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }) } }

    private func commandSummary(_ command: RemoteCommand) -> String {
        switch command.kind {
        case "write_file": return "Write \(command.payload["path"]?.string ?? ".")"
        case "terminal_session": return command.payload["action"]?.string == "start" ? "Start a mobile terminal session" : "Send input to the mobile terminal"
        case "preview_tunnel": return "Expose local development port \(command.payload["port"]?.int ?? 0)"
        case "native_browser": return "Native browser action: \(command.payload["action"]?.string ?? "")"
        default: return command.payload["command"]?.string ?? command.kind
        }
    }
    private func scopedPayload(_ payload: [String: RemoteJSONValue], workspace: String) -> [String: RemoteJSONValue] {
        var payload = payload
        payload["scope"] = .string("project")
        if let projectID = projects().first(where: { URL(fileURLWithPath: $0.workspacePath).standardizedFileURL.path == URL(fileURLWithPath: workspace).standardizedFileURL.path })?.id {
            payload["projectID"] = .string(projectID)
        }
        return payload
    }
    private var workspace: String { let value = workspacePath.isEmpty ? FileManager.default.currentDirectoryPath : workspacePath; return URL(fileURLWithPath: value).standardizedFileURL.path }

    private static nonisolated func requestComplete(_ data: Data) -> Bool { guard let marker = data.range(of: Data([13, 10, 13, 10])) else { return false }; let headers = String(decoding: data[..<marker.lowerBound], as: UTF8.self); let length = headers.split(separator: "\r\n").compactMap { line -> Int? in let parts = line.split(separator: ":", maxSplits: 1); return parts.count == 2 && parts[0].lowercased() == "content-length" ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil }.first ?? 0; return data.count - marker.upperBound >= length }
    private static func parse(_ data: Data) -> RemoteHTTPRequest? { guard let marker = data.range(of: Data([13, 10, 13, 10])) else { return nil }; let lines = String(decoding: data[..<marker.lowerBound], as: UTF8.self).split(separator: "\r\n", omittingEmptySubsequences: false); let first = lines.first?.split(separator: " ", maxSplits: 2).map(String.init) ?? []; guard first.count == 3 else { return nil }; var headers: [String: String] = [:]; for line in lines.dropFirst() { let parts = line.split(separator: ":", maxSplits: 1); if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) } }; let body = Data(data[marker.upperBound...]); let path = first[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? first[1]; return RemoteHTTPRequest(method: first[0].uppercased(), target: first[1], path: path, headers: headers, body: body) }
    private static func query(_ target: String, _ key: String) -> String { guard let components = URLComponents(string: target), let item = components.queryItems?.first(where: { $0.name == key }) else { return "" }; return item.value ?? "" }
    public nonisolated static func workspaceIDForProject(_ value: String) -> String { SHA256.hash(data: Data(URL(fileURLWithPath: value).standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description }
    private static func workspaceID(_ value: String) -> String { workspaceIDForProject(value) }
    private static func preferredHost() -> String { var addresses: UnsafeMutablePointer<ifaddrs>?; guard getifaddrs(&addresses) == 0 else { return "127.0.0.1" }; defer { freeifaddrs(addresses) }; var current = addresses; while let item = current { if item.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET), let name = String(validatingCString: item.pointee.ifa_name), name != "lo0" { var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST)); getnameinfo(item.pointee.ifa_addr, socklen_t(item.pointee.ifa_addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST); let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }; let value = String(decoding: bytes, as: UTF8.self); if value != "127.0.0.1" { return value } }; current = item.pointee.ifa_next }; return "127.0.0.1" }
}

private struct PairRequest: Codable { let code: String; let deviceName: String? }
public struct RemoteCommand: Codable, Sendable { let id: String; let workspaceId: String; let sessionId: String?; let kind: String; let expectedRevision: Int64?; let payload: [String: RemoteJSONValue]; let projectID: String? }
private struct MessageResponse: Codable { let error: String }
private struct CommandResponse: Codable {
    let commandId: String
    let status: String
    let httpStatus: Int
    let approvalId: String?
    let result: RemoteJSONValue?
    let error: String?
    static func accepted(_ id: String, _ status: String) -> Self { .init(commandId: id, status: status, httpStatus: 202, approvalId: nil, result: nil, error: nil) }
    static func pending(_ id: String, _ approval: String) -> Self { .init(commandId: id, status: "approval-required", httpStatus: 202, approvalId: approval, result: nil, error: nil) }
    static func ok(_ id: String, _ value: [String: RemoteJSONValue]) -> Self {
        .init(commandId: id, status: "completed", httpStatus: 200, approvalId: nil, result: .object(value), error: nil)
    }
    static func ok(_ id: String, _ value: Any) -> Self {
        let result: RemoteJSONValue
        if let value = value as? RemoteJSONValue { result = value }
        else if let value = value as? [String: RemoteJSONValue] { result = .object(value) }
        else { result = .string(String(describing: value)) }
        return .init(commandId: id, status: "completed", httpStatus: 200, approvalId: nil, result: result, error: nil)
    }
    static func conflict(_ id: String, _ value: RemoteFileWriteResult) -> Self { .init(commandId: id, status: "conflict", httpStatus: 409, approvalId: nil, result: .object(["path": .string(value.path), "currentSha256": .string(value.currentSha256 ?? "")]), error: nil) }
    static func failed(_ status: Int, _ message: String) -> Self { .init(commandId: "", status: "failed", httpStatus: status, approvalId: nil, result: nil, error: message) }
}

private extension JSONEncoder {
    static var remote: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
    func encodeToString<T: Encodable>(_ value: T) throws -> String { String(decoding: try encode(value), as: UTF8.self) }
}

private extension JSONDecoder {
    static var remote: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}

private enum RemoteWorkspaceMac {
    private static let excludedDirectories = Set([".git", ".mem", "node_modules", "bin", "obj", "build", "dist", ".gradle", "DerivedData", "Pods", ".next"])
    private static let maxBytes: Int64 = 50 * 1024 * 1024

    static func snapshot(workspace: String, workspaceId: String, revision: Int64) -> RemoteWorkspaceSnapshot {
        var files: [RemoteWorkspaceFile] = []; var excluded: [RemoteExcludedPath] = []
        walk(URL(fileURLWithPath: workspace), root: URL(fileURLWithPath: workspace), depth: 0, files: &files, excluded: &excluded)
        return RemoteWorkspaceSnapshot(version: 1, workspaceId: workspaceId, workspace: workspace, revision: revision, baseCommitSha: baseCommit(workspace), files: files, excluded: excluded, createdAt: Date())
    }

    static func read(path: String, workspace: URL) throws -> Data { let file = try resolve(path, workspace: workspace); let data = try Data(contentsOf: file); guard Int64(data.count) <= maxBytes else { throw RouterTestError.message("File is larger than the remote transfer limit.") }; return data }

    static func readArtifact(path: String, workspace: URL) throws -> Data {
        let file = try resolve(path, workspace: workspace, allowGenerated: true)
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let parts = file.path.replacingOccurrences(of: root.path + "/", with: "").split(separator: "/").map(String.init)
        guard !parts.contains(where: { [".git", ".mem", "node_modules", ".gradle", "Pods"].contains($0) }) else { throw RouterTestError.message("This artifact path is not available through remote control.") }
        guard parts.contains(where: { ["bin", "obj", "build", "dist", "DerivedData", ".next"].contains($0) }) else { throw RouterTestError.message("Build artifacts must be inside a generated output directory.") }
        let data = try Data(contentsOf: file)
        guard Int64(data.count) <= maxBytes else { throw RouterTestError.message("Artifact is larger than the remote transfer limit.") }
        return data
    }

    static func write(content: String, path: String, workspace: URL, expectedSha256: String?) throws -> RemoteFileWriteResult {
        guard Int64(content.utf8.count) <= maxBytes else { throw RouterTestError.message("File is larger than the remote transfer limit.") }
        let file = try resolve(path, workspace: workspace); let current = FileManager.default.fileExists(atPath: file.path) ? try hash(Data(contentsOf: file)) : nil
        if let expectedSha256, !expectedSha256.isEmpty, expectedSha256.lowercased() != current?.lowercased() { return RemoteFileWriteResult(written: false, conflict: true, path: path, sha256: current ?? "", currentSha256: current, message: "The file changed on the desktop.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = file.appendingPathExtension("remote-\(UUID().uuidString)")
        try Data(content.utf8).write(to: temp, options: .atomic)
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temp, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: temp, to: file)
        }
        let digest = try hash(Data(content.utf8)); return RemoteFileWriteResult(written: true, conflict: false, path: path, sha256: digest, currentSha256: digest, message: "File written.")
    }

    private static func walk(_ directory: URL, root: URL, depth: Int, files: inout [RemoteWorkspaceFile], excluded: inout [RemoteExcludedPath]) {
        guard depth <= 20, files.count < 20_000, let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: []) else { return }
        for entry in entries.sorted(by: { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }) {
            let relative = entry.path.replacingOccurrences(of: root.path + "/", with: "")
            let name = entry.lastPathComponent
            if excludedDirectories.contains(name) || sensitive(name) { excluded.append(RemoteExcludedPath(path: relative, reason: excludedDirectories.contains(name) ? "generated or private runtime directory" : "secret or credential file")); continue }
            if entry.isSymbolicLink { excluded.append(RemoteExcludedPath(path: relative, reason: "symbolic link")); continue }
            if entry.isDirectory { walk(entry, root: root, depth: depth + 1, files: &files, excluded: &excluded); continue }
            guard let data = try? Data(contentsOf: entry) else { excluded.append(RemoteExcludedPath(path: relative, reason: "unreadable")); continue }
            guard Int64(data.count) <= maxBytes else { excluded.append(RemoteExcludedPath(path: relative, reason: "file exceeds transfer limit")); continue }
            files.append(RemoteWorkspaceFile(path: relative, bytes: Int64(data.count), sha256: (try? hash(data)) ?? "", mode: 0))
        }
    }

    private static func resolve(_ path: String, workspace: URL, allowGenerated: Bool = false) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/") else { throw RouterTestError.message("A relative file path is required.") }
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath(); let file = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
        let resolved = file.resolvingSymlinksInPath(); guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else { throw RouterTestError.message("Path is outside the workspace.") }
        let components = file.path.replacingOccurrences(of: root.path + "/", with: "").split(separator: "/"); if components.contains(where: { sensitive(String($0)) || (!allowGenerated && excludedDirectories.contains(String($0))) }) { throw RouterTestError.message("This path is not available through remote control.") }
        return file
    }

    private static func sensitive(_ value: String) -> Bool { value == ".env" || value.hasPrefix(".env.") || value == "credentials.json" || value == "secrets.json" || value.hasSuffix(".pem") || value.hasSuffix(".p12") || value.hasSuffix(".key") || value == "id_rsa" }
    private static func hash(_ data: Data) throws -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func baseCommit(_ workspace: String) -> String? {
        let git = URL(fileURLWithPath: workspace).appendingPathComponent(".git", isDirectory: true)
        guard let head = try? String(contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        var value = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("ref: ") {
            let reference = String(value.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            let direct = git.appendingPathComponent(reference)
            if let resolved = try? String(contentsOf: direct, encoding: .utf8) {
                value = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let packed = try? String(contentsOf: git.appendingPathComponent("packed-refs"), encoding: .utf8) {
                value = packed.split(whereSeparator: \.isNewline).compactMap { line in
                    let parts = line.split(separator: " ", maxSplits: 1)
                    return parts.count == 2 && parts[1] == reference ? String(parts[0]) : nil
                }.first ?? value
            }
        }
        return value.count == 40 && value.allSatisfy(\.isHexDigit) ? value : nil
    }
}

private extension URL {
    var isDirectory: Bool { (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    var isSymbolicLink: Bool { (try? resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
}
