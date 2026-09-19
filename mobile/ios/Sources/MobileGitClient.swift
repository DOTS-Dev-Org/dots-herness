import Foundation

struct MobileGitResult: Sendable {
    let code: Int32
    let output: String

    var succeeded: Bool { code == Int32(HERNESS_GIT_OK) }
    var unavailable: Bool { code == Int32(HERNESS_GIT_UNAVAILABLE) }
}

/// Small Swift boundary over the C ABI. The token is passed only for the
/// duration of the libgit2 call and is never put in a URL or Git config.
final class MobileGitClient: @unchecked Sendable {
    let root: URL
    private let token: @Sendable () -> String

    init(root: URL, token: @escaping @Sendable () -> String) {
        self.root = root
        self.token = token
    }

    var available: Bool { herness_git_available() != 0 }

    func execute(operation: String, arguments: [String: String] = [:]) async -> MobileGitResult {
        let root = self.root.resolvingSymlinksInPath().standardizedFileURL
        let repoPath: String
        if let value = arguments["repoPath"] {
            let candidate = (value.hasPrefix("/") ? URL(fileURLWithPath: value) : root.appendingPathComponent(value))
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
                return MobileGitResult(code: Int32(HERNESS_GIT_ERROR), output: "Git path is outside the workspace.")
            }
            repoPath = candidate.path
        } else {
            repoPath = root.path
        }
        let token = token()
        let argument = arguments["argument"] ?? ""
        let second = arguments["second"] ?? ""
        let authorName = arguments["authorName"] ?? "HerNess Mobile"
        let authorEmail = arguments["authorEmail"] ?? "mobile@herness.local"
        return await Task.detached(priority: .userInitiated) {
            var buffer = [CChar](repeating: 0, count: 64 * 1024)
            let code = buffer.withUnsafeMutableBufferPointer { buffer in
                operation.withCString { operation in
                    repoPath.withCString { repoPath in
                        argument.withCString { argument in
                            second.withCString { second in
                                token.withCString { token in
                                    authorName.withCString { authorName in
                                        authorEmail.withCString { authorEmail in
                                            herness_git_execute(operation, repoPath, argument, second, token, authorName, authorEmail, buffer.baseAddress, buffer.count)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return MobileGitResult(code: code, output: String(cString: buffer))
        }.value
    }

    func clone(repositoryURL: String, destination: URL, branch: String) async throws {
        let result = await execute(operation: "clone", arguments: [
            "repoPath": destination.path,
            "argument": repositoryURL,
            "second": branch,
        ])
        guard result.succeeded else { throw MobileGitError(result: result) }
    }

    func fetch() async throws { try await require("fetch") }
    func checkout(branch: String) async throws { try await require("checkout", argument: branch) }
    func createBranch(_ branch: String) async throws { try await require("create_branch", argument: branch) }
    func commit(message: String, authorName: String, authorEmail: String) async throws {
        try await require("commit", argument: message, authorName: authorName, authorEmail: authorEmail)
    }
    func push(remote: String = "origin", branch: String = "HEAD") async throws {
        try await require("push", argument: remote, second: branch)
    }

    private func require(_ operation: String, argument: String = "", second: String = "", authorName: String = "HerNess Mobile", authorEmail: String = "mobile@herness.local") async throws {
        let result = await execute(operation: operation, arguments: [
            "argument": argument,
            "second": second,
            "authorName": authorName,
            "authorEmail": authorEmail,
        ])
        guard result.succeeded else { throw MobileGitError(result: result) }
    }
}

struct MobileGitError: LocalizedError, Sendable {
    let result: MobileGitResult

    var errorDescription: String? {
        result.unavailable
            ? "The native libgit2 backend is not linked in this build."
            : result.output.ifEmpty("The Git operation failed.")
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
