import Foundation

struct GitHubFileChange: Sendable { let path: String; let content: String }
struct GitHubRepository: Identifiable, Hashable, Sendable {
    let id: Int64
    let fullName: String
    let defaultBranch: String
    var owner: String { fullName.split(separator: "/").first.map(String.init) ?? "" }
    var name: String { fullName.split(separator: "/").last.map(String.init) ?? fullName }
}

/// GitHub fallback used when no desktop is reachable. It intentionally creates
/// a branch and pull request; the phone never writes the default branch directly.
struct GitHubClient: Sendable {
    let token: String
    private let session = URLSession.shared

    func tree(owner: String, repository: String, branch: String) async throws -> [String] {
        let ref = try await request("GET", "/repos/\(owner)/\(repository)/git/ref/heads/\(branch)")
        let sha = try json(ref, "object.sha")
        let data = try await request("GET", "/repos/\(owner)/\(repository)/git/trees/\(sha)?recursive=1")
        return ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tree"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
    }

    func read(owner: String, repository: String, path: String, reference: String) async throws -> String {
        let data = try await request("GET", "/repos/\(owner)/\(repository)/contents/\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?ref=\(reference)")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let encoded = object?["content"] as? String, let decoded = Data(base64Encoded: encoded.replacingOccurrences(of: "\n", with: "")), let text = String(data: decoded, encoding: .utf8) else { throw GitHubError.invalidFile }
        return text
    }

    func commitAndOpenPullRequest(owner: String, repository: String, base: String, branch: String, message: String, changes: [GitHubFileChange], title: String, body: String) async throws -> URL {
        let ref = try await request("GET", "/repos/\(owner)/\(repository)/git/ref/heads/\(base)")
        let baseSHA = try json(ref, "object.sha")
        let commit = try await request("GET", "/repos/\(owner)/\(repository)/git/commits/\(baseSHA)")
        let baseTree = try json(commit, "tree.sha")
        let treeEntries = changes.map { ["path": $0.path, "mode": "100644", "type": "blob", "content": $0.content] }
        let tree = try await request("POST", "/repos/\(owner)/\(repository)/git/trees", body: ["base_tree": baseTree, "tree": treeEntries])
        let treeSHA = try json(tree, "sha")
        let newCommit = try await request("POST", "/repos/\(owner)/\(repository)/git/commits", body: ["message": message, "tree": treeSHA, "parents": [baseSHA]])
        let commitSHA = try json(newCommit, "sha")
        _ = try await request("POST", "/repos/\(owner)/\(repository)/git/refs", body: ["ref": "refs/heads/\(branch)", "sha": commitSHA])
        let pr = try await request("POST", "/repos/\(owner)/\(repository)/pulls", body: ["title": title, "head": branch, "base": base, "body": body])
        guard let url = (try? JSONSerialization.jsonObject(with: pr) as? [String: Any])?["html_url"] as? String, let result = URL(string: url) else { throw GitHubError.invalidResponse }
        return result
    }

    fileprivate func request(_ method: String, _ path: String, body: Any? = nil) async throws -> Data {
        guard let url = URL(string: "https://api.github.com" + path) else { throw GitHubError.invalidURL }
        var request = URLRequest(url: url); request.httpMethod = method; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept"); request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw GitHubError.server(String(data: data, encoding: .utf8) ?? "GitHub request failed") }
        return data
    }

    fileprivate func json(_ data: Data, _ keyPath: String) throws -> String {
        let parts = keyPath.split(separator: ".").map(String.init); var current: Any = try JSONSerialization.jsonObject(with: data)
        for part in parts { guard let value = (current as? [String: Any])?[part] else { throw GitHubError.invalidResponse }; current = value }
        guard let value = current as? String else { throw GitHubError.invalidResponse }; return value
    }
}

struct GitHubBlob: Sendable, Hashable { let path: String; let sha: String; let size: Int; let mode: String }
struct GitHubTree: Sendable { let commit: String; let blobs: [GitHubBlob]; let truncated: Bool }

extension GitHubClient {
    func repositories() async throws -> [GitHubRepository] {
        let data = try await request("GET", "/user/repos?per_page=100&sort=updated")
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any] ] ?? []).compactMap { item in
            guard let fullName = item["full_name"] as? String, !fullName.isEmpty else { return nil }
            return GitHubRepository(id: item["id"] as? Int64 ?? Int64(item["id"] as? Int ?? 0), fullName: fullName, defaultBranch: item["default_branch"] as? String ?? "main")
        }
    }

    func branches(owner: String, repository: String) async throws -> [String] {
        let data = try await request("GET", "/repos/\(owner)/\(repository)/branches?per_page=100")
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any] ] ?? []).compactMap { $0["name"] as? String }
    }

    /// Full recursive tree plus the commit it came from, so a clone can be
    /// recorded as a snapshot the phone can later diff against.
    func fullTree(owner: String, repository: String, branch: String) async throws -> GitHubTree {
        let ref = try await request("GET", "/repos/\(owner)/\(repository)/git/ref/heads/\(branch)")
        let commit = try json(ref, "object.sha")
        let data = try await request("GET", "/repos/\(owner)/\(repository)/git/trees/\(commit)?recursive=1")
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let blobs = (root?["tree"] as? [[String: Any]] ?? []).compactMap { item -> GitHubBlob? in
            guard item["type"] as? String == "blob", let path = item["path"] as? String, let sha = item["sha"] as? String else { return nil }
            return GitHubBlob(path: path, sha: sha, size: item["size"] as? Int ?? 0, mode: item["mode"] as? String ?? "100644")
        }
        return GitHubTree(commit: commit, blobs: blobs, truncated: root?["truncated"] as? Bool ?? false)
    }

    func blob(owner: String, repository: String, sha: String) async throws -> Data {
        let data = try await request("GET", "/repos/\(owner)/\(repository)/git/blobs/\(sha)")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let encoded = object?["content"] as? String,
              let decoded = Data(base64Encoded: encoded.replacingOccurrences(of: "\n", with: "")) else { throw GitHubError.invalidFile }
        return decoded
    }

    func defaultBranch(owner: String, repository: String) async throws -> String {
        let data = try await request("GET", "/repos/\(owner)/\(repository)")
        return (try? json(data, "default_branch")) ?? "main"
    }
}

enum GitHubError: LocalizedError {
    case invalidURL, invalidFile, invalidResponse, server(String)
    var errorDescription: String? { switch self { case .invalidURL: return "GitHub URL is invalid."; case .invalidFile: return "GitHub returned a non-UTF-8 file."; case .invalidResponse: return "GitHub returned an unexpected response."; case .server(let message): return message } }
}
