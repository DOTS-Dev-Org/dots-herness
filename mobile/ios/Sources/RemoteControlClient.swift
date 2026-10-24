import CryptoKit
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
    let projectID: String?
    let endpoints: [String]

    enum CodingKeys: String, CodingKey {
        case protocolVersion, workspaceId, workspace, revision, conversationId, provider, model, status, isBusy, accessMode, capabilities, projectID, endpoints
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        workspaceId = try values.decode(String.self, forKey: .workspaceId)
        workspace = try values.decode(String.self, forKey: .workspace)
        revision = try values.decode(Int64.self, forKey: .revision)
        conversationId = try values.decodeIfPresent(String.self, forKey: .conversationId)
        provider = try values.decodeIfPresent(String.self, forKey: .provider)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        status = try values.decode(String.self, forKey: .status)
        isBusy = try values.decode(Bool.self, forKey: .isBusy)
        accessMode = try values.decode(String.self, forKey: .accessMode)
        capabilities = try values.decode([String].self, forKey: .capabilities)
        projectID = try values.decodeIfPresent(String.self, forKey: .projectID)
        endpoints = try values.decodeIfPresent([String].self, forKey: .endpoints) ?? []
    }
}

struct RemoteProjectDescriptor: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let workspaceId: String
    let branch: String?
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
    let projectID: String?
    let kind: String
    let expectedRevision: Int64?
    let payload: [String: RemoteJSONValue]
}

/// HTTPS only, LAN included. The desktop's LAN certificate is self-signed and
/// trusted by its pinned fingerprint (see RemoteSessionDelegate); every
/// exchange is sealed on top of that (see RemoteSealed).
enum RemoteEndpoint {
    static func isAllowed(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, let host = url.host, !host.isEmpty else { return false }
        return url.scheme?.lowercased() == "https"
    }

    /// SHA-256 of a DER certificate, lowercase hex, as the pairing QR carries it.
    static func isFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...102).contains($0.value) }
    }
}

/// Sealed channel v1, the only way to talk to the desktop, LAN and cloud tunnel
/// alike: the tunnel ends TLS at Cloudflare, so the raw HTTP exchange is
/// AES-256-GCM encrypted end to end. The format is specified on the desktop
/// (`RemoteSealed` in macOS RemoteControl.swift and shared/RemoteControl.cs).
enum RemoteSealed {
    static let path = "/v3/sealed"
    static let pairingDevice = "pair"

    static func key(_ secret: String) -> SymmetricKey { SymmetricKey(data: SHA256.hash(data: Data("herness.sealed.v1:\(secret)".utf8))) }

    /// A pairing or device secret: 32 random bytes, base64url without padding.
    static func isSecret(_ value: String) -> Bool {
        value.count == 43 && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }

    /// The request body: a fresh nonce, then the sealed timestamp and raw HTTP request.
    static func request(key: SymmetricKey, device: String, method: String, path: String, host: String, body: Data?) throws -> Data {
        var plain = Data()
        withUnsafeBytes(of: Int64(Date().timeIntervalSince1970 * 1000).bigEndian) { plain.append(contentsOf: $0) }
        plain += Data("\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nContent-Length: \(body?.count ?? 0)\r\n\(body == nil ? "" : "Content-Type: application/json\r\n")\r\n".utf8) + (body ?? Data())
        guard let sealed = try AES.GCM.seal(plain, using: key, authenticating: Data(device.utf8)).combined else { throw ClientError.server("Sealing failed.") }
        return sealed
    }

    static func open(line: String, key: SymmetricKey, nonce: Data, counter: UInt32) throws -> Data {
        var aad = nonce
        withUnsafeBytes(of: counter.bigEndian) { aad.append(contentsOf: $0) }
        guard let data = Data(base64Encoded: line) else { throw ClientError.server("The desktop reply is malformed.") }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: aad)
    }
}

/// A pairing request that arrived through a `herness://` link. Any web page
/// can open that scheme, so the endpoint stays untrusted until the user
/// confirms the host they are shown.
struct PendingPairRequest: Identifiable, Equatable {
    let endpoint: String
    let code: String
    let secret: String
    let fingerprint: String?

