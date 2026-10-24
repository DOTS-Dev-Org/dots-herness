// Copyright (c) 2026 DOTS
// Native conversation composer and command palettes.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore
import HarnessPluginKit

/// Full composer height, reported up so the transcript can stay bottom-aligned while the composer grows or shrinks.
struct ComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ComposerView: View {
    @ObservedObject var model: AppModel
    // AppModel does not forward its nested router's change notifications.
    @ObservedObject private var router: RouterController
    @ObservedObject private var promptTemplates: PromptTemplateCatalog
    // `model.draft` is not published on AppModel; this redraws the composer per keystroke.
    @ObservedObject private var draftBox: DraftBox
    @ObservedObject var skillSuggestions: SkillSuggestionMonitor
    @StateObject private var voiceInput: LiveVoiceInput

    @State private var showPermissionMenu = false
    @State private var showModelMenu = false
    @State private var showContextUsage = false
    @State private var showProjectMenu = false
    @State private var showWorkLocationMenu = false
    @State private var showRemoteFolderPicker = false
    @State private var showBranchMenu = false
    @State private var gitSnapshot = GitSnapshot.empty
    @State private var gitRefreshToken = 0
    @State private var gitError: String?
    @State private var gitBarHidden = false
    @State private var queueExpanded = false
    @State private var gitBusy = false
    @State private var highlightedSlashCommandID: String?
    @State private var isDropTargeted = false
    @State private var planPillHovered = false
    @State private var showCacheResumeInfo = false
    @State private var cacheNoticeClock = Date()
    @State private var composerTextWidth: CGFloat = 0
    @FocusState private var composerFocused: Bool

    private var bridge: AgentBridge { model.bridge }

    private static let compactComposerWidth: CGFloat = 360

    private var workLocationIcon: String {
        switch model.workLocation {
        case .local: return "laptopcomputer"
        case .localWorktree: return "arrow.up.right.square"
        case .remote: return "network"
        }
    }

    private var workLocationTitle: String {
        switch model.workLocation {
        case .local: return AppCopy.text("workLocation.local")
        case .localWorktree: return AppCopy.text("workLocation.localWorktree")
        case .remote(let alias): return alias
        }
    }

    /// Derived from the router so the label can never drift from what is sent.
    private var reasoningEffort: String {
        let effort = router.isAutoSelected
            ? router.selectedEffort
            : router.effectiveEffort(for: model.selectedModelID)
        return effort.isEmpty ? "" : ModelPickerPopover.effortLabel(effort)
    }

    private var visibleFollowUpSuggestion: String? {
        guard bridge.followUpConversationID == model.selectedConversationID else { return nil }
        return bridge.followUpSuggestion
    }

