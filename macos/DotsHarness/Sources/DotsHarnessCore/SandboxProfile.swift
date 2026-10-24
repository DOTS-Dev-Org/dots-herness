// Copyright (c) 2026 DOTS
// macOS process policy for sandbox worktrees.

import Darwin
import Foundation

public struct SandboxExecutionPolicy: Sendable, Equatable {
    public let workspaceURL: URL
    public let networkAccess: Bool
    public let browserSafe: Bool
    /// Extra writable paths outside the workspace — used for a sandbox
    /// worktree's git metadata (`.git/worktrees/<name>` and the shared
    /// `.git/objects` in the origin checkout), which git needs to write to
    /// even though it lives outside the worktree itself. Never the origin's
    /// working-tree files: only its `.git` directory is added here.
    public let additionalWritableRoots: [URL]

    public init(
        workspaceURL: URL,
        networkAccess: Bool = true,
        additionalWritableRoots: [URL] = [],
        browserSafe: Bool = false
    ) {
        self.workspaceURL = SandboxProfile.canonicalURL(workspaceURL)
        self.networkAccess = networkAccess
        self.additionalWritableRoots = additionalWritableRoots.map(SandboxProfile.canonicalURL)
        self.browserSafe = browserSafe
    }

    /// A command the agent runs in a sandbox worktree. The policy's own
    /// `networkAccess` (Settings, or a scheduled task's `allowsNetwork`) decides
    /// whether it may reach the network; the IPC services denied by
    /// `browserSafe` stay denied either way.
    public func agentCommandPolicy() -> SandboxExecutionPolicy {
        SandboxExecutionPolicy(
            workspaceURL: workspaceURL,
            networkAccess: networkAccess,
            additionalWritableRoots: additionalWritableRoots,
            browserSafe: true
        )
    }

    public func strictAgentPolicy() -> SandboxExecutionPolicy {
        SandboxExecutionPolicy(
            workspaceURL: workspaceURL,
            networkAccess: false,
            additionalWritableRoots: additionalWritableRoots,
            browserSafe: true
        )
    }
}

/// A path inside a writable root that the sandbox must keep read-only.
public struct SandboxProtectedPath: Sendable, Equatable {
    public let path: String
    public let isDirectory: Bool

    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }
}

public enum SandboxProfileError: LocalizedError, Equatable {    case unavailable
    case invalidWritableRoot(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The macOS process sandbox is unavailable. The command was not started."
        case .invalidWritableRoot(let path):
            return "The sandbox rejected an unsafe writable root: \(path)"
        }
    }
}