    var id: String { "\(endpoint)#\(code)" }
    /// The host the device would talk to — what the user has to recognise.
    var host: String { URL(string: endpoint)?.host ?? endpoint }
}

private struct PairingPayload {
    let endpoint: String
    let code: String
    /// Seals the pairing exchange; only the QR carries it.
    let secret: String
    /// Pinned desktop certificate; required for its self-signed LAN address.
    let fingerprint: String?

    init?(url: URL) {
        guard url.scheme?.lowercased() == "herness", url.host?.lowercased() == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, items.count == Set(items.map(\.name)).count,
              Set(items.map(\.name)) == Set(["endpoint", "code", "k"]) || Set(items.map(\.name)) == Set(["endpoint", "code", "k", "fp"]),
              let endpoint = items.first(where: { $0.name == "endpoint" })?.value,
              let code = items.first(where: { $0.name == "code" })?.value,
              let secret = items.first(where: { $0.name == "k" })?.value else { return nil }
        self.init(endpoint: endpoint, code: code, secret: secret, fingerprint: items.first(where: { $0.name == "fp" })?.value)
    }

    init?(endpoint: String, code: String, secret: String, fingerprint: String? = nil) {
        let normalized = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pin = fingerprint?.lowercased()
        guard let url = URL(string: normalized), RemoteEndpoint.isAllowed(url),
              code.count == 6,
              code.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              RemoteSealed.isSecret(secret),
              pin.map(RemoteEndpoint.isFingerprint) ?? true else { return nil }
        self.endpoint = normalized
        self.code = code
        self.secret = secret
        self.fingerprint = pin
    }
}

