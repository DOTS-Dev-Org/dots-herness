// Copyright (c) 2026 DOTS
// Model/appearance/legal/permission settings, forge links, /goal and /loop.

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import HarnessPluginKit

@MainActor
extension AppModel {
    public func setModel(_ value: String) {
        router.selectedModelID = value
        endpoint.modelID = value
        endpoint.updateStatus()
        host.settings.set("agent.model.\(activeArea.rawValue)", value.isEmpty ? .null : .string(value))
        if activeArea == .coding {
            host.settings.set("agent.model", value.isEmpty ? .null : .string(value))
        }
        // Levels are model-specific, so a level the new model rejects must not
        // carry over — it would fail the next request with HTTP 400.
        if !router.efforts(for: value).contains(router.selectedEffort) { setEffort("") }
        if router.fastMode, !router.supportsFast(value) { setFast(false) }
        persistSettings()
        Task { await bridge.refreshConnection() }
    }

    /// Reasoning effort for the selected model. Empty means the provider default.
    public func setEffort(_ value: String) {
        router.selectedEffort = value
        objectWillChange.send() // router is a nested ObservableObject; views watching only AppModel must refresh
        host.settings.set("agent.effort.\(activeArea.rawValue)", value.isEmpty ? .null : .string(value))
        if activeArea == .coding {
            host.settings.set("agent.effort", value.isEmpty ? .null : .string(value))
        }
        persistSettings()
    }

    /// Fast (priority) response mode; only meaningful for models that support it.
    public func setFast(_ value: Bool) {
        router.fastMode = value
        objectWillChange.send()
        host.settings.set("agent.fast.\(activeArea.rawValue)", value ? .bool(true) : .null)
        persistSettings()
    }

    public func setAppearance(_ value: Appearance) {
        appearance = value
        host.settings.set("ui.appearance", .string(value.rawValue))
        persistSettings()
    }

    public func loadLegal() async {
        let lang = AppCopy.effectiveLanguage.rawValue
        if let docs = await legal.fetch(lang: lang) {
            // Every @Published write re-renders the window, even with an equal value.
            let needsAcceptance = legal.needsAcceptance(docs)
            if legalDocuments != docs { legalDocuments = docs }
            if legalNeedsAcceptance != needsAcceptance { legalNeedsAcceptance = needsAcceptance }
            if legalLoadFailed { legalLoadFailed = false }
        } else {
            // Offline with nothing cached: gate only if the user never accepted.
            let needsAcceptance = !legal.hasAnyAcceptance
            if !legalLoadFailed { legalLoadFailed = true }
            if legalNeedsAcceptance != needsAcceptance { legalNeedsAcceptance = needsAcceptance }
        }
    }

    public func acceptLegal() {
        guard let docs = legalDocuments else { return }
        legal.accept(docs)
        legalNeedsAcceptance = false
        persistSettings()
    }

    public func legalConsent(_ key: LegalConsentKey) -> Bool { legal.consent(key) }


    public func setPermissionMode(_ value: AgentPermissionMode) {
        permissionMode = value
        chatBridge.setPermissionMode(value)
        codingBridge.setPermissionMode(value)
        host.settings.set("agent.permissionMode", .string(value.rawValue))
        persistSettings()
    }

    public func setBrowserBackend(_ value: BrowserBackend?) {
        let selected = value == .unknown ? nil : value
        browserBackend = selected
        chatBridge.setBrowserBackend(selected)
        codingBridge.setBrowserBackend(selected)
        if let selected {
            host.settings.set("agent.browserBackend", .string(selected.rawValue))
        } else {
            host.settings.set("agent.browserBackend", .null)
        }
        persistSettings()
    }

    public func beginRemotePairing() -> RemotePairingInfo {
        remoteControl.beginPairing()
    }

    public func enableRemoteCloudTunnel() async throws -> String {
        try await remoteControl.enableCloudTunnel()
    }

    public func disableRemoteCloudTunnel() {
        remoteControl.disableCloudTunnel()
    }

    public func dismissFullAccessWarning() {
        guard !fullAccessWarningDismissed else { return }
        fullAccessWarningDismissed = true
        host.settings.set("ui.fullAccessWarningDismissed", .bool(true))
        persistSettings()
    }

    public func dismissVoiceIntro() {
        guard !voiceIntroSeen else { return }
        voiceIntroSeen = true
        host.settings.set("ui.voiceIntroSeen", .bool(true))
        persistSettings()
    }

    public func setAppLanguage(_ value: AppLanguage) {
        AppCopy.setLanguage(value)
        appLanguage = value
        host.settings.set("ui.language", .string(value.rawValue))
        persistSettings()
    }

    public func setSelfVerification(_ value: Bool) {
        selfVerification = value
        chatBridge.setSelfVerification(value)
        codingBridge.setSelfVerification(value)
        host.settings.set("agent.selfVerification", .bool(value))
        persistSettings()
    }

    public func setSeedProjectRules(_ value: Bool) {
        seedProjectRules = value
        chatBridge.setSeedProjectRules(value)
        codingBridge.setSeedProjectRules(value)
        host.settings.set("agent.seedProjectRules", .bool(value))
        persistSettings()
    }

    public func setConfirmBeforeExit(_ value: Bool) {
        confirmBeforeExit = value
        host.settings.set("ui.confirmBeforeExit", .bool(value))
        persistSettings()
    }


