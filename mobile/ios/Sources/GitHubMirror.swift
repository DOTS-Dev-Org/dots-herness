import Foundation
import CryptoKit

/// Repository coordinates the phone remembers so a clone can later be pushed
/// back as a branch and pull request without retyping them.
struct RepoCoordinates: Codable, Equatable, Sendable {
    var owner = ""
    var repository = ""
    var branch = "main"

    var isComplete: Bool { !owner.isEmpty && !repository.isEmpty && !branch.isEmpty }
    var slug: String { "\(owner)/\(repository)" }

    static let storageKey = "herness.repo"

    static func load() -> RepoCoordinates {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(RepoCoordinates.self, from: data) else { return RepoCoordinates() }
        return value
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// Accepts `owner/repo`, an https clone URL, or an ssh remote.
    static func parse(_ value: String, branch: String = "main") -> RepoCoordinates? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        text = text.replacingOccurrences(of: "https://github.com/", with: "")
        text = text.replacingOccurrences(of: "git@github.com:", with: "")
        let parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return RepoCoordinates(owner: parts[parts.count - 2], repository: parts[parts.count - 1], branch: branch)
    }
}

extension LocalWorkspaceStore {
    /// Clone straight from GitHub when no desktop is reachable. A linked
    /// libgit2 backend creates the real repository; the REST path is only a
    /// build-time fallback for checkouts that do not ship libgit2 yet.
    func clone(_ repo: RepoCoordinates, token: String, git: MobileGitClient? = nil) async {
        if activeSandbox != nil { localError = "Exit the sandbox before cloning a new repository."; return }
        guard repo.isComplete else { localError = "Enter an owner, repository, and branch."; return }
        let nativeGit = git ?? MobileGitClient(root: root, token: { token })
        if nativeGit.available {
            guard files().isEmpty else {
                localError = "The local workspace is not empty. Create a new workspace before cloning a Git repository."
                return
            }
            cloneStatus = "Cloning \(repo.slug)…"
            do {
                try await nativeGit.clone(repositoryURL: "https://github.com/\(repo.slug).git", destination: root, branch: repo.branch)
                let files = try agentFiles()
                try replaceSnapshot(WorkspaceSnapshot(version: 1, workspaceId: "github:\(repo.slug)", workspace: repo.slug, revision: 0, baseCommitSha: nil, files: files, excluded: [], createdAt: Date()))
                repo.save()
                cloneStatus = "Cloned \(files.count) files from \(repo.slug)."
            } catch {
                cloneStatus = ""
                localError = error.localizedDescription
            }
            return
        }
        let client = GitHubClient(token: token)
        cloneStatus = "Reading \(repo.slug) as a workspace mirror…"
        do {
            let tree = try await client.fullTree(owner: repo.owner, repository: repo.repository, branch: repo.branch)
            if tree.truncated { localError = "This repository is too large for the GitHub tree API; some files were skipped." }
            var files: [WorkspaceFile] = []
            var excluded: [ExcludedFile] = []
            var completed = 0
            for chunk in stride(from: 0, to: tree.blobs.count, by: 8).map({ Array(tree.blobs[$0..<min($0 + 8, tree.blobs.count)]) }) {
                let fetched: [(GitHubBlob, Data)] = try await withThrowingTaskGroup(of: (GitHubBlob, Data).self) { group in
                    for blob in chunk where blob.size <= Self.maximumCloneFileBytes {
                        group.addTask { (blob, try await client.blob(owner: repo.owner, repository: repo.repository, sha: blob.sha)) }
                    }
                    var results: [(GitHubBlob, Data)] = []
                    for try await item in group { results.append(item) }
                    return results
                }
                for blob in chunk where blob.size > Self.maximumCloneFileBytes {
                    excluded.append(ExcludedFile(path: blob.path, reason: "Larger than \(Self.maximumCloneFileBytes / 1_048_576) MB."))
                }
                for (blob, data) in fetched {
                    try write(relativePath: blob.path, data: data)
                    files.append(WorkspaceFile(path: blob.path, bytes: Int64(data.count), sha256: Self.digest(data), mode: blob.mode == "100755" ? 0o755 : 0o644))
                }
                completed += chunk.count
                cloneStatus = "Downloaded \(completed) of \(tree.blobs.count) files…"
            }
            let snapshot = WorkspaceSnapshot(
                version: 1,
                workspaceId: "github:\(repo.slug)",
                workspace: repo.slug,
                revision: 0,
                baseCommitSha: tree.commit,
                files: files.sorted { $0.path < $1.path },
                excluded: excluded,
                createdAt: Date())
            try replaceSnapshot(snapshot)
            repo.save()
            cloneStatus = "Downloaded \(files.count) files to the workspace mirror. Native libgit2 is not linked in this build."
        } catch {
            cloneStatus = ""
            localError = error.localizedDescription
        }
    }

    static let maximumCloneFileBytes = 8 * 1_048_576

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
