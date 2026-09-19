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

    public func strictAgentPolicy() -> SandboxExecutionPolicy {
        SandboxExecutionPolicy(
            workspaceURL: workspaceURL,
            networkAccess: false,
            additionalWritableRoots: additionalWritableRoots,
            browserSafe: true
        )
    }
}

public enum SandboxProfileError: LocalizedError, Equatable {
    case unavailable
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
        let profile = makeProfile(
            writableRootCount: roots.count,
            networkAccess: networkAccess,
            browserSafe: browserSafe
        )

        var result = [
            "-D", "WORKSPACE=\(workspace.path)",
            "-D", "HOME=\(home.path)",
            "-D", "MEMORY=\(memory.path)",
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
        ]
        for (index, root) in roots.enumerated() {
            result += ["-D", "WRITE_ROOT_\(index)=\(root.path)"]
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

        if networkAccess && !browserSafe {
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
        for parameter in ["SSH", "AWS", "KEYCHAINS", "DOTCONFIG", "APPSUPPORT", "NETRC", "NPMRC"] {
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