    public func presentSettings(tab: String? = nil) {
        settingsInitialTab = tab
        isSettingsPresented = true
    }

    public func requestFeedbackForLatestResponse() {
        guard !workspacePath.isEmpty,
              let conversation = selected,
              let message = conversation.messages.last(where: {
                  ($0.kind == .assistant || $0.kind == .plan)
                      && !$0.streaming
                      && (!$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.mediaItems.isEmpty)
              }) else { return }
        let feedbackType = bridge.feedback(for: message.id, in: conversation.id)?.feedbackType ?? .good
        feedbackRequest = FeedbackTarget(
            conversationID: conversation.id,
            messageID: message.id,
            feedbackType: feedbackType
        )
    }

    public func presentUsage() {
        isUsagePresented = true
    }

    public func setAccountIdentity(_ identity: AccountIdentity) {
        account = identity
    }

    public func syncAccountFromMarketplace() {
        guard let profile = marketplaceSession.profile else { return }
        let displayName = [profile.name, profile.surname]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        let name = displayName.isEmpty ? profile.email : displayName
        let identity = AccountIdentity(
            displayName: name,
            username: profile.username ?? profile.email,
            initials: AccountIdentity.initials(from: name),
            isSignedIn: true
        )
        if account != identity { account = identity }
    }

    /// Browser URL for the project's code-forge pull/merge request list, derived
    /// from `git remote.origin.url`. `nil` when the path isn't a git repo with an
    /// `origin` remote.
    public func forgeURL(for path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "config", "--get", "remote.origin.url"]
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              var remote = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !remote.isEmpty else { return nil }

        if remote.hasSuffix(".git") { remote = String(remote.dropLast(4)) }

        // Normalize scp-style (git@host:owner/repo) and ssh/https to https://host/owner/repo
        var host = ""
        var pathPart = ""
        if let range = remote.range(of: "://") {
            let rest = String(remote[range.upperBound...])
            if let slash = rest.firstIndex(of: "/") {
                host = String(rest[..<slash])
                pathPart = String(rest[rest.index(after: slash)...])
            }
            if let at = host.firstIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        } else if let at = remote.firstIndex(of: "@"), let colon = remote.firstIndex(of: ":") {
            host = String(remote[remote.index(after: at)..<colon])
            pathPart = String(remote[remote.index(after: colon)...])
        } else {
            return nil
        }
        guard !host.isEmpty, !pathPart.isEmpty else { return nil }

        let base = "https://\(host)/\(pathPart)"
        let lowerHost = host.lowercased()
        if lowerHost.contains("github") {
            return URL(string: base + "/pulls")
        } else if lowerHost.contains("gitlab") {
            return URL(string: base + "/-/merge_requests")
        } else if lowerHost.contains("bitbucket") {
            return URL(string: base + "/pull-requests")
        }
        return URL(string: base)
    }

    public var activeProjectForgeURL: URL? {
        forgeURL(for: workspacePath)
    }

    public func openPullRequests() {
        if let url = activeProjectForgeURL { NSWorkspace.shared.open(url) }
    }

    /// ponytail: no Sites subsystem exists yet; send the user to the Cloudflare
    /// Pages dashboard. Replace with a real deploy-targets view when one lands.
    public func openSites() {
        if let url = URL(string: "https://dash.cloudflare.com/?to=/:account/pages") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - /goal


    /// Sets (or clears, when blank) the session goal and refreshes the system prompt.
    public func setSessionGoal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionGoal = trimmed
        sessionGoalRetract?()
        sessionGoalRetract = nil
        if !trimmed.isEmpty {
            sessionGoalRetract = host.prompt.section(
                name: "session:goal",
                order: 10,
                text: "## Session goal\n\nThe user is working toward this goal for the current session. Keep responses aligned with it and flag when work drifts away from it:\n\n\(trimmed)"
            )
        }
        bridge.updateSystemPrompt(host.prompt.assembledText())
    }

    // MARK: - /loop

    /// Creates a recurring scheduled task that re-runs `instruction` in the current
    /// workspace every `everyMinutes` minutes. Managed afterwards from the Tasks sheet.
    @discardableResult
    public func createLoopTask(everyMinutes: Int, instruction: String) -> ScheduledTask {
        let task = ScheduledTask(
            name: String(instruction.prefix(48)),
            cron: Self.loopCron(everyMinutes: everyMinutes),
            prompt: instruction,
            workspacePath: workspacePath
        )
        scheduler.upsert(task)
        return task
    }

    /// ponytail: minute intervals that don't divide 60 fire on the hour boundary
    /// (e.g. `*/45` -> :00 and :45), not as a true rolling interval. Good enough
    /// for "every N minutes" loops; upgrade to a real interval scheduler if needed.
    static func loopCron(everyMinutes m: Int) -> String {
        let mins = max(1, m)
        if mins < 60 { return "*/\(mins) * * * *" }
        let hours = mins / 60
        return hours < 24 ? "0 */\(hours) * * *" : "0 0 * * *"
    }

    public func signOut() {
        setWorkspace("")
        account = .signedOut()
        Task { @MainActor [weak self] in
            await self?.marketplaceSession.signOut()
        }
    }

    public func persistSettings() {
        let snapshot = host.settings.snapshot()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: paths.settings, options: .atomic)
        }
    }
}
