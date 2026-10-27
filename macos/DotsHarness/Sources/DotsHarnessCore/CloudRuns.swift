// Copyright (c) 2026 DOTS
// Cloud work location: agent tasks run by GitHub Actions in the project's own repository.
//
// The app creates a run record in the HerNess API, then dispatches the
// herness-cloud.yml workflow with the user's GitHub token. The runner streams
// the transcript back to the API (authenticated by GitHub OIDC, see
// shared/CloudRunner.cs) and pushes its changes to a herness/cloud-* branch.

import Foundation
import Security

// MARK: - Git origin

/// A git remote reduced to host and `owner/repo` path.
public struct GitRemote: Equatable, Sendable {
    public let host: String
    public let path: String

    /// Accepts https/ssh URLs and scp-style `git@host:owner/repo`.
    public init?(url raw: String) {
        var remote = raw.trimmingCharacters(in: .whitespaces)
        if remote.hasSuffix(".git") { remote = String(remote.dropLast(4)) }
        var host = ""
        var path = ""
        if let range = remote.range(of: "://") {
            let rest = String(remote[range.upperBound...])
            if let slash = rest.firstIndex(of: "/") {
                host = String(rest[..<slash])
                path = String(rest[rest.index(after: slash)...])
            }
            if let at = host.firstIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        } else if let at = remote.firstIndex(of: "@"), let colon = remote.firstIndex(of: ":"), at < colon {
            host = String(remote[remote.index(after: at)..<colon])
            path = String(remote[remote.index(after: colon)...])
        } else {
            return nil
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty, !path.isEmpty else { return nil }
        self.host = host
        self.path = path
    }

    public var webURL: URL? { URL(string: "https://\(host)/\(path)") }

    /// The `origin` URL of the repository at `repositoryPath`. Reads the git
    /// files directly: spawning git inside a SwiftUI body re-enters the run loop.
    public static func originURL(atRepository repositoryPath: String) -> String? {
        guard let gitDir = gitDirectory(atRepository: repositoryPath) else { return nil }
        let common = (try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8))
            .map { resolve($0.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDir) } ?? gitDir
        guard let config = try? String(contentsOfFile: common + "/config", encoding: .utf8) else { return nil }
        var inOrigin = false
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]" }
            else if inOrigin, line.hasPrefix("url"), let eq = line.firstIndex(of: "=") {
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// The checked-out branch, or nil when HEAD is detached.
    public static func currentBranch(atRepository repositoryPath: String) -> String? {
        guard let gitDir = gitDirectory(atRepository: repositoryPath),
              let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8) else { return nil }
        let prefix = "ref: refs/heads/"
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
    }

    /// `.git` is a directory in a normal checkout and a `gitdir:` file in a worktree.
    private static func gitDirectory(atRepository repositoryPath: String) -> String? {
        guard !repositoryPath.isEmpty else { return nil }
        let dotGit = repositoryPath + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first,
              line.hasPrefix("gitdir:") else { return nil }
        return resolve(line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces), relativeTo: repositoryPath)
    }

    private static func resolve(_ path: String, relativeTo base: String) -> String {
        path.hasPrefix("/") ? path : URL(fileURLWithPath: base).appendingPathComponent(path).standardizedFileURL.path
    }
}

/// A github.com repository a cloud run can target.
public struct GitHubRepository: Equatable, Hashable, Sendable {
    public let owner: String
    public let name: String

    public var fullName: String { "\(owner)/\(name)" }
    public var webURL: URL { URL(string: "https://github.com/\(fullName)")! }
    public var actionsSecretsURL: URL { webURL.appendingPathComponent("settings/secrets/actions") }

    public init?(fullName: String) {
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              parts.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } }) else { return nil }
        owner = String(parts[0])
        name = String(parts[1])
    }

    public init?(remote: GitRemote) {
        guard remote.host.lowercased() == "github.com" else { return nil }
        self.init(fullName: remote.path)
    }

    public init?(workspacePath: String) {
        guard let url = GitRemote.originURL(atRepository: workspacePath),
              let remote = GitRemote(url: url) else { return nil }
        self.init(remote: remote)
    }

    public func branchURL(_ branch: String) -> URL {
        webURL.appendingPathComponent("tree").appendingPathComponent(branch)
    }
}

// MARK: - Run model

public enum CloudRunStatus: String, Codable, Sendable {
    case queued, running, succeeded, failed, cancelled