/// Refuses every redirect: nothing but the paired desktop can answer a
/// sealed request anyway.
final class RemoteSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var pinned = ""
    /// The paired desktop's certificate fingerprint. A server is trusted when
    /// its leaf matches it exactly, otherwise only through the normal CA check
    /// (the cloud tunnel) — a LAN impostor passes neither.
    var fingerprint: String {
        get { lock.lock(); defer { lock.unlock() }; return pinned }
        set { lock.lock(); pinned = newValue; lock.unlock() }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let pin = fingerprint
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, !pin.isEmpty,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map({ String(format: "%02x", $0) }).joined() == pin else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
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
    @Published private(set) var remoteProjects: [RemoteProjectDescriptor] = []
    @Published private(set) var remoteSelectedProjectID: String?
    @Published var errorMessage: String?
    /// Set when a `herness://pair` link arrives; the user has to confirm it.
    @Published var pendingPair: PendingPairRequest?

    private let sessionDelegate = RemoteSessionDelegate()
    private lazy var session = URLSession(configuration: .default, delegate: sessionDelegate, delegateQueue: nil)
    private let secure = SecureStore()
    private var eventTask: Task<Void, Never>?
    /// The id the desktop knows this phone by; it names the sealing key.
    private var deviceID = ""
    private var lastSequence: Int64 = 0
    /// Other addresses of the paired desktop (LAN, tunnel). Tried in turn when
    /// the current one stops answering, e.g. a restarted quick tunnel.
    private var knownEndpoints: [String] = []
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }()

    init() {
        endpoint = secure.read("endpoint") ?? ""
        token = secure.read("token") ?? ""
        deviceID = secure.read("device") ?? ""
        sessionDelegate.fingerprint = secure.read("fingerprint") ?? ""
        knownEndpoints = (secure.read("endpoints") ?? "").split(separator: "\n").map(String.init)
        if isPaired { Task { await connect() } }
    }

    /// A pairing from before the sealed channel has no device id: scan again.
    var isPaired: Bool { !endpoint.isEmpty && !token.isEmpty && !deviceID.isEmpty }
    var workspaceID: String { remoteProjects.first(where: { $0.id == remoteSelectedProjectID })?.workspaceId ?? bootstrap?.workspaceId ?? snapshot?.workspaceId ?? "" }

    private func pair(_ payload: PairingPayload) async {
        guard !isPairing else { return }
        isPairing = true
        defer { isPairing = false }
        let previousPin = sessionDelegate.fingerprint
        sessionDelegate.fingerprint = payload.fingerprint ?? ""
        do {
            let (data, status) = try await exchange("/v1/control/pair/complete", method: "POST", body: try encoder.encode(PairRequest(code: payload.code, deviceName: UIDevice.current.name)), base: payload.endpoint, secret: payload.secret, device: RemoteSealed.pairingDevice)
            try validate(status, data: data)
            let result = try decoder.decode(PairingResult.self, from: data)
            endpoint = payload.endpoint; token = result.token; deviceID = result.deviceId; isGuest = false; UserDefaults.standard.set(false, forKey: "herness.guest"); UserDefaults.standard.set(false, forKey: "worksOffline")
            secure.write(token, key: "token")
            secure.write(deviceID, key: "device")
            if let pin = payload.fingerprint { secure.write(pin, key: "fingerprint") } else { secure.delete("fingerprint") }
            knownEndpoints = []; endpoint = ""; useEndpoint(payload.endpoint)
            await connect()
        } catch { sessionDelegate.fingerprint = previousPin; errorMessage = error.localizedDescription }
    }

    func consumePairURL(_ url: URL) {
        guard let payload = PairingPayload(url: url) else {
            errorMessage = "This QR code is not a valid HerNess pairing code."
            return
        }
        // A herness:// link can be opened by any web page, so never pair
        // straight from it: hold the request until the user confirms the host.
        pendingPair = PendingPairRequest(endpoint: payload.endpoint, code: payload.code, secret: payload.secret, fingerprint: payload.fingerprint)
    }

    /// Pairs with the host the user just confirmed.
    func confirmPendingPair() async {
        guard let pending = pendingPair else { return }
        pendingPair = nil
        guard let payload = PairingPayload(endpoint: pending.endpoint, code: pending.code, secret: pending.secret, fingerprint: pending.fingerprint) else {
            errorMessage = "This pairing request is not valid."
            return
        }
        await pair(payload)
    }

    func cancelPendingPair() {
        pendingPair = nil
    }

    func connect() async {
        isConnecting = true; defer { isConnecting = false }
        do {
            bootstrap = try await reachDesktop()
            await loadRemoteProjects()
            await loadTranscript()
            errorMessage = nil
            startEvents()
        } catch { errorMessage = error.localizedDescription }
    }

    private struct Transcript: Decodable {
        struct Message: Decodable { let id: String; let kind: String; let text: String; let createdAt: Date }
        let conversationId: String
        let messages: [Message]
    }

    /// Seeds the feed with the desktop conversation so far; the event stream
    /// only carries what happens after the phone connects. Sequence 0 marks
    /// these rows so a reconnect replaces rather than duplicates them.
    private func loadTranscript() async {
        guard bootstrap?.capabilities.contains("transcript") == true,
              let (data, status) = try? await exchange(controlPath("/v1/control/transcript")), (try? validate(status, data: data)) != nil,
              let value = try? decoder.decode(Transcript.self, from: data) else { return }
        let history = value.messages.map {
            ControlEvent(id: "transcript-\($0.id)", sequence: 0, workspaceId: workspaceID, sessionId: value.conversationId, timestamp: $0.createdAt, kind: "\($0.kind).message", payload: ["text": .string($0.text)], artifactId: nil, redacted: false)
        }
        events = history + events.filter { $0.sequence != 0 }
    }

    /// Bootstraps against the current endpoint, then every other known one,
    /// and keeps whichever answers.
    private func reachDesktop() async throws -> Bootstrap {
        var lastError: Error = ClientError.invalidEndpoint
        for candidate in [endpoint] + knownEndpoints where !candidate.isEmpty {
            do {
                let (data, status) = try await exchange("/v1/control/bootstrap", base: candidate, timeout: 8)
                try validate(status, data: data)
                let value = try decoder.decode(Bootstrap.self, from: data)
                useEndpoint(candidate, learned: value.endpoints)
                return value
            } catch { lastError = error }
        }
        throw lastError
    }

    private func useEndpoint(_ value: String, learned: [String] = []) {
        if endpoint != value { endpoint = value; secure.write(value, key: "endpoint") }
        var merged = knownEndpoints
        for item in learned + [value] where !merged.contains(item) { merged.append(item) }
        knownEndpoints = Array(merged.suffix(6))
        secure.write(knownEndpoints.joined(separator: "\n"), key: "endpoints")
    }

    func requestSnapshot() async {
        do { let (data, status) = try await exchange(controlPath("/v1/control/snapshot/request"), method: "POST"); try validate(status, data: data); snapshot = try decoder.decode(WorkspaceSnapshot.self, from: data) }
        catch { errorMessage = error.localizedDescription }
    }

    func readFile(_ path: String) async throws -> String {
        let data = try await readFileData(path)
        guard let text = String(data: data, encoding: .utf8) else { throw ClientError.binaryFile }
        return text
    }

    func readFileData(_ path: String) async throws -> Data {
        let (data, status) = try await exchange(controlPath("/v1/control/file") + query("path", path))
        try validate(status, data: data)
        return data
    }

    func artifactText(_ id: String) async throws -> String {
        let data = try await artifactData(id)
        guard let text = String(data: data, encoding: .utf8) else { throw ClientError.binaryFile }
        return text
    }

    func artifactData(_ id: String) async throws -> Data {
        let (data, status) = try await exchange(controlPath("/v1/control/artifact") + query("id", id))
        try validate(status, data: data)
        return data
    }

    @discardableResult
    func command(kind: String, payload: [String: RemoteJSONValue], expectedRevision: Int64? = nil, timeout: TimeInterval = 120) async throws -> CommandResponse {
        guard !workspaceID.isEmpty else { throw ClientError.invalidEndpoint }
        var payload = payload
        payload["projectID"] = .string(remoteSelectedProjectID ?? "")
        let value = ControlCommand(id: UUID().uuidString, workspaceId: workspaceID, sessionId: bootstrap?.conversationId, projectID: remoteSelectedProjectID, kind: kind, expectedRevision: expectedRevision, payload: payload)
        let (data, status) = try await exchange(controlPath("/v1/control/commands"), method: "POST", body: try encoder.encode(value), timeout: timeout)
        if let commandResponse = try? decoder.decode(CommandResponse.self, from: data), commandResponse.status == "conflict" { return commandResponse }
        try validate(status, data: data)
        return try decoder.decode(CommandResponse.self, from: data)
    }

    func savePhoneSecret(_ value: String, key: String) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { secure.delete("phone.\(key)") } else { secure.write(value, key: "phone.\(key)") }
    }

    func phoneSecret(_ key: String) -> String { secure.read("phone.\(key)") ?? "" }

    /// Stop using the last desktop project while the phone is on a local or
    /// GitHub project. Pairing remains intact so the user can select a desktop
    /// project again without pairing a second time.
    func clearRemoteProjectScope() {
        eventTask?.cancel()
        eventTask = nil
        remoteSelectedProjectID = nil
        snapshot = nil
        events = []
        lastSequence = 0
    }

    func selectRemoteProject(_ id: String) async {
        guard isPaired else { return }
        do {
            let body = try encoder.encode(["projectID": id])
            let (data, status) = try await exchange("/v2/control/projects/select", method: "POST", body: body)
            try validate(status, data: data)
            let selection = try decoder.decode(RemoteProjectSelection.self, from: data)
            remoteSelectedProjectID = selection.projectID
            snapshot = nil
            // The event stream is workspace-scoped. Reconnect it after a
            // project change so events from the previous remote project cannot
            // remain attached to the new selection.
            events = []
            lastSequence = 0
            startEvents()
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadRemoteProjects() async {
        do {
            let (data, status) = try await exchange("/v2/control/projects")
            try validate(status, data: data)
            let result = try decoder.decode(RemoteProjectsResponse.self, from: data)
            remoteProjects = result.projects
            remoteSelectedProjectID = result.projectID
        } catch {
            // v1-only desktop hosts remain supported.
            remoteProjects = []
            remoteSelectedProjectID = nil
        }
    }

    private func controlPath(_ v1Path: String) -> String {
        remoteSelectedProjectID == nil ? v1Path : v1Path.replacingOccurrences(of: "/v1/", with: "/v2/", options: [.anchored])
    }

    /// Sends one sealed request (see RemoteSealed) and returns the reply body
    /// and status. `onBody`, when given, receives the body as it arrives
    /// instead (the event stream); a reply without its end frame throws.
    private func exchange(_ path: String, method: String = "GET", body: Data? = nil, base: String? = nil, secret: String? = nil, device: String? = nil, timeout: TimeInterval = 60, onBody: ((Data) -> Void)? = nil) async throws -> (Data, Int) {
        let normalized = (base ?? endpoint).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: normalized), RemoteEndpoint.isAllowed(baseURL), let host = baseURL.host,
              let url = URL(string: normalized + RemoteSealed.path) else { throw ClientError.invalidEndpoint }
        let key = RemoteSealed.key(secret ?? token)
        let device = device ?? deviceID
        let sealed = try RemoteSealed.request(key: key, device: device, method: method, path: path, host: baseURL.port.map { "\(host):\($0)" } ?? host, body: body)
        var request = URLRequest(url: url); request.timeoutInterval = timeout; request.httpMethod = "POST"; request.httpBody = sealed
        request.setValue(device, forHTTPHeaderField: "X-Herness-Device"); request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            var data = Data(); for try await byte in bytes { data.append(byte) }
            throw ClientError.server((try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "The desktop refused the request.")
        }
        let nonce = Data(sealed.prefix(12))
        var counter: UInt32 = 0, plain = Data(), status: Int?
        for try await line in bytes.lines {
            let chunk = try RemoteSealed.open(line: line, key: key, nonce: nonce, counter: counter)
            counter += 1
            guard !chunk.isEmpty else { guard let status else { break }; return (plain, status) }
            plain += chunk
            if status == nil, let end = plain.range(of: Data("\r\n\r\n".utf8)) {
                status = String(decoding: plain[..<end.lowerBound], as: UTF8.self).split(separator: " ").dropFirst().first.flatMap { Int($0) }
                plain = Data(plain[end.upperBound...])
            }
            if status != nil, let onBody, !plain.isEmpty { onBody(plain); plain = Data() }
        }
        throw ClientError.server("The desktop reply was cut off.")
    }

    private func query(_ name: String, _ value: String) -> String {
        var components = URLComponents(); components.queryItems = [URLQueryItem(name: name, value: value)]
        return components.percentEncodedQuery.map { "?\($0)" } ?? ""
    }

    private func startEvents() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    var pending = Data(), eventData = ""
                    _ = try await exchange(controlPath("/v1/control/events?after=\(lastSequence)"), timeout: 300) { [weak self] chunk in
                        guard let self else { return }
                        pending += chunk
                        while let newline = pending.firstIndex(of: 10) {
                            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                            pending = Data(pending[(newline + 1)...])
                            if line.isEmpty {
                                if let data = eventData.data(using: .utf8), let event = try? decoder.decode(ControlEvent.self, from: data) {
                                    lastSequence = max(lastSequence, event.sequence); events.append(event); if events.count > 500 { events.removeFirst(events.count - 500) }
                                    if event.kind == "tunnel.ready", case .string(let address)? = event.payload["endpoint"] { useEndpoint(endpoint, learned: [address]) }
                                }
                                eventData = ""
                            } else if line.hasPrefix("data: ") { eventData = String(line.dropFirst(6)) }
                        }
                    }
                } catch {
                    if !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
                    // The address may be gone (new tunnel URL, left the Wi-Fi):
                    // switch to whichever known endpoint answers before retrying.
                    if !Task.isCancelled, let value = try? await reachDesktop() { bootstrap = value }
                }
            }
        }
    }

    private func validate(_ status: Int, data: Data) throws {
        guard (200..<300).contains(status) else { throw ClientError.server(String(data: data, encoding: .utf8) ?? "Remote request failed") }
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
    func write(_ value: String, key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        // ThisDeviceOnly keeps the item out of an encrypted backup, so a
        // restored device cannot read the provider keys or pairing token.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
    func delete(_ key: String) { let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]; SecItemDelete(query as CFDictionary) }

    /// Migrate the pre-account mobile key exactly once.  The old key had no
    /// provider identity, so it is assigned to the provider that was selected
    /// when the app last ran and then removed; future lookups are scoped.
    func migrateLegacyProviderKey(to provider: String) {
        let legacyKey = "phone.provider"
        guard let value = read(legacyKey), !value.isEmpty else { return }
        let scopedKey = MobileAgent.credentialKey(for: provider)
        if let existing = read(scopedKey), !existing.isEmpty {
            delete(legacyKey)
        } else {
            write(value, key: scopedKey)
            delete(legacyKey)
        }
    }
}
