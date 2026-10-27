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
        // The router decides whether the id is one a catalog knows; reading back
        // what it accepted keeps the endpoint mirror and the setting in step.
        let selected = router.select(modelID: value)
        endpoint.modelID = selected
        endpoint.updateStatus()
        let storedModel: JSONValue = selected.isEmpty ? .null : .string(selected)
        host.settings.set("agent.model", storedModel)
        // Keep the old coding-scoped key in sync during the settings migration.
        host.settings.set("agent.model.coding", storedModel)
        if let conversationID = bridge.selectedID {
            bridge.setConversationModelPreference(selected.isEmpty ? nil : selected, for: conversationID)
        }
        router.persistModelCatalog()
        // Levels are model-specific, so a level the new model rejects must not
        // carry over — it would fail the next request with HTTP 400. Auto has no
        // single model, so retain the user's effort preference for each route.
        if !router.isAutoSelected, !router.efforts(for: selected).contains(router.selectedEffort) { setEffort("") }
        if router.fastMode, !router.supportsFast(selected) { setFast(false) }
        persistSettings()
        Task { await bridge.refreshConnection() }
    }

    /// Switching chats restores that chat's explicit model, or the latest app
    /// default when the chat has never had its own model choice.
    func applyConversationModelSelection(_ conversationID: String?) {
        let conversationPreference = conversationID.flatMap { id in
            bridge.conversations.first(where: { $0.id == id })?.modelPreferenceID
        }
        let appDefault = host.settings.get("agent.model")?.string
            ?? host.settings.get("agent.model.coding")?.string
            ?? ""
        let selected = router.select(modelID: conversationPreference ?? appDefault)
        endpoint.modelID = selected
        endpoint.updateStatus()
        if router.pendingModelID != nil {
            Task { await router.refreshModelsIfNeeded() }
        }
        Task { await bridge.refreshConnection() }
    }

    /// Reasoning effort preference. Empty means automatic/default effort selection.
    public func setEffort(_ value: String) {
        router.selectedEffort = value
        objectWillChange.send() // router is a nested ObservableObject; views watching only AppModel must refresh
        let storedEffort: JSONValue = value.isEmpty ? .null : .string(value)
        host.settings.set("agent.effort", storedEffort)
        host.settings.set("agent.effort.coding", storedEffort)
        persistSettings()
    }

    /// Fast (priority) response mode; only meaningful for models that support it.
    public func setFast(_ value: Bool) {
        router.fastMode = value
        objectWillChange.send()
        host.settings.set("agent.fast", value ? .bool(true) : .null)
        persistSettings()
    }

    /// Response economy is persisted as one project-agent preference. Fast is
    /// intentionally retained as a preference, but the transport ignores its
    /// priority tier while Economy is active.
    public func setUsageMode(_ value: AgentUsageMode) {
        router.usageMode = value
        objectWillChange.send()
        host.settings.set("agent.usageMode", .string(value.rawValue))
        persistSettings()
    }

    /// Response prose is a user setting, not a hidden skill or an inferred
    /// rewrite of the current prompt. The next request receives this choice as
    /// a dynamic style section and output-budget input.
    public func setResponseStylePreference(_ value: AgentResponseStylePreference) {
        router.responseStylePreference = value
        objectWillChange.send()
        host.settings.set(AgentResponseStylePreference.settingsKey, .string(value.rawValue))
        persistSettings()
    }

    public func setMemoryEnabled(_ enabled: Bool) {
        bridge.setMemoryEnabled(enabled)
        if !enabled, section == .memory { section = .home }
        objectWillChange.send()
        host.settings.set(WorkspaceMemory.enabledSettingsKey, .bool(enabled))
        persistSettings()
    }

    public func setMemoryScanInterval(_ interval: MemoryScanInterval) {
        bridge.setMemoryScanInterval(interval)
        objectWillChange.send()
        host.settings.set(MemoryScanInterval.settingsKey, .string(interval.rawValue))
        persistSettings()
    }

    /// Empty returns the exploration subagent to the automatic choice.
    public func setExplorationModel(_ id: String) {
        router.explorationModelID = id
        objectWillChange.send()
        host.settings.set(RouterController.explorationModelKey, .string(id))
        persistSettings()
    }

    /// An explicit choice outlives the usage mode's default in both directions.
    public func setSubagentsEnabled(_ value: Bool) {
        router.subagentsPreference = value
        objectWillChange.send()
        host.settings.set(RouterController.subagentsKey, .bool(value))
        persistSettings()
    }

    public func setAutoAccountFailoverAfterLimit(_ value: Bool) {
        router.autoAccountFailoverAfterLimit = value
        if !value {
            bridge.cancelScheduledLimitResume()
        }
        objectWillChange.send()
        host.settings.set(RouterController.autoAccountFailoverAfterLimitKey, .bool(value))
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


    public func setPermissionMode(_ value: AgentPermissionMode) {
        permissionMode = value
        bridge.setPermissionMode(value)
        host.settings.set("agent.permissionMode", .string(value.rawValue))
        persistSettings()
    }

    public func setBrowserBackend(_ value: BrowserBackend?) {
        let selected = value == .unknown ? nil : value
        browserBackend = selected
        bridge.setBrowserBackend(selected)
        if let selected {
            host.settings.set("agent.browserBackend", .string(selected.rawValue))
        } else {
            host.settings.set("agent.browserBackend", .null)
        }
        persistSettings()
    }

    public func setComputerUseEnabled(_ value: Bool) {
        isComputerUseEnabled = value
        bridge.setComputerUseEnabled(value)
        host.settings.set("agent.computerUseEnabled", .bool(value))
        persistSettings()
    }

    public func beginRemotePairing() -> RemotePairingInfo {
        remoteControl.beginPairing()
    }

    public func enableRemoteCloudTunnel() async throws -> String {
        let endpoint = try await remoteControl.enableCloudTunnel()
        host.settings.set("remote.cloudTunnel", .bool(true))
        persistSettings()
        return endpoint
    }

    public func disableRemoteCloudTunnel() {
        remoteControl.disableCloudTunnel()
        host.settings.set("remote.cloudTunnel", .bool(false))
        persistSettings()
    }

    /// The tunnel comes up on its own whenever the gateway runs, so a phone off
    /// the LAN still reaches it; only an explicit "disable" keeps it down. It
    /// carries sealed requests only (see `RemoteSealed`), never plaintext.
    /// The quick-tunnel URL still changes; the phone learns it from
    /// `tunnel.ready` or bootstrap `endpoints` once it reaches us.
    func restoreRemoteCloudTunnel() {
        guard host.settings.get("remote.cloudTunnel")?.bool != false else { return }
        guard remoteControl.isEnabled, remoteControl.publicEndpoint == nil else { return }
        Task {
            do { _ = try await remoteControl.enableCloudTunnel() }
            catch { remoteControl.publish("tunnel.failed", ["message": .string(error.localizedDescription)]) }
        }
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
        loadLanguagePack()
    }

    /// Fetches the active language when the release did not ship it, then re-renders.
    /// ponytail: a failed download stays on English until the next launch or pick.
    public func loadLanguagePack() {
        let language = appLanguage
        guard !LanguagePacks.isAvailable(language) else { return }
        Task { @MainActor [weak self] in
            try? await LanguagePacks.ensure(language)
            if self?.appLanguage == language { self?.appLanguage = language }
        }
    }

    public func setSkillSuggestionsEnabled(_ value: Bool) {
        skillSuggestionsEnabled = value
        skillSuggestions.enabled = value
        host.settings.set("skills.suggestions.enabled", .bool(value))
        persistSettings()
    }

    public func setSelfVerification(_ value: Bool) {
        selfVerification = value
        bridge.setSelfVerification(value)
        host.settings.set("agent.selfVerification", .bool(value))
        persistSettings()
    }

    public func setSeedProjectRules(_ value: Bool) {
        seedProjectRules = value
        bridge.setSeedProjectRules(value)
        host.settings.set("agent.seedProjectRules", .bool(value))
        persistSettings()
    }

    public func setAutoApprovePlans(_ value: Bool) {
        autoApprovePlans = value
        bridge.setAutoApprovePlans(value)
        host.settings.set("agent.autoApprovePlans", .bool(value))
        persistSettings()
    }

    public func setWorkspaceConflictPolicy(_ value: WorkspaceConflictPolicy) {
        workspaceConflictPolicy = value
        bridge.setWorkspaceConflictPolicy(value)
        host.settings.set("agent.workspaceConflictPolicy", .string(value.rawValue))
        persistSettings()
    }

    public func setConflictWaitSeconds(_ value: Int) {
        let seconds = max(0, value)
        conflictWaitSeconds = seconds
        bridge.setConflictWaitSeconds(seconds)
        host.settings.set("agent.conflictWaitSeconds", .number(Double(seconds)))
        persistSettings()
    }

    public func setConfirmBeforeExit(_ value: Bool) {
        confirmBeforeExit = value
        host.settings.set("ui.confirmBeforeExit", .bool(value))
        persistSettings()
    }

    public func setCloseToTray(_ value: Bool) {
        closeToTray = value
        host.settings.set("ui.closeToTray", .bool(value))
        persistSettings()
    }

    public func setAutoUpdate(_ value: Bool) {
        autoUpdate = value
        host.settings.set("updates.auto", .bool(value))
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
        guard let url = GitRemote.originURL(atRepository: path),
              let remote = GitRemote(url: url),
              let base = remote.webURL else { return nil }
        let lowerHost = remote.host.lowercased()
        if lowerHost.contains("github") {
            return base.appendingPathComponent("pulls")
        } else if lowerHost.contains("gitlab") {
            return base.appendingPathComponent("-/merge_requests")
        } else if lowerHost.contains("bitbucket") {
            return base.appendingPathComponent("pull-requests")
        }
        return base
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