    public var isActive: Bool { self == .queued || self == .running }
}

public struct CloudRun: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let repository: String
    public let baseRef: String
    public let prompt: String
    public let model: String?
    public let status: CloudRunStatus
    public let cancelRequested: Bool
    public let githubRunID: String?
    public let githubRunURL: String?
    public let resultBranch: String?
    public let resultCommit: String?
    public let summary: String?
    public let error: String?
    public let eventCount: Int
    public let createdAt: String
    public let updatedAt: String
    public let finishedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, repository, prompt, model, status, summary, error
        case baseRef = "base_ref"
        case cancelRequested = "cancel_requested"
        case githubRunID = "github_run_id"
        case githubRunURL = "github_run_url"
        case resultBranch = "result_branch"
        case resultCommit = "result_commit"
        case eventCount = "event_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case finishedAt = "finished_at"
    }

    public var createdDate: Date? { CloudRun.parseDate(createdAt) }

    static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public struct CloudRunEvent: Codable, Identifiable, Equatable, Sendable {
    public let seq: Int
    public let kind: String
    public let text: String
    public let createdAt: String

    public var id: Int { seq }

    enum CodingKeys: String, CodingKey {
        case seq, kind, text
        case createdAt = "created_at"
    }
}

public enum CloudRunError: LocalizedError, Equatable, Sendable {
    case notSignedIn
    case notGitHubRepository
    case noGitHubToken
    case workflowMissing(repository: String, ref: String)
    case workflowInstallForbidden
    case limitReached(Int)
    case github(status: Int, message: String)
    case api(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return AppCopy.text("cloud.error.notSignedIn")
        case .notGitHubRepository: return AppCopy.text("cloud.error.notGitHub")
        case .noGitHubToken: return AppCopy.text("cloud.error.noToken")
        case let .workflowMissing(repository, ref): return AppCopy.format("cloud.error.workflowMissing", repository, ref)
        case .workflowInstallForbidden: return AppCopy.text("cloud.error.installForbidden")
        case let .limitReached(limit): return AppCopy.format("cloud.error.limit", limit)
        case let .github(status, message): return AppCopy.format("cloud.error.github", status, message)
        case let .api(status, message): return AppCopy.format("cloud.error.api", status, message)
        }
    }
}

// MARK: - Workflow template

public enum CloudWorkflow {
    public static let fileName = "herness-cloud.yml"
    public static let path = ".github/workflows/\(fileName)"