    init(model: AppModel, bridge: AgentBridge) {
        self.model = model
        self.router = model.router
        self.promptTemplates = model.promptTemplates
        self.draftBox = model.draftBox
        self.skillSuggestions = model.activeSkillSuggestions
        self._voiceInput = StateObject(
            wrappedValue: LiveVoiceInput(model: model) { text in
                let separator = model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
                model.draft += separator + text
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if slashMenuIsVisible {
                SlashCommandPalette(
                    settings: slashSettings,
                    media: slashMedia,
                    templates: slashTemplates,
                    skills: slashSkills,
                    highlightedID: $highlightedSlashCommandID,
                    onSelect: selectSlashCommand
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            SlotStack(slot: WellKnownSlot.composerAccessory, registry: model.host.slots)

            if let suggestion = skillSuggestions.pending {
                skillSuggestionBanner(suggestion)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            if model.showsVoiceIntro {
                voiceIntroBanner
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            if model.showsFullAccessWarning {
                fullAccessWarning
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            if let question = bridge.pendingQuestion {
                QuestionCard(
                    pending: question,
                    onSubmit: { bridge.answerQuestions($0, in: question.conversationID) },
                    onSkip: { bridge.cancelQuestions(in: question.conversationID) }
                )
                .id(question.id)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }

            if let approval = bridge.pendingApproval {
                approvalBanner(approval)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            if let conflict = bridge.pendingConflict {
                conflictBanner(conflict)
                    .id(conflict.id)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            } else if let waiting = bridge.waitingOnLease {
                leaseWaitingBanner(waiting)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            if let vision = bridge.pendingVisionInstall {
                visionInstallBanner(vision)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            providerLimitNotice
            queueBar
            cacheResumeNotice
            gitBar

            if !(gitSnapshot.isRepository && !gitBarHidden) {
                composerContext
            }

            VStack(spacing: 0) {
                if model.isEditingMessage {
                    editingBanner
                }
                if let historyError = model.historyError {
                    Text(historyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 15)
                        .padding(.top, 8)
                }
                if !model.draftAttachments.isEmpty {
                    draftAttachments
                }
                growingEditor
                composerControls
            }
            .composerOutline()
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ComposerHeightKey.self, value: proxy.size.height)
            }
        }
        .animation(.easeOut(duration: 0.16), value: slashMenuIsVisible)
        .onChange(of: slashMenuIsVisible) { _, isVisible in
            highlightedSlashCommandID = isVisible ? visibleSlashCommands.first?.id : nil
            if isVisible { promptTemplates.refresh(workspacePath: bridge.workspacePath) }
        }
        .onAppear {
            refreshGit()
            promptTemplates.refresh(workspacePath: bridge.workspacePath)
        }
        .task(id: model.selectedConversationID) {
            while !Task.isCancelled {
                cacheNoticeClock = Date()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .onChange(of: model.workspacePath) { _, _ in
            refreshGit()
            promptTemplates.refresh(workspacePath: bridge.workspacePath)
        }
        .onChange(of: model.composerFocusRequestID) { _, _ in composerFocused = true }
        .onChange(of: composerFocused) { _, focused in if focused { bridge.prewarmProvider() } }
        .onChange(of: model.draft.isEmpty) { _, isEmpty in if !isEmpty { bridge.prewarmProvider() } }
        .onChange(of: showBranchMenu) { _, isPresented in
            if isPresented { refreshGit() }
        }
        .sheet(isPresented: $showRemoteFolderPicker) {
            RemoteFolderPickerView(model: model)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers) { model.addDraftAttachments($0) }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                    .overlay {
                        Text(AppCopy.text("conversation.dropFiles"))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                            .allowsHitTesting(false)
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var providerLimitNotice: some View {
        if let conversation = model.selected,
           conversation.canContinue,
           let continuation = conversation.continuation,
           continuation.reason == .providerLimit {
            let target = [continuation.provider, continuation.model]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: " / ")
            ComposerBanner(verticalPadding: 11) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)
                        Text(AppCopy.text("agent.providerLimitTitle"))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.red)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        if !target.isEmpty {
                            Text(target)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        HStack(spacing: 5) {
                            Image(systemName: "clock")
                                .accessibilityHidden(true)
                            if let retryAt = continuation.retryAt {
                                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                    Text(AppCopy.format(
                                        "usage.resetsIn",
                                        Self.limitCountdown(until: retryAt, now: timeline.date)
                                    ))
                                    .monospacedDigit()
                                }
                            } else {
                                Text(AppCopy.text("usage.noLimitInfo"))
                            }
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(AppCopy.text("router.continueAfterLimit.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.red.opacity(0.8))
                    .frame(width: 3)
                    .padding(.vertical, 12)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private static func limitCountdown(until reset: Date, now: Date) -> String {
        let totalSeconds = max(0, Int(ceil(reset.timeIntervalSince(now))))
        if totalSeconds <= 10 * 60 {
            return "\(totalSeconds) s"
        }

        let totalMinutes = totalSeconds / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0
            ? "\(hours) h \(minutes) min"
            : "\(totalMinutes) min"
    }

    private var cacheResumeNotice: some View {
        let accountSwitched = bridge.accountSwitched(in: model.selectedConversationID)
        let cacheExpired = expiredCachePrefixTokens != nil
        let cacheLocal = cacheExpired && latestServedLocally
        let contextFull = contextNearlyFull
        // Surface only the strongest active warning, with context pressure first.
        return VStack(spacing: 0) {
            if contextFull {
                composerNotice(AppCopy.text("composer.contextFull.notice"))
            } else if cacheLocal {
                // A local model costs nothing; the loss is prefill time.
                composerNotice(AppCopy.text("composer.cacheLocal.notice"))
            } else if cacheExpired {
                composerNotice(AppCopy.text("composer.cacheExpired.notice")) {
                    Button {
                        showCacheResumeInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(AppCopy.text("composer.cacheExpired.infoTitle"))
                    .popover(isPresented: $showCacheResumeInfo, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(AppCopy.text("composer.cacheExpired.infoTitle"))
                                .font(.headline)
                            Text(AppCopy.text("composer.cacheExpired.explanation"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(width: 320, alignment: .leading)
                    }
                }
            } else if accountSwitched {
                composerNotice(AppCopy.text("composer.accountSwitched.notice"))
            }
        }
        .animation(.easeOut(duration: 0.16), value: [accountSwitched, cacheExpired, cacheLocal, contextFull])
    }

    private var latestServedLocally: Bool {
        bridge.contextUsageEvents()
            .filter { $0.conversationID == model.selectedConversationID && $0.requestKind == .main && $0.errorKind == nil }
            .max { $0.timestamp < $1.timestamp }?.cacheTrace?.local == true
    }

    private func composerNotice(
        _ text: String,
        @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
        .transition(.opacity)
    }

    private var latestMainUsage: AgentContextUsageEvent? {
        guard let conversationID = model.selectedConversationID else { return nil }
        return bridge.contextUsageEvents()
            .filter { $0.conversationID == conversationID && $0.requestKind == .main }
            .max { $0.timestamp < $1.timestamp }
    }

    /// Align with the 90% mark at which the context ring turns red.
    private var contextNearlyFull: Bool {
        guard let latest = latestMainUsage else { return false }
        if !router.isAutoSelected, model.selectedModelID != latest.model {
            // The last usage count came from a different model and tokenizer.
            // Wait for a usage event on the selected model before warning.
            return false
        }
        let window = router.isAutoSelected
            ? router.contextWindow(for: latest.model, provider: latest.provider)
            : router.contextWindow(for: model.selectedModelID)
        guard window > 0 else { return false }
        return Double(latest.contextTokens) / Double(window) > 0.9
    }

    private var expiredCachePrefixTokens: Int? {
        guard let conversationID = model.selectedConversationID else { return nil }
        let currentModel = router.isAutoSelected
            ? router.lastServedModelID
            : model.selectedModelID
        guard let currentModel else { return nil }

        let mainEvents = bridge.contextUsageEvents().filter {
            // A failed request carries no TTL or cache usage; it must not hide
            // the warning computed from the last request that actually ran.
            $0.conversationID == conversationID && $0.requestKind == .main && $0.model == currentModel
                && $0.errorKind == nil
        }
        guard let latest = mainEvents.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
        let previous = mainEvents.filter { $0.timestamp < latest.timestamp }
        if latest.cacheTrace?.local == true {
            return Self.localCachePrefixLost(latest, conversationID: conversationID, events: bridge.contextUsageEvents())
                ?? Self.droppedCachePrefixTokens(latest, previous: previous)
        }
        // Routes without a known retention (ChatGPT subscription): after an hour
        // the cache is gone on any OpenAI route, so that is the upper bound;
        // before it, warn from the measured miss on the last request.
        guard latest.cacheTrace?.ttlSeconds != nil else {
            let startedAt = latest.cacheTrace?.requestStartedAt ?? latest.timestamp
            if cacheNoticeClock.timeIntervalSince(startedAt) >= 3_600, latest.totalInputTokens >= 8_192 {
                return latest.totalInputTokens
            }
            return Self.droppedCachePrefixTokens(latest, previous: previous)
        }
        guard let trace = latest.cacheTrace,
              let ttl = trace.ttlSeconds,
              ttl > 0,
              cacheNoticeClock.timeIntervalSince(trace.requestStartedAt) >= Double(ttl)
        else { return nil }

        let evidence = latest.cacheReuseEvidence
        let hasProviderCacheEvidence = (latest.cachedTokens ?? 0) > 0
            || (latest.cacheWriteTokens ?? 0) > 0
            || (evidence?.classification == "eligible" && (evidence?.reusedTokens ?? 0) > 0)
        guard hasProviderCacheEvidence else { return nil }

        let tokenCount = max(
            evidence?.eligibleTokens ?? 0,
            (latest.cachedTokens ?? 0) + (latest.cacheWriteTokens ?? 0)
        )
        return tokenCount >= 8_192 ? tokenCount : nil
    }

    /// A large prefix that was cached earlier came back almost entirely uncached.
    /// Known prefix rewrites (compaction, settings) are expected misses, not breaks.
    static func droppedCachePrefixTokens(_ latest: AgentContextUsageEvent, previous: [AgentContextUsageEvent]) -> Int? {
        AgentCacheResumePolicy.droppedCachePrefixTokens(latest, previous: previous)
    }

    /// A local server keeps one prompt's KV cache (llama-server `--parallel 1`,
    /// dotsmlx): idle time says nothing, but any later request on the same
    /// server from another chat or a subagent has replaced it.
    static func localCachePrefixLost(_ latest: AgentContextUsageEvent, conversationID: String,
                                     events: [AgentContextUsageEvent]) -> Int? {
        AgentCacheResumePolicy.localCachePrefixLost(latest, conversationID: conversationID, events: events)
    }

    private var projectPopover: some View {
        ProjectPickerPopover(
            workspacePath: model.workspacePath,
            projects: model.projectPaths,
            projectTitle: { model.projectTitle(for: $0) },
            onSelect: { path in
                showProjectMenu = false
                model.selectProject(path)
            },
            onChoose: {
                showProjectMenu = false
                model.chooseWorkspace()
            },
            onClear: {
                showProjectMenu = false
                model.selectNoProject()
            }
        )
    }

    private var workLocationPopover: some View {
        WorkLocationPopover(
            selection: model.workLocation,
            hosts: model.sshHosts,
            sshAvailable: SSHRunner.isAvailable,
            remotePath: model.remoteWorkspace?.remotePath
        ) { setting in
            model.setWorkLocation(setting)
            showWorkLocationMenu = false
        } onManageHosts: {
            showWorkLocationMenu = false
            model.presentSettings(tab: "general")
        } onChooseFolder: {
            showWorkLocationMenu = false
            showRemoteFolderPicker = true
        }
    }

    private var branchPopover: some View {
        GitBranchPopover(
            snapshot: gitSnapshot,
            error: gitError,
            busy: gitBusy,
            onSelect: selectBranch,
            onSelectRemote: selectRemoteBranch,
            onCreate: createBranch,
            onFetch: fetchFromRemote,
            onPush: pushCurrentBranch
        )
    }

    /// Fallback row for chats without a visible git bar.
    private var composerContext: some View {
        HStack(spacing: 7) {
            Button { showProjectMenu.toggle() } label: {
                contextPill(icon: currentProjectIcon, title: currentProjectTitle)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showProjectMenu, arrowEdge: .bottom) { projectPopover }
            .help(AppCopy.text("composer.projectPickerHelp"))

            Button { showWorkLocationMenu.toggle() } label: {
                contextPill(icon: workLocationIcon, title: workLocationTitle)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showWorkLocationMenu, arrowEdge: .bottom) { workLocationPopover }
            .help(AppCopy.text("workLocation.help"))

            if gitSnapshot.isRepository {
                Button { showBranchMenu.toggle() } label: {
                    contextPill(icon: "arrow.triangle.branch", title: gitBranchName)
                }
                .buttonStyle(.plain)
                .disabled(bridge.isBusy)
                .popover(isPresented: $showBranchMenu, arrowEdge: .bottom) { branchPopover }
                .help(AppCopy.text("git.branchHelp"))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 7)
    }

    // MARK: - Queue + git bars

    private func barIcon(_ name: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func queueSummary(_ prompt: PendingPrompt) -> String {
        let text = prompt.notice ?? prompt.text
        return text.isEmpty ? "…" : text.replacingOccurrences(of: "\n", with: " ")
    }

    @ViewBuilder
    private var queueBar: some View {
        let conversation = model.selected
        let queued = (conversation?.pendingPrompts ?? []).filter { prompt in
            prompt.mode == .queue
                && !(conversation.map { bridge.isStartingPrompt(prompt.id, in: $0.id) } ?? false)
        }
        if let conversation, !queued.isEmpty {
            let conversationID = conversation.id
            // Editing pulls the text into the composer, so it is blocked until the box is empty.
            let draftBusy = !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !model.draftAttachments.isEmpty
            let multiple = queued.count > 1
            VStack(spacing: 0) {
                if multiple {
                    Button { withAnimation(.easeOut(duration: 0.15)) { queueExpanded.toggle() } } label: {
                        HStack(spacing: 10) {
                            Text(AppCopy.format("composer.queue.many", queued.count)).fontWeight(.medium)
                            if !queueExpanded {
                                Text(AppCopy.format("composer.queue.next", queueSummary(queued[0])))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: queueExpanded ? "chevron.up" : "chevron.down")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if !multiple || queueExpanded {
                    ForEach(queued) { prompt in
                        HStack(spacing: 10) {
                            if !multiple {
                                Text(AppCopy.text("composer.queue.one")).fontWeight(.medium)
                            }
                            Text(queueSummary(prompt))
                                .foregroundStyle(.secondary)
                                .lineLimit(multiple ? 3 : 1)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            barIcon("arrow.turn.down.left", help: AppCopy.text("conversation.steer")) {
                                bridge.steerPendingPrompt(prompt.id, in: conversationID)
                            }
                            barIcon(
                                "pencil",
                                help: AppCopy.text(draftBusy ? "composer.queue.editBlocked" : "composer.queue.edit"),
                                disabled: draftBusy
                            ) {
                                model.editQueuedPrompt(prompt.id)
                            }
                            barIcon("xmark", help: AppCopy.text("composer.queue.remove")) {
                                bridge.removeQueuedPrompt(prompt.id, in: conversationID)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, multiple ? 8 : 12)
                    }
                    .padding(.bottom, multiple ? 4 : 0)
                }
            }
            .font(.callout)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var gitBar: some View {
        if gitSnapshot.isRepository, !gitBarHidden {
            HStack(spacing: 8) {
                gitContextControls
                Spacer(minLength: 4)
                gitChangeCounts
                gitActions(compact: true)
                hideGitBarButton
            }
            .frame(maxWidth: .infinity)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
        }
    }

    private var gitContextControls: some View {
        Group {
            Button { showProjectMenu.toggle() } label: {
                contextPill(icon: currentProjectIcon, title: currentProjectTitle)
                    .frame(maxWidth: 220, alignment: .leading)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showProjectMenu, arrowEdge: .bottom) { projectPopover }
            .help(AppCopy.text("composer.projectPickerHelp"))
            Button { showBranchMenu.toggle() } label: {
                contextPill(icon: "arrow.triangle.branch", title: gitSnapshot.currentBranch ?? AppCopy.text("git.detached"))
                    .frame(maxWidth: 180, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(bridge.isBusy)
            .popover(isPresented: $showBranchMenu, arrowEdge: .bottom) { branchPopover }
            .help(AppCopy.text("git.branchHelp"))
            Button { showWorkLocationMenu.toggle() } label: {
                Image(systemName: workLocationIcon)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showWorkLocationMenu, arrowEdge: .bottom) { workLocationPopover }
            .help(AppCopy.text("workLocation.help"))
        }
    }

    @ViewBuilder
    private var gitChangeCounts: some View {
        if gitSnapshot.added + gitSnapshot.removed > 0 {
            HStack(spacing: 6) {
                Text("+\(gitSnapshot.added.formatted())").foregroundStyle(.green)
                Text("-\(gitSnapshot.removed.formatted())").foregroundStyle(.red)
            }
            .font(.system(.callout, design: .monospaced).weight(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func gitActions(compact: Bool) -> some View {
        HStack(spacing: 0) {
            Button { model.openPullRequests() } label: {
                Group {
                    if compact {
                        Image(systemName: "arrow.triangle.pull")
                    } else {
                        Text(AppCopy.text("git.createPR"))
                    }
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .help(AppCopy.text("git.createPR"))
            .accessibilityLabel(AppCopy.text("git.createPR"))
            Divider().frame(height: 16)
            Menu {
                Button(AppCopy.text("git.push"), action: pushCurrentBranch)
                Button(AppCopy.text("git.fetch"), action: fetchFromRemote)
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 8)
        }
        .foregroundStyle(.secondary)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .disabled(bridge.isBusy || gitBusy)
    }

    private var hideGitBarButton: some View {
        barIcon("xmark", help: AppCopy.text("git.hideBar")) { gitBarHidden = true }
    }

    private func contextPill(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.08), in: Capsule())
    }

    private var growingEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                PromptTextEditor(
                    text: $model.draft,
                    isEnabled: !bridge.historyMutationBusy,
                    onSubmit: { mode in
                        guard !bridge.historyMutationBusy,
                              model.canSend || model.isEditingMessage else { return }
                        model.send(mode: mode)
                    },
                    onAcceptSlashCommand: acceptSlashCommand,
                    onMoveSlashCommand: moveSlashCommand,
                    followUpSuggestion: visibleFollowUpSuggestion,
                    onDropFiles: { model.addDraftAttachments($0) },
                    onPasteImage: { model.addDraftImageData($0) }
                )
                    .frame(height: editorHeight)
                    .padding(.horizontal, 9)
                    .padding(.top, 5)
                    .focused($composerFocused)

                if model.draft.isEmpty, let visibleFollowUpSuggestion {
                    Text(visibleFollowUpSuggestion)
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.top, 13)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else if model.draft.isEmpty {
                    Text(AppCopy.text("composer.placeholder"))
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 13)
                        .allowsHitTesting(false)
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ComposerEditorWidthKey.self,
                        value: max(1, proxy.size.width - 28)
                    )
                }
            }

            VoiceTranscriptPreview(text: voiceInput.transcript)
        }
        .onPreferenceChange(ComposerEditorWidthKey.self) { width in
            guard width > 0 else { return }
            composerTextWidth = width
        }
    }

    private var draftAttachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.draftAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if attachment.kind == .image, let image = ImageFileCache.image(at: attachment.url) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            VStack(spacing: 4) {
                                Image(systemName: attachment.kind.systemImageName)
                                    .font(.title3)
                                Text(attachment.name)
                                    .font(.caption2)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                                .frame(width: 64, height: 64)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            model.removeDraftAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white, .black.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .padding(3)
                    }
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, 10)
        }
        .frame(height: 82)
    }

    private var editingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(AppCopy.text("conversation.editingMessage"))
                .font(.caption.weight(.medium))
            Spacer(minLength: 0)
            Button(AppCopy.text("conversation.cancelEdit")) {
                model.cancelEditing()
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.medium))
            .disabled(bridge.historyMutationBusy)
            .help(AppCopy.text("conversation.cancelEdit"))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 15)
        .padding(.top, 10)
    }

    private var fullAccessWarning: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 22, weight: .medium))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(AppCopy.text("permission.fullWarningTitle"))
                    .font(.headline)
                Text(AppCopy.text("permission.fullWarningBody"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(AppCopy.text("permission.fullWarningLearnMore"))
                    .font(.callout)
                    .underline()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button(AppCopy.text("permission.fullWarningDismiss")) {
                model.dismissFullAccessWarning()
            }
            .buttonStyle(BannerButtonStyle())

            Button {
                model.dismissFullAccessWarning()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(AppCopy.text("permission.fullWarningDismiss"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func skillSuggestionBanner(_ suggestion: SkillSuggestion) -> some View {
        ComposerBanner {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.cardTitle)
                    .font(.headline)
                Text(suggestion.cardDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(AppCopy.text("skill.suggestion.dismiss")) {
                model.dismissSkillSuggestion()
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)

            Button(AppCopy.text("skill.suggestion.create")) {
                _ = try? model.acceptSkillSuggestion(name: suggestion.draftName, description: suggestion.draftDescription)
            }
            .buttonStyle(BannerButtonStyle())
        }
        }
    }

    private var voiceIntroBanner: some View {
        ComposerBanner {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(AppCopy.text("voice.intro.title"))
                    .font(.headline)
                Text(AppCopy.text("voice.intro.body"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(AppCopy.text("voice.intro.start")) {
                model.dismissVoiceIntro()
                voiceInput.startListening()
            }
            .buttonStyle(BannerButtonStyle())

            Button {
                model.dismissVoiceIntro()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(AppCopy.text("voice.intro.dismiss"))
        }
        }
    }

    private func approvalBanner(_ approval: PendingApproval) -> some View {
        ComposerBanner {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "hand.raised")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppCopy.format("permission.approvalTitle", approval.toolName))
                    .font(.headline)
                Text(approval.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button(AppCopy.text("permission.reject")) {
                bridge.answerApproval("rejected")
            }
            .buttonStyle(.plain)

            Button(AppCopy.text("permission.allowOnce")) {
                bridge.answerApproval("allowed-once")
            }
            .buttonStyle(BannerButtonStyle())
        }
        }
    }

    /// Two chats of one project want the same file: the other one holds it, so this
    /// run waits and the user decides what happens next.
    private func conflictBanner(_ conflict: PendingConflict) -> some View {
        ComposerBanner {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppCopy.text("conflict.banner.title"))
                            .font(.headline)
                        Text(AppCopy.format(
                            "conflict.banner.body",
                            conflict.path,
                            conflict.holderTitle,
                            conflict.heldSeconds
                        ))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    conflictButton(AppCopy.text("conflict.banner.keepWaiting"), prominent: true) {
                        bridge.answerConflict(.keepWaiting)
                    }
                    conflictButton(AppCopy.format("conflict.banner.stopHolder", conflict.holderTitle), prominent: false) {
                        bridge.answerConflict(.stopHolder)
                    }
                    if conflict.otherRunningConversations > 1 {
                        conflictButton(AppCopy.text("conflict.banner.stopAllOthers"), prominent: false) {
                            bridge.answerConflict(.stopAllOthers)
                        }
                    }
                    Spacer(minLength: 8)
                    conflictButton(AppCopy.text("conflict.banner.skip"), prominent: false) {
                        bridge.answerConflict(.skip)
                    }
                }
            }
        }
    }

    /// The silent half of the "wait, then ask" policy: the run is parked behind
    /// another chat, and the user should see why nothing is happening.
    private func leaseWaitingBanner(_ holder: WorkspaceLeaseHolder) -> some View {
        ComposerBanner(verticalPadding: 10) {
            HStack(alignment: .center, spacing: 12) {
                HerNessLoadingAnimation(size: 20)
                Text(AppCopy.format("conflict.waiting", holder.conversationTitle, holder.label))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
            }
        }
    }

    private func conflictButton(
        _ title: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .font(.callout.weight(prominent ? .medium : .regular))
            .foregroundStyle(prominent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, prominent ? 14 : 6)
            .padding(.vertical, prominent ? 8 : 4)
            .background(prominent ? Color.primary.opacity(0.16) : .clear, in: Capsule())
            .buttonStyle(.plain)
    }

    private func visionInstallBanner(_ pending: PendingVisionInstall) -> some View {
        ComposerBanner {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "eye")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppCopy.text("vision.installTitle"))
                    .font(.headline)
                Text(AppCopy.format(
                    "vision.installReason",
                    pending.provider,
                    ByteCountFormatter.string(fromByteCount: pending.modelBytes, countStyle: .file)
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 12)

            Button(AppCopy.text("vision.notNow")) {
                bridge.answerVisionInstall(false)
            }
            .buttonStyle(.plain)

            Button(AppCopy.text("vision.downloadAndContinue")) {
                bridge.answerVisionInstall(true)
            }
            .buttonStyle(BannerButtonStyle())
        }
        }
    }

    private var contextEvents: [AgentContextUsageEvent] {
        bridge.contextUsageEvents().filter { $0.conversationID == model.selectedConversationID }
    }

    private func contextWindow(for event: AgentContextUsageEvent) -> Int? {
        let providerID = RouterCatalog.providers.first {
            $0.id.caseInsensitiveCompare(event.provider) == .orderedSame
                || $0.name.caseInsensitiveCompare(event.provider) == .orderedSame
        }?.id ?? event.provider
        if let override = model.router.modelContextWindowOverride(for: event.model, provider: providerID) {
            return override
        }
        // contextWindow() always supplies a generic fallback (32K, 128K, etc.).
        // That fallback can be smaller than the model that served the saved event,
        // so use only a resolved capacity here, then the event's request-time value.
        return model.router.detectedContextWindow(for: event.model, provider: providerID)
            ?? event.contextWindowTokens
    }

    private var composerControls: some View {
        GeometryReader { proxy in
            HStack(spacing: proxy.size.width < Self.compactComposerWidth ? 4 : 9) {
            ComposerAddButton(rows: [
                .init(icon: "paperclip", title: AppCopy.text("attachment.files"), shortcut: "⌘U", action: chooseFiles),
                .init(icon: "folder", title: AppCopy.text("attachment.project"), action: model.chooseWorkspace),
                .init(icon: "slash.circle", title: AppCopy.text("attachment.slashCommands"), action: openSkillsFromAttachmentMenu),
                .init(icon: "scope", title: AppCopy.text("attachment.goal"), action: promptForGoal),
                .init(icon: "point.3.connected.trianglepath.dotted", title: AppCopy.text("attachment.connectors"), opensElsewhere: true) {
                    model.presentSettings(tab: "mcp")
                },
                .init(icon: "puzzlepiece.extension", title: AppCopy.text("attachment.plugins"), opensElsewhere: true) {
                    model.presentSettings(tab: "plugins")
                }
            ], onShortcut: chooseFiles)

            ComposerVoiceButton(model: model, voiceInput: voiceInput)

                Button {
                    showPermissionMenu.toggle()
                } label: {
                    Group {
                        if proxy.size.width < Self.compactComposerWidth {
                            Image(systemName: model.permissionMode == .full ? "shield.fill" : "shield")
                                .font(.caption.weight(.semibold))
                                .frame(width: 28, height: 28)
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: model.permissionMode == .full ? "shield.fill" : "shield")
                                    .font(.caption.weight(.semibold))
                                Text(model.permissionMode.title)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                        }
                    }
                    .foregroundStyle(model.permissionMode == .full ? Color.orange : .secondary)
                    .background(
                        (model.permissionMode == .full ? Color.orange : Color.primary).opacity(0.12),
                        in: Capsule()
                    )
                }
            .buttonStyle(.plain)
            .accessibilityLabel(model.permissionMode.title)
            .popover(isPresented: $showPermissionMenu, arrowEdge: .top) {
                PermissionMenu(selection: Binding(
                    get: { model.permissionMode },
                    set: { value in
                        model.setPermissionMode(value)
                        showPermissionMenu = false
                    }
                ))
            }

            // ponytail: plan pill only exists while plan mode is active (entered via /plan).
            // Not a persistent toggle button; clicking it (or its hover ✕) exits plan mode.
            if model.isPlanMode {
                Divider()
                    .frame(height: 20)
                    .opacity(0.35)

                Button {
                    model.togglePlanMode()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: planPillHovered ? "xmark" : "lightbulb")
                            .font(.caption.weight(.semibold))
                        Text(AppCopy.text("plan.title"))
                            .font(.callout.weight(.medium))
                    }
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .onHover { planPillHovered = $0 }
                .help(AppCopy.text("plan.turnOffDetail"))
                .accessibilityLabel(AppCopy.text("plan.turnOffDetail"))
                .accessibilityValue(AppCopy.text("plan.on"))
                .accessibilityAddTraits(.isSelected)
            }

            Spacer(minLength: 0)

            Button {
                showModelMenu.toggle()
            } label: {
                ComposerModelLabel(name: modelName, effort: reasoningEffort)
            }
            .buttonStyle(.plain)
            .layoutPriority(-1)
            .help([modelName, reasoningEffort].filter { !$0.isEmpty }.joined(separator: " "))
            .popover(isPresented: $showModelMenu, arrowEdge: .top) {
                ModelPickerPopover(model: model)
            }

            ContextRingButton(
                isPresented: $showContextUsage,
                events: contextEvents,
                contextWindowForEvent: contextWindow(for:)
            )

            if bridge.isBusy {
                HStack(spacing: 5) {
                    ComposerRoundButton(icon: "stop.fill", label: AppCopy.text("common.stop"), action: model.stop)

                    cancelPlanButton
                }
            } else if bridge.canContinue {
                HStack(spacing: 5) {
                    ComposerRoundButton(icon: "play.fill", label: AppCopy.text("agent.continue")) {
                        if canSubmit { model.send(mode: .queue) } else { model.continueCurrentRun() }
                    }
                    .disabled(!model.canSend)
                    .opacity(model.canSend ? 1 : 0.7)

                    cancelPlanButton
                }
            } else {
                ComposerRoundButton(
                    icon: sendIcon, size: 14, label: AppCopy.text("bots.send"),
                    help: AppCopy.text("composer.keyboardHelp")
                ) { model.send(mode: .queue) }
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.7)
            }
            }
            .padding(.horizontal, proxy.size.width < Self.compactComposerWidth ? 8 : 12)
            .padding(.bottom, 10)
            .padding(.top, 6)
        }
        .frame(height: 46)
    }

    @ViewBuilder
    private var cancelPlanButton: some View {
        if model.selected?.planGateActive == true {
            Button {
                model.cancelPlan()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppCopy.text("conversation.cancelPlanHelp"))
            .help(AppCopy.text("conversation.cancelPlanHelp"))
        }
    }

    private var currentProjectTitle: String {
        let path = model.workspacePath
        guard !path.isEmpty else { return AppCopy.text("composer.noProject") }
        return model.projectTitle(for: path)
    }

    private var currentProjectIcon: String {
        model.workspacePath.isEmpty ? "bubble.left.and.bubble.right" : "folder"
    }

    private var gitBranchName: String {
        let base = gitSnapshot.currentBranch ?? AppCopy.text("git.detached")
        var suffix = ""
        if gitSnapshot.ahead > 0 { suffix += " ↑\(gitSnapshot.ahead)" }
        if gitSnapshot.behind > 0 { suffix += " ↓\(gitSnapshot.behind)" }
        return base + suffix
    }

    private var modelName: String {
        // Auto chooses a model per message; keep the mode label stable instead
        // of making the last route look like a pinned selection.
        if router.isAutoSelected {
            return AppCopy.text("modelPicker.auto")
        }
        // The router only ever holds a model a catalog knows, so the pill cannot
        // drift away from the picker that sits behind it.
        return router.modelLabel(forID: model.selectedModelID)
    }

    private var editorHeight: CGFloat {
        composerEditorHeight(for: model.draft, width: composerTextWidth)
    }

    private var canSubmit: Bool {
        let hasDraft = !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.draftAttachments.isEmpty
        return hasDraft && !bridge.historyMutationBusy && (model.canSend || model.isEditingMessage)
    }

    private var sendIcon: String {
        return model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "waveform" : "arrow.up"
    }

    private var slashMenuIsVisible: Bool {
        slashToken != nil
    }

    private var visibleSlashCommands: [SlashCommand] {
        slashSettings + slashMedia + slashTemplates + slashSkills
    }

    private var slashToken: String? {
        let lastLine = model.draft.components(separatedBy: .newlines).last ?? ""
        guard let lastCharacter = lastLine.last, !lastCharacter.isWhitespace else { return nil }
        guard let token = lastLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).last,
              token.first == "/" else {
            return nil
        }
        return String(token)
    }

    private var slashQuery: String {
        guard let slashToken else { return "" }
        return String(slashToken.dropFirst())
    }

    private var slashSettings: [SlashCommand] {
        var commands = [
            SlashCommand(id: "reasoning", title: AppCopy.text("slash.reasoning"), detail: reasoningEffort, icon: "brain.head.profile", kind: .setting),
            SlashCommand(id: "status", title: AppCopy.text("slash.status"), detail: AppCopy.text("slash.statusDetail"), icon: "gauge", kind: .setting),
            SlashCommand(id: "feedback", title: AppCopy.text("slash.feedback"), detail: AppCopy.text("slash.feedbackDetail"), icon: "bubble.left.and.exclamationmark.bubble.right", kind: .setting),
            SlashCommand(id: "goal", title: AppCopy.text("slash.goal"), detail: AppCopy.text("slash.goalDetail"), icon: "scope", kind: .setting),
            SlashCommand(id: "loop", title: AppCopy.text("slash.loop"), detail: AppCopy.text("slash.loopDetail"), icon: "repeat", kind: .setting),
            SlashCommand(id: "speed", title: AppCopy.text("slash.speed"), detail: AppCopy.text("slash.speedDetail"), icon: "bolt", kind: .setting),
            SlashCommand(id: "billing", title: AppCopy.text("slash.billing"), detail: AppCopy.text("slash.billingDetail"), icon: "chart.bar", kind: .setting),
            SlashCommand(id: "mcp", title: AppCopy.text("slash.mcp"), detail: AppCopy.text("slash.mcpDetail"), icon: "point.3.connected.trianglepath.dotted", kind: .setting),
            SlashCommand(id: "prompt-templates-folder", title: AppCopy.text("slash.promptTemplates"), detail: "/prompt-templates-folder · \(AppCopy.text("slash.promptTemplatesDetail"))", icon: "text.book.closed", kind: .setting),
            SlashCommand(id: "model", title: AppCopy.text("slash.model"), detail: modelName, icon: "cube", kind: .setting),
            SlashCommand(
                id: "plan",
                title: AppCopy.text("slash.plan"),
                detail: model.isPlanMode ? AppCopy.text("plan.turnOffDetail") : AppCopy.text("slash.planDetail"),
                icon: "lightbulb",
                kind: .setting
            ),
            SlashCommand(id: "mascot", title: AppCopy.text("slash.mascot"), detail: AppCopy.text("slash.mascotDetail"), icon: "smiley", kind: .setting),
            SlashCommand(id: "plugincreator", title: AppCopy.text("slash.pluginCreator"), detail: AppCopy.text("slash.pluginCreatorDetail"), icon: "puzzlepiece.extension", kind: .setting),
        ]
        if model.canCompactSelectedConversation {
            commands.append(SlashCommand(id: "compact", title: AppCopy.text("slash.compact"), detail: AppCopy.text("slash.compactDetail"), icon: "arrow.down.right.and.arrow.up.left", kind: .setting))
        }
        commands.insert(
            SlashCommand(id: "project", title: AppCopy.text("slash.project"), detail: AppCopy.text("slash.projectDetail"), icon: "folder", kind: .setting),
            at: 1
        )
        return filterCommands(commands)
    }

    private var slashSkills: [SlashCommand] {
        let installed = model.skills.entries
            .filter(\.enabled)
            .map {
                SlashCommand(
                    id: "skill-\($0.id)",
                    title: $0.name,
                    detail: $0.description.isEmpty ? AppCopy.text("composer.installedSkill") : $0.description,
                    icon: "cube.transparent",
                    kind: .skill,
                    command: $0.id
                )
            }

        let fallback = [
            SlashCommand(id: "skill-documents", title: AppCopy.text("library.kind.document"), detail: AppCopy.text("skill.documentsDetail"), icon: "doc.text", kind: .skill),
            SlashCommand(id: "skill-pdf", title: "PDF", detail: AppCopy.text("skill.pdfDetail"), icon: "doc.richtext", kind: .skill),
            SlashCommand(id: "skill-spreadsheets", title: AppCopy.text("skill.spreadsheets"), detail: AppCopy.text("skill.spreadsheetsDetail"), icon: "tablecells", kind: .skill),
            SlashCommand(id: "skill-browser", title: AppCopy.text("conversation.browser"), detail: AppCopy.text("skill.browserDetail"), icon: "globe", kind: .skill),
            SlashCommand(id: "skill-imagegen", title: AppCopy.text("slash.imagegen"), detail
: AppCopy.text("skill.imageGenDetail"), icon: "photo", kind: .skill),
        ]

        var seen = Set<String>()
        return filterCommands((installed + fallback).filter { seen.insert($0.title.lowercased()).inserted })
    }

    private var slashMedia: [SlashCommand] {
        var commands = [
            SlashCommand(
                id: "imagegen",
                title: AppCopy.text("slash.imagegen"),
                detail: AppCopy.text("slash.imagegenDetail"),
                icon: "photo",
                kind: .media,
                command: "imagegen"
            ),
            SlashCommand(
                id: "videogen",
                title: AppCopy.text("slash.videogen"),
                detail: AppCopy.text("slash.videogenDetail"),
                icon: "video",
                kind: .media,
                command: "videogen"
            ),
            SlashCommand(
                id: "audiogen",
                title: AppCopy.text("slash.audiogen"),
                detail: AppCopy.text("slash.audiogenDetail"),
                icon: "waveform",
                kind: .media,
                command: "audiogen"
            ),
        ]
        if !router.imageGenerationCommandVisible {
            commands.removeAll { $0.id == "imagegen" }
        }
        return filterCommands(commands)
    }

    private var slashTemplates: [SlashCommand] {
        filterCommands(promptTemplates.templates.map { template in
            let info = [template.argumentHint, template.description]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            let invocation = "/template-\(template.id)"
            return SlashCommand(
                id: "template-\(template.id)",
                title: template.title,
                detail: info.isEmpty ? invocation : "\(invocation) · \(info)",
                icon: "text.quote",
                kind: .template,
                command: template.id
            )
        })
    }

    private func filterCommands(_ commands: [SlashCommand]) -> [SlashCommand] {
        guard !slashQuery.isEmpty else { return commands }
        return commands.filter {
            $0.title.localizedCaseInsensitiveContains(slashQuery)
                || $0.detail.localizedCaseInsensitiveContains(slashQuery)
                || ($0.command?.localizedCaseInsensitiveContains(slashQuery) == true)
        }
    }

    private func selectSlashCommand(_ command: SlashCommand) {
        let replacement: String
        switch command.kind {
        case .setting: replacement = ""
        case .skill:
            let skillID = command.command ?? String(command.id.dropFirst("skill-".count))
            replacement = "/\(skillID) "
        case .media: replacement = "/\(command.command ?? command.id) "
        case .template: replacement = "/template-\(command.command ?? command.id) "
        }
        replaceSlashToken(with: replacement)
        composerFocused = true

        switch command.id {
        case "feedback":
            model.requestFeedbackForLatestResponse()
        case "model":
            showModelMenu = true
        case "goal":
            promptForGoal()
        case "loop":
            promptForLoop()
        case "project":
            showProjectMenu = true
        case "reasoning":
            showModelMenu = true
        case "speed":
            if router.supportsFast(model.selectedModelID) { model.setFast(!router.fastMode) }
        case "plan":
            model.togglePlanMode()
        case "compact":
            // Sent with the draft: it compacts first, then answers the rest.
            model.draft = "/compact " + model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        case "plugincreator":
            let trimmed = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            model.draft = trimmed.isEmpty
                ? AppCopy.text("pluginCreator.template")
                : AppCopy.format("pluginCreator.templateWith", trimmed)
            composerFocused = true
        case "mcp":
            model.presentSettings(tab: "mcp")
        case "prompt-templates-folder":
            do {
                let directory = try promptTemplates.directoryToOpen(workspacePath: bridge.workspacePath)
                NSWorkspace.shared.open(directory)
            } catch {
                model.reportHistoryError(error.localizedDescription)
            }
        default:
            if command.kind == .setting {
                model.presentSettings()
            }
        }
    }

    private func acceptSlashCommand() -> Bool {
        guard slashMenuIsVisible,
              let command = visibleSlashCommands.first(where: { $0.id == highlightedSlashCommandID })
                ?? visibleSlashCommands.first else { return false }
        selectSlashCommand(command)
        return true
    }

    private func moveSlashCommand(_ offset: Int) -> Bool {
        guard slashMenuIsVisible else { return false }
        let commands = visibleSlashCommands
        guard !commands.isEmpty else { return false }

        let currentIndex = commands.firstIndex(where: { $0.id == highlightedSlashCommandID })
            ?? (offset > 0 ? -1 : 0)
        highlightedSlashCommandID = commands[(currentIndex + offset + commands.count) % commands.count].id
        return true
    }

    private func replaceSlashToken(with replacement: String) {
        guard let slashToken,
              let range = model.draft.range(of: slashToken, options: .backwards) else { return }
        model.draft.replaceSubrange(range, with: replacement)
    }

    private func promptForGoal() {
        let alert = NSAlert()
        alert.messageText = AppCopy.text("goal.dialogTitle")
        alert.informativeText = AppCopy.text("goal.dialogBody")
        alert.addButton(withTitle: AppCopy.text("common.save"))
        alert.addButton(withTitle: AppCopy.text("common.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = model.sessionGoal
        field.placeholderString = AppCopy.text("slash.goalDetail")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            model.setSessionGoal(field.stringValue)
        }
    }

    private func promptForLoop() {
        let alert = NSAlert()
        alert.messageText = AppCopy.text("loop.dialogTitle")
        alert.informativeText = AppCopy.text("loop.dialogBody")
        alert.addButton(withTitle: AppCopy.text("common.save"))
        alert.addButton(withTitle: AppCopy.text("common.cancel"))

        let minutes = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        minutes.stringValue = "30"
        let instruction = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        instruction.stringValue = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        instruction.placeholderString = AppCopy.text("loop.instructionLabel")

        let stack = NSStackView(views: [
            labeledField(AppCopy.text("loop.minutesLabel"), minutes),
            labeledField(AppCopy.text("loop.instructionLabel"), instruction),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 96)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = instruction.stringValue.isEmpty ? instruction : minutes

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let mins = max(1, Int(minutes.stringValue.trimmingCharacters(in: .whitespaces)) ?? 30)
        let text = instruction.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.createLoopTask(everyMinutes: mins, instruction: text)
        model.draft = ""
        model.presentTasks()
    }

    private func labeledField(_ title: String, _ field: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, field])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        return row
    }

    private func openSkillsFromAttachmentMenu() {
        model.draft = "/"
        composerFocused = true
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.item]
        panel.prompt = AppCopy.text("composer.add")
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                model.addDraftAttachments(panel.urls)
            }
        }
    }

    /// Reads the repository off the main thread: it spawns several `git` processes, and
    /// this runs when the composer first appears. A newer refresh supersedes an older one.
    private func refreshGit(clearError: Bool = true) {
        let path = model.workspacePath
        gitRefreshToken &+= 1
        let token = gitRefreshToken
        if clearError { gitError = nil }
        Task {
            let snapshot = await Task.detached(priority: .utility) { GitRepository.snapshot(at: path) }.value
            guard token == gitRefreshToken else { return }
            gitSnapshot = snapshot
        }
    }

    private func selectBranch(_ branch: String) {
        guard !gitBusy else { return }
        guard branch != gitSnapshot.currentBranch else {
            showBranchMenu = false
            return
        }
        guard let error = GitRepository.checkout(branch, at: model.workspacePath) else {
            showBranchMenu = false
            refreshGit()
            return
        }
        gitError = error
    }

    /// Check out a remote-tracking ref (`origin/foo`). Git's DWIM creates the
    /// local `foo` with upstream set when it does not exist yet.
    private func selectRemoteBranch(_ remote: String) {
        guard !gitBusy else { return }
        let local = remote.split(separator: "/").dropFirst().joined(separator: "/")
        guard !local.isEmpty else { return }
        guard let error = GitRepository.checkout(local, at: model.workspacePath) else {
            showBranchMenu = false
            refreshGit()
            return
        }
        gitError = error
    }

    private func fetchFromRemote() {
        runGitNetwork(.fetch)
    }

    private func pushCurrentBranch() {
        guard let branch = gitSnapshot.currentBranch else {
            gitError = AppCopy.text("git.detached")
            return
        }
        runGitNetwork(.push(branch))
    }

    /// Run a blocking git network command off the main thread, then refresh.
    private func runGitNetwork(_ op: GitNetworkOp) {
        guard !gitBusy, !model.workspacePath.isEmpty else { return }
        gitBusy = true
        gitError = nil
        let path = model.workspacePath
        Task {
            let error = await Task.detached { () -> String? in
                switch op {
                case .fetch: return GitRepository.fetch(at: path)
                case .push(let branch): return GitRepository.push(branch, at: path)
                }
            }.value
            await MainActor.run {
                gitBusy = false
                refreshGit(clearError: false)
                gitError = error
            }
        }
    }

    private func createBranch() {
        let alert = NSAlert()
        alert.messageText = AppCopy.text("git.createBranchTitle")
        alert.informativeText = AppCopy.text("git.createBranchMessage")
        alert.addButton(withTitle: AppCopy.text("common.save"))
        alert.addButton(withTitle: AppCopy.text("common.cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = AppCopy.text("git.branchName")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let error = GitRepository.createBranch(
            field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            at: model.workspacePath
        ) else {
            showBranchMenu = false
            refreshGit()
            return
        }
        gitError = error
    }
}