enum SandboxProfile {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    static func canonicalURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard let resolved = standardized.withUnsafeFileSystemRepresentation({
            realpath($0, &buffer)
        }) else {
            return standardized.resolvingSymlinksInPath()
        }
        return URL(
            fileURLWithPath: String(cString: resolved),
            isDirectory: standardized.hasDirectoryPath
        )
    }

    /// The per-user temp directory (`/var/folders/…/T`). Foundation, `mktemp`
    /// and SwiftPM resolve it through `confstr`, not `$TMPDIR`, so it cannot be
    /// redirected into the workspace: `swift build` fails unless it is writable.
    static var userTemporaryDirectory: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else {
            return canonicalURL(FileManager.default.temporaryDirectory)
        }
        return canonicalURL(URL(fileURLWithPath: String(cString: buffer), isDirectory: true))
    }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    static func arguments(
        executable: String,
        arguments: [String],
        policy: SandboxExecutionPolicy
    ) throws -> [String] {
        try buildArguments(
            executable: executable,
            arguments: arguments,
            workspaceURL: policy.workspaceURL,
            writableRoots: [policy.workspaceURL] + policy.additionalWritableRoots,
            networkAccess: policy.networkAccess,
            browserSafe: policy.browserSafe
        )
    }

    /// `sandbox-exec`'s own arguments (the `-D ... -p <profile>` block) with
    /// no executable or arguments appended — for callers (plugin/MCP process
    /// launch) that build their own argv on top of it, one level removed from
    /// `WorkspaceTools`/`TerminalSession`.
    static func launchPrefix(policy: SandboxExecutionPolicy) throws -> [String] {
        try buildArguments(
            executable: nil,
            arguments: [],
            workspaceURL: policy.workspaceURL,
            writableRoots: [policy.workspaceURL] + policy.additionalWritableRoots,
            networkAccess: policy.networkAccess,
            browserSafe: policy.browserSafe
        )
    }

    static func lifecycleArguments(
        executable: String,
        arguments: [String],
        workspaceURL: URL,
        writableRoots: [URL],
        networkAccess: Bool = false,
        browserSafe: Bool = false
    ) throws -> [String] {
        try buildArguments(
            executable: executable,
            arguments: arguments,
            workspaceURL: workspaceURL,
            writableRoots: writableRoots,
            networkAccess: networkAccess,
            browserSafe: browserSafe
        )
    }

    private static func buildArguments(
        executable: String?,
        arguments: [String],
        workspaceURL: URL,
        writableRoots: [URL],
        networkAccess: Bool,
        browserSafe: Bool
    ) throws -> [String] {
        guard isAvailable else { throw SandboxProfileError.unavailable }

        let workspace = canonicalURL(workspaceURL)
        let roots = try uniqueRoots(writableRoots)
        guard !roots.isEmpty else { throw SandboxProfileError.invalidWritableRoot("<empty>") }

        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let memory = workspace.appendingPathComponent(".mem", isDirectory: true)
        let protectedPaths = protectedWritePaths(in: roots)
        let profile = makeProfile(
            writableRootCount: roots.count,
            protectedWritePaths: protectedPaths,
            networkAccess: networkAccess,
            browserSafe: browserSafe
        )

        var result = [
            "-D", "WORKSPACE=\(workspace.path)",
            "-D", "HOME=\(home.path)",
            "-D", "MEMORY=\(memory.path)",
            "-D", "USERTEMP=\(userTemporaryDirectory.path)",
            "-D", "SSH=\(home.appendingPathComponent(".ssh").path)",
            "-D", "AWS=\(home.appendingPathComponent(".aws").path)",
            "-D", "KEYCHAINS=\(home.appendingPathComponent("Library/Keychains").path)",
            // Config directories and dotfiles that routinely hold plaintext
            // tokens: gh/npm/docker/kube configs under ~/.config, cloud and
            // chat-app session state under Application Support, ~/.netrc and
            // ~/.npmrc themselves.
            "-D", "DOTCONFIG=\(home.appendingPathComponent(".config").path)",
            "-D", "APPSUPPORT=\(home.appendingPathComponent("Library/Application Support").path)",
            "-D", "NETRC=\(home.appendingPathComponent(".netrc").path)",
            "-D", "NPMRC=\(home.appendingPathComponent(".npmrc").path)",
            // More places where a credential sits in plain text: the git
            // credential helper's file, the docker and kubernetes configs,
            // GPG and package-manager keys, and the shell history that
            // records every `TOKEN=…` that was typed.
            "-D", "GITCREDENTIALS=\(home.appendingPathComponent(".git-credentials").path)",
            "-D", "DOCKER=\(home.appendingPathComponent(".docker").path)",
            "-D", "KUBE=\(home.appendingPathComponent(".kube").path)",
            "-D", "GNUPG=\(home.appendingPathComponent(".gnupg").path)",
            "-D", "CARGO=\(home.appendingPathComponent(".cargo").path)",
            "-D", "GEM=\(home.appendingPathComponent(".gem").path)",
            "-D", "MAVEN=\(home.appendingPathComponent(".m2").path)",
            "-D", "ZSHHISTORY=\(home.appendingPathComponent(".zsh_history").path)",
            "-D", "BASHHISTORY=\(home.appendingPathComponent(".bash_history").path)",
            "-D", "LOCALSHARE=\(home.appendingPathComponent(".local/share").path)",
        ]
        for (index, root) in roots.enumerated() {
            result += ["-D", "WRITE_ROOT_\(index)=\(root.path)"]
        }
        for (index, path) in protectedPaths.enumerated() {
            result += ["-D", "PROTECTED_\(index)=\(path.path)"]
        }
        result += ["-p", profile]
        if let executable { result.append(executable) }
        return result + arguments
    }

    /// Points common package-manager caches at a directory inside the
    /// workspace instead of their `~`-relative defaults, which the sandbox
    /// leaves read-only. Without this, `npm install`/`cargo build`/`pip
    /// install`/`go build`/`gradle` fail outright the first time they try to
    /// write their cache — not a security boundary, just where the cache
    /// lives, so no extra writable root is needed: `.sandbox-cache` is
    /// already inside WORKSPACE.
    static func cacheEnvironment(workspaceURL: URL) -> [String: String] {
        let cache = canonicalURL(workspaceURL).appendingPathComponent(".sandbox-cache", isDirectory: true)
        return [
            "NPM_CONFIG_CACHE": cache.appendingPathComponent("npm").path,
            "YARN_CACHE_FOLDER": cache.appendingPathComponent("yarn").path,
            "CARGO_HOME": cache.appendingPathComponent("cargo").path,
            "PIP_CACHE_DIR": cache.appendingPathComponent("pip").path,
            "GOPATH": cache.appendingPathComponent("go").path,
            "GOCACHE": cache.appendingPathComponent("go-build").path,
            "GRADLE_USER_HOME": cache.appendingPathComponent("gradle").path,
        ]
    }

    /// Git metadata a sandboxed agent must not be able to rewrite. `hooks/`
    /// would run on the user's next git command, and `config` can point git at
    /// another pager, hook path or ssh command — both are ways out of the
    /// sandbox that need no code to run in here.
    ///
    /// A writable root is a git metadata directory when it holds a `HEAD`
    /// file. A linked worktree's own `.git` is a *file* pointing at the real
    /// directory, so only the origin's `.git` and its `worktrees/<name>`
    /// entries are picked up — never the agent's own workspace.
    static func protectedWritePaths(in roots: [URL]) -> [SandboxProtectedPath] {
        let manager = FileManager.default
        var result: [SandboxProtectedPath] = []
        for root in roots {
            var headIsDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.appendingPathComponent("HEAD").path, isDirectory: &headIsDirectory),
                  !headIsDirectory.boolValue else { continue }
            let hooks = root.appendingPathComponent("hooks", isDirectory: true)
            var hooksIsDirectory: ObjCBool = false
            if manager.fileExists(atPath: hooks.path, isDirectory: &hooksIsDirectory), hooksIsDirectory.boolValue {
                result.append(SandboxProtectedPath(path: hooks.path, isDirectory: true))
            }
            for name in ["config", "config.worktree"] {
                let file = root.appendingPathComponent(name)
                if manager.fileExists(atPath: file.path) {
                    result.append(SandboxProtectedPath(path: file.path, isDirectory: false))
                }
            }
        }
        return result
    }

    private static func uniqueRoots(_ roots: [URL]) throws -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for root in roots {
            let normalized = canonicalURL(root)
            guard normalized.path != "/" else {
                throw SandboxProfileError.invalidWritableRoot(normalized.path)
            }
            guard seen.insert(normalized.path).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    private static func makeProfile(
        writableRootCount: Int,
        protectedWritePaths: [SandboxProtectedPath],
        networkAccess: Bool,
        browserSafe: Bool
    ) -> String {
        var lines = [
            "(version 1)",
            "(deny default)",
            "(import \"system.sb\")",
            "(allow process-fork process-exec)",
            "(allow process-info* (target self))",
            "(allow signal (target self))",
            "(allow file-read*)",
            "(allow file-read-metadata)",
            "(allow file-map-executable (subpath (param \"WORKSPACE\")))",
            "(allow file-map-executable (subpath \"/tmp\"))",
            "(allow file-map-executable (subpath \"/private/tmp\"))",
            "(allow file-write* (literal \"/dev/null\"))",
        ]

        for index in 0..<writableRootCount {
            lines.append("(allow file-write* (subpath (param \"WRITE_ROOT_\(index)\")))")
        }
        lines.append("(allow file-write* (subpath \"/tmp\"))")
        lines.append("(allow file-write* (subpath \"/private/tmp\"))")
        lines.append("(allow file-write* (subpath (param \"USERTEMP\")))")

        if networkAccess {
            lines.append("(system-network)")
            lines.append("(allow network-outbound)")
        } else {
            lines.append("(deny network-outbound)")
            lines.append("(deny network-inbound)")
            lines.append("(deny network-bind)")
        }

        // Seatbelt takes the LAST matching rule, most-specific-last. The
        // sandbox's own worktrees live under ~/Library/Application Support
        // (see SandboxWorkspaces.root()), so denying that whole tree here
        // would also revoke the write access just granted to the roots
        // above. Deny the broad secret trees first, then re-grant the
        // specific roots so a root nested inside one of them still works,
        // then deny MEMORY last so `.mem` — nested inside the workspace root
        // — stays blocked even though the roots were just re-granted.
        for parameter in ["SSH", "AWS", "KEYCHAINS", "DOTCONFIG", "APPSUPPORT", "NETRC", "NPMRC",
                          "GITCREDENTIALS", "DOCKER", "KUBE", "GNUPG", "CARGO", "GEM", "MAVEN",
                          "ZSHHISTORY", "BASHHISTORY", "LOCALSHARE"] {
            lines.append("(deny file-read* (subpath (param \"\(parameter)\")))")
            lines.append("(deny file-write* (subpath (param \"\(parameter)\")))")
        }
        lines.append("(allow file-read* (subpath (param \"WORKSPACE\")))")
        for index in 0..<writableRootCount {
            lines.append("(allow file-read* (subpath (param \"WRITE_ROOT_\(index)\")))")
            lines.append("(allow file-write* (subpath (param \"WRITE_ROOT_\(index)\")))")
        }
        lines.append("(deny file-read* (subpath (param \"MEMORY\")))")
        lines.append("(deny file-write* (subpath (param \"MEMORY\")))")

        // Git metadata stays read-only even though its directory is writable:
        // the deny comes last so it wins over the write roots granted above.
        for (index, path) in protectedWritePaths.enumerated() {
            let rule = path.isDirectory ? "subpath" : "literal"
            lines.append("(deny file-write* (\(rule) (param \"PROTECTED_\(index)\")))")
        }

        for service in [
            "com.apple.SecurityServer",
            "com.apple.securityd",
            "com.apple.securityd.xpc",
            "com.apple.securityd.general",
            "com.apple.securityd.systemkeychain",
        ] {
            lines.append("(deny mach-lookup (global-name \"\(service)\"))")
        }

        if browserSafe {
            for service in [
                "com.apple.LaunchServices",
                "com.apple.LaunchServices.lsregister",
                "com.apple.systemevents",
                "com.apple.coreservicesd",
                "com.apple.pasteboard",
            ] {
                lines.append("(deny mach-lookup (global-name \"\(service)\"))")
            }
        }

        return lines.joined(separator: "\n")
    }
}