    /// Bundled copy of shared/cloud/herness-cloud.yml (kept in sync by tools/sync_skills.py).
    public static func template() -> String? {
        guard let url = Bundle.module.url(forResource: "herness-cloud", withExtension: "yml") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - GitHub

/// The user's own GitHub token: a token saved in HerNess, then GH_TOKEN /
/// GITHUB_TOKEN, then the GitHub CLI's login. It never leaves this machine
/// except in requests to api.github.com.
public enum GitHubCredential {
    private static let service = "com.dots.dotsharness.cloud"
    private static let account = "github-token"
    private static let ghPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    public static var hasStoredToken: Bool { stored() != nil }

    public static func stored() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    public static func store(_ token: String?) {
        SecItemDelete(baseQuery as CFDictionary)
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return }
        var item = baseQuery
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = KeychainAccess.whenUnlocked
        SecItemAdd(item as CFDictionary, nil)
    }

    /// Blocking: may run `gh auth token`. Call off the main actor.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let token = stored() { return token }
        for name in ["GH_TOKEN", "GITHUB_TOKEN"] {
            if let token = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty { return token }
        }
        guard let gh = ghPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let data = try? ProcessRunner.run(
                executable: URL(fileURLWithPath: gh),
                arguments: ["auth", "token", "--hostname", "github.com"],
                timeout: 10,
                mapFailure: { _ in CloudRunError.noGitHubToken }
              ) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public struct GitHubActionsClient: Sendable {
    public let token: String
    private let apiBase = URL(string: "https://api.github.com")!

    public init(token: String) { self.token = token }

    public func defaultBranch(of repository: GitHubRepository) async throws -> String {
        let (data, status) = try await send("GET", "repos/\(repository.fullName)")
        guard status == 200 else { throw githubError(status, data) }
        guard let branch = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["default_branch"] as? String else {
            throw CloudRunError.github(status: status, message: "default_branch missing")
        }
        return branch
    }

    public func dispatchCloudRun(repository: GitHubRepository, ref: String, inputs: [String: String]) async throws {
        let path = "repos/\(repository.fullName)/actions/workflows/\(CloudWorkflow.fileName)/dispatches"
        let (data, status) = try await send("POST", path, body: ["ref": ref, "inputs": inputs])
        if status == 404 { throw CloudRunError.workflowMissing(repository: repository.fullName, ref: ref) }
        guard status == 204 || status == 200 else { throw githubError(status, data) }
    }

    /// Commits the workflow file to `branch`, replacing an older copy.
    public func installWorkflow(repository: GitHubRepository, branch: String, content: String) async throws {
        let path = "repos/\(repository.fullName)/contents/\(CloudWorkflow.path)"
        let (existing, existingStatus) = try await send("GET", path, query: [URLQueryItem(name: "ref", value: branch)])
        var body: [String: Any] = [
            "message": "Add HerNess cloud workflow",
            "content": Data(content.utf8).base64EncodedString(),
            "branch": branch,
        ]
        if existingStatus == 200,
           let sha = (try? JSONSerialization.jsonObject(with: existing) as? [String: Any])?["sha"] as? String {
            body["sha"] = sha
        }
        let (data, status) = try await send("PUT", path, body: body)
        if status == 403 || status == 404 { throw CloudRunError.workflowInstallForbidden }
        guard status == 200 || status == 201 else { throw githubError(status, data) }
    }

    public func cancelRun(repository: GitHubRepository, runID: String) async throws {
        let (data, status) = try await send("POST", "repos/\(repository.fullName)/actions/runs/\(runID)/cancel")
        // 409: the run already finished.
        guard status == 202 || status == 409 else { throw githubError(status, data) }
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> (Data, Int) {
        var components = URLComponents(url: apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func githubError(_ status: Int, _ data: Data) -> CloudRunError {
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
        return .github(status: status, message: message ?? String(decoding: data.prefix(300), as: UTF8.self))
    }
}

// MARK: - HerNess API

@MainActor
public struct CloudRunAPI {
    public let session: MarketplaceSession

    public init(session: MarketplaceSession) { self.session = session }

    public func create(repository: GitHubRepository, baseRef: String, prompt: String, model: String?) async throws -> CloudRun {
        var body: [String: String] = ["repository": repository.fullName, "base_ref": baseRef, "prompt": prompt]
        if let model, !model.isEmpty { body["model"] = model }
        let data = try await request("api/cloud-runs", method: "POST", body: body)
        return try JSONDecoder().decode(RunEnvelope.self, from: data).run
    }

    public func list() async throws -> [CloudRun] {
        struct Envelope: Decodable { let runs: [CloudRun] }
        return try JSONDecoder().decode(Envelope.self, from: try await request("api/cloud-runs")).runs
    }

    public func detail(id: String, after: Int) async throws -> (CloudRun, [CloudRunEvent]) {
        struct Envelope: Decodable { let run: CloudRun; let events: [CloudRunEvent] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: try await request("api/cloud-runs/\(id)?after=\(after)"))
        return (envelope.run, envelope.events)
    }

    public func cancel(id: String, error: String? = nil) async throws -> CloudRun {
        let body = error.map { ["error": String($0.prefix(500))] } ?? [:]
        let data = try await request("api/cloud-runs/\(id)/cancel", method: "POST", body: body)
        return try JSONDecoder().decode(RunEnvelope.self, from: data).run
    }

    private struct RunEnvelope: Decodable { let run: CloudRun }

    private func request(_ path: String, method: String = "GET", body: [String: String]? = nil) async throws -> Data {
        guard session.isSignedIn else { throw CloudRunError.notSignedIn }
        // authorizedData appends a path component; a query string has to ride along unescaped.
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        let encoded = try body.map { try JSONEncoder().encode($0) }
        let (data, response) = try await session.authorizedData(
            path: parts[0],
            query: parts.count > 1 ? parts[1] : nil,
            method: method,
            body: encoded,
            contentType: encoded == nil ? nil : "application/json"
        )
        guard (200..<300).contains(response.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if response.statusCode == 429, json?["error"] as? String == "cloud_run_limit" {
                throw CloudRunError.limitReached(json?["limit"] as? Int ?? 3)
            }
            if response.statusCode == 401 { throw CloudRunError.notSignedIn }
            throw CloudRunError.api(status: response.statusCode, message: json?["error"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }
}
