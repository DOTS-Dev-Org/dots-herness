// Copyright (c) 2026 DOTS
// Remote work locations: an SSH host, the folder selected on it, and the
// execution target that tells the tool layer which machine a command runs on.

import Foundation

/// One entry of the work-location picker's remote section. Mirrors a `Host`
/// stanza in `~/.ssh/config`.
///
/// There is deliberately no password field: the app never stores an SSH
/// password in a file, and a type without the field cannot leak one.
public struct SSHHost: Codable, Sendable, Equatable, Identifiable {
    public var alias: String
    public var hostName: String
    public var user: String
    public var port: Int
    public var identityFile: String?
    /// True when the app wrote this stanza itself (inside its markers) and may
    /// rewrite or remove it. Hand-written stanzas are read but never edited.
    public var managedByApp: Bool

    public var id: String { alias }

    public init(
        alias: String,
        hostName: String,
        user: String,
        port: Int = 22,
        identityFile: String? = nil,
        managedByApp: Bool = false
    ) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.managedByApp = managedByApp
    }

    public var displayDestination: String {
        let base = user.isEmpty ? hostName : "\(user)@\(hostName)"
        return port == 22 ? base : "\(base):\(port)"
    }
}

/// A host plus the folder on it that the agent works in.
public struct SSHTarget: Sendable, Equatable, Codable {
    public let alias: String
    public let remotePath: String

    public init(alias: String, remotePath: String) {
        self.alias = alias
        self.remotePath = remotePath
    }

    /// Conversation/terminal identity for a remote workspace. Kept distinct
    /// from a local path so `~/src/app` on a remote host never collides with
    /// the local directory of the same name.
    public var identity: String { "ssh://\(alias)\(remotePath.hasPrefix("/") ? "" : "/")\(remotePath)" }
}

public enum SSHError: LocalizedError, Equatable {
    case sshUnavailable
    case notReachable(String)
    case hostKeyChanged(String)
    case authFailed(String)
    case passwordAuthDisabled
    case pathMissing(String)
    case configWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sshUnavailable:
            return AppCopy.text("ssh.error.unavailable")
        case .notReachable(let host):
            return AppCopy.format("ssh.error.notReachable", host)
        case .hostKeyChanged(let host):
            return AppCopy.format("ssh.error.hostKeyChanged", host)
        case .authFailed(let host):
            return AppCopy.format("ssh.error.authFailed", host)
        case .passwordAuthDisabled:
            return AppCopy.text("ssh.error.passwordAuthDisabled")
        case .pathMissing(let path):
            return AppCopy.format("ssh.error.pathMissing", path)
        case .configWriteFailed(let detail):
            return AppCopy.format("ssh.error.configWriteFailed", detail)
        }
    }
}

/// Where a command runs. `.local` is the existing behaviour verbatim — the
/// optional sandbox policy it carries is the same value the tool layer used
/// before this type existed.
///
/// This is deliberately *not* an extra case on `SandboxExecutionPolicy`: that
/// type canonicalises its workspace through `realpath(3)` and its non-nil-ness
/// means "the agent is jailed" throughout MCP, plugins and the system prompt.
/// A remote host is neither of those things.
public enum ExecutionTarget: Sendable, Equatable {
    case local(SandboxExecutionPolicy?)
    case remote(SSHTarget)

    public var sandboxPolicy: SandboxExecutionPolicy? {
        if case .local(let policy) = self { return policy }
        return nil
    }

    public var remoteTarget: SSHTarget? {
        if case .remote(let target) = self { return target }
        return nil
    }

    public var isRemote: Bool { remoteTarget != nil }
}

/// The composer's work-location selection, persisted in app settings.
public enum WorkLocationSetting: Codable, Sendable, Equatable {
    case local
    case localWorktree
    case remote(alias: String)

    public var remoteAlias: String? {
        if case .remote(let alias) = self { return alias }
        return nil
    }

    public var isRemote: Bool { remoteAlias != nil }

    /// Compact settings representation: `local`, `localWorktree`, `remote:<alias>`.
    public var storageValue: String {
        switch self {
        case .local: return "local"
        case .localWorktree: return "localWorktree"
        case .remote(let alias): return "remote:\(alias)"
        }
    }

    public init(storageValue: String) {
        if storageValue.hasPrefix("remote:") {
            let alias = String(storageValue.dropFirst("remote:".count))
            self = alias.isEmpty ? .local : .remote(alias: alias)
        } else if storageValue == "localWorktree" {
            self = .localWorktree
        } else {
            self = .local
        }
    }
}
