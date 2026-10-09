// Copyright (c) 2026 DOTS
// SSH hosts and the composer work location.

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import HarnessPluginKit

@MainActor
extension AppModel {
    // MARK: - Remote work location



    /// What the UI shows as the current working folder. A remote workspace has
    /// no local path, so it is named by host and folder instead.
    public var workspaceDisplayPath: String {
        if let remote = remoteWorkspace { return "\(remote.alias):\(remote.remotePath)" }
        return workspacePath
    }

    /// Terminal panes are keyed by this, so a remote folder never shares a
    /// session list with a local directory of the same path.
    public var terminalWorkspaceKey: String {
        return remoteWorkspace?.identity ?? workspacePath
    }

    public func refreshSSHHosts() {
        sshStore.reload()
        sshHosts = sshStore.hosts
        if let alias = workLocation.remoteAlias, sshStore.host(alias: alias) == nil {
            sshNotice = AppCopy.format("ssh.error.notReachable", alias)
            applyWorkLocation(.local)
        }
    }

    public func setWorkLocation(_ setting: WorkLocationSetting) {
        guard setting != workLocation else { return }
        if activeSandbox != nil, setting.isRemote {
            sandboxNotice = "Leave the active sandbox before working on a remote host."
            return
        }
        guard !bridge.anyRunBusy else {
            sshNotice = AppCopy.text("ssh.busy")
            return
        }
        guard let alias = setting.remoteAlias else {
            applyWorkLocation(setting)
            return
        }
        guard let host = sshStore.host(alias: alias) else {
            sshNotice = AppCopy.format("ssh.error.notReachable", alias)
            return
        }
        sshNotice = AppCopy.format("ssh.connecting", host.alias)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .userInitiated) {
                SSHRunner.probe(alias: alias)
            }.value
            switch result {
            case .success:
                self.sshNotice = nil
                self.applyWorkLocation(setting)
                let remembered = self.sshStore.record(alias: alias).lastRemotePath
                if let remembered {
                    self.setRemoteWorkspace(path: remembered)
                } else {
                    self.remoteWorkspace = nil
                    self.bridge.setRemoteTarget(nil)
                }
            case .failure(let error):
                self.sshNotice = error.localizedDescription
            }
        }
    }

    private func applyWorkLocation(_ setting: WorkLocationSetting) {
        workLocation = setting
        if !setting.isRemote {
            if let previous = remoteWorkspace?.alias {
                SSHRunner.closeMaster(alias: previous)
            }
            remoteWorkspace = nil
            bridge.setRemoteTarget(nil)
            bridge.setSandboxPolicy(sandboxExecutionPolicy, branch: activeSandbox?.branch)
        }
        host.settings.set("agent.workLocation", .string(setting.storageValue))
        persistSettings()
    }

    /// Picks the folder on the remote host the agent works in. The path is
    /// resolved on that machine so `~` and symlinks settle before it is stored.
    public func setRemoteWorkspace(path: String) {
        guard let alias = workLocation.remoteAlias else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let resolved = await Task.detached(priority: .userInitiated) {
                SSHRunner.resolveDirectory(alias: alias, path: trimmed)
            }.value
            guard let resolved else {
                self.sshNotice = SSHError.pathMissing(trimmed).localizedDescription
                return
            }
            let target = SSHTarget(alias: alias, remotePath: resolved)
            self.remoteWorkspace = target
            self.bridge.setRemoteTarget(target)
            self.sshStore.rememberRemotePath(alias: alias, path: resolved)
            self.sshNotice = nil
        }
    }

    public func removeSSHHost(alias: String) {
        do {
            try sshStore.remove(alias: alias)
            if workLocation.remoteAlias == alias { applyWorkLocation(.local) }
            refreshSSHHosts()
        } catch {
            sshNotice = error.localizedDescription
        }
    }

    // MARK: - Adding a remote host

    /// Step 1: fetch the host's public keys so the user can check the
    /// fingerprint. Nothing is trusted and no password is asked for yet.
    public func scanSSHHostKey(hostName: String, port: Int) async -> Result<SSHEnrollment.HostKeyScan, Error> {
        await Task.detached(priority: .userInitiated) {
            do { return .success(try SSHEnrollment.scanHostKey(hostName: hostName, port: port)) }
            catch { return .failure(error) }
        }.value
    }

    /// Step 2, after the user confirmed the fingerprint: trust the key,
    /// install our public key using the password once, and write the stanza.
    ///
    /// The password is passed straight through to the one ssh call that needs
    /// it. It is stored only when `rememberPassword` is set, and then only in
    /// the Keychain — never in ~/.ssh/config, which cannot hold one anyway.
    public func enrollSSHHost(
        alias: String,
        user: String,
        hostName: String,
        port: Int,
        password: String,
        scan: SSHEnrollment.HostKeyScan,
        rememberPassword: Bool
    ) async -> Result<SSHHost, Error> {
        guard SSHConfigStore.isValidAlias(alias) else {
            return .failure(SSHError.configWriteFailed(alias))
        }
        let host = SSHHost(
            alias: alias,
            hostName: hostName,
            user: user,
            port: port,
            identityFile: SSHEnrollment.identityFileReference,
            managedByApp: true
        )
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
            do {
                try SSHEnrollment.trust(scan: scan)
                let publicKey = try SSHEnrollment.ensureKeyPair()
                try SSHEnrollment.installPublicKey(
                    user: user,
                    hostName: hostName,
                    port: port,
                    password: password,
                    publicKey: publicKey
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        if case .failure(let error) = outcome { return .failure(error) }

        do {
            try sshStore.add(host, enrolled: true)
        } catch {
            return .failure(error)
        }
        if rememberPassword {
            try? sshStore.storePassword(password, alias: alias)
        } else {
            sshStore.forgetPassword(alias: alias)
        }
        refreshSSHHosts()

        let probe = await Task.detached(priority: .userInitiated) { SSHRunner.probe(alias: alias) }.value
        if case .failure(let error) = probe { return .failure(error) }
        return .success(host)
    }

    /// Adds a host that already authenticates (an existing key, an agent) with
    /// no password step.
    public func addSSHHostWithoutPassword(
        alias: String,
        user: String,
        hostName: String,
        port: Int,
        scan: SSHEnrollment.HostKeyScan
    ) async -> Result<SSHHost, Error> {
        guard SSHConfigStore.isValidAlias(alias) else {
            return .failure(SSHError.configWriteFailed(alias))
        }
        let host = SSHHost(alias: alias, hostName: hostName, user: user, port: port, managedByApp: true)
        do {
            try await Task.detached(priority: .userInitiated) { try SSHEnrollment.trust(scan: scan) }.value
            try sshStore.add(host, enrolled: false)
        } catch {
            return .failure(error)
        }
        refreshSSHHosts()
        let probe = await Task.detached(priority: .userInitiated) { SSHRunner.probe(alias: alias) }.value
        if case .failure(let error) = probe { return .failure(error) }
        return .success(host)
    }

    /// Re-checks a host and reports the outcome in the Settings pane.
    public func testSSHHost(alias: String) {
        sshNotice = AppCopy.format("ssh.connecting", alias)
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { SSHRunner.probe(alias: alias) }.value
            switch result {
            case .success:
                self?.sshNotice = AppCopy.format("ssh.reachable", alias)
            case .failure(let error):
                self?.sshNotice = error.localizedDescription
            }
        }
    }

    /// Lists sub-folders of `path` on a host, for the remote folder picker.
    public func remoteDirectories(alias: String, path: String) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            SSHRunner.listDirectories(alias: alias, path: path)
        }.value
    }

    /// Restores the saved work location once the bridge is up.
    func restoreWorkLocation() {
        refreshSSHHosts()
        let stored = WorkLocationSetting(storageValue: host.settings.get("agent.workLocation")?.string ?? "local")
        guard stored.isRemote else { return }
        setWorkLocation(stored)
    }

    func refreshSandboxWritableRoots() {
        sandboxAgentWritableRoots = activeSandbox.flatMap { try? SandboxWorkspaces.agentWritableRoots(for: $0) } ?? []
    }

    public var sandboxExecutionPolicy: SandboxExecutionPolicy? {
        guard let sandbox = activeSandbox,
              SandboxProfile.canonicalURL(URL(fileURLWithPath: workspacePath, isDirectory: true)).path == sandbox.path else {
            return nil
        }
        return SandboxExecutionPolicy(
            workspaceURL: URL(fileURLWithPath: sandbox.path, isDirectory: true),
            networkAccess: sandboxNetworkAccess,
            additionalWritableRoots: sandboxAgentWritableRoots
        )
    }

}
