// Copyright (c) 2026 DOTS
// Menu bar panel: live chats and provider limits, with the full conversation
// surface (composer, model picker) one click away, without opening the window.

import SwiftUI
import DotsHarnessCore

public struct TrayPanelView: View {
    @ObservedObject var model: AppModel
    private let onOpenWindow: () -> Void
    private let onQuit: () -> Void
    @State private var showingChat = false
    @State private var showingUsage = false
    @State private var expandedGroups = Set<String>()

    private static let groupLimit = 5

    public init(model: AppModel, onOpenWindow: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.model = model
        self.onOpenWindow = onOpenWindow
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            // The legal gate lives in the window; nothing is usable before it.
            if showingChat, !model.legalNeedsAcceptance {
                chatHeader
                Divider()
                // ponytail: shares the window's selection, so the window follows the
                // panel. Give the panel its own selection if the two must diverge.
                ConversationView(model: model, isPanePickerVisible: .constant(false))
            } else {
                listHeader
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        if !model.legalNeedsAcceptance { chatList }
                    }
                    .padding(8)
                }
                Divider()
                footer
            }
        }
        .frame(width: 420, height: 620)
        .preferredColorScheme(model.appearance.colorScheme)
        .environment(\.locale, model.appLocale)
        .environment(\.layoutDirection, model.isRTL ? .rightToLeft : .leftToRight)
    }

    // MARK: - Chrome

    private var listHeader: some View {
        HStack {
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Dots Harness")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                model.newConversation()
                showingChat = true
            } label: {
                Label(AppCopy.text("sidebar.newChat"), systemImage: "square.and.pencil")
            }
            .controlSize(.small)
            .disabled(model.legalNeedsAcceptance)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var chatHeader: some View {
        let status = model.selected.map(status(for:))
        return HStack(spacing: 8) {
            Button { showingChat = false } label: {
                Label(AppCopy.text("tray.back"), systemImage: "chevron.backward")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            VStack(spacing: 1) {
                Text(model.selected?.title ?? AppCopy.text("sidebar.newChat"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let status, !status.text.isEmpty {
                    Text(status.text)
                        .font(.system(size: 11))
                        .foregroundStyle(status.tint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)

            Button(action: onOpenWindow) { Image(systemName: "macwindow") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(AppCopy.text("tray.show"))
                .accessibilityLabel(AppCopy.text("tray.show"))
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button(AppCopy.text("tray.show"), systemImage: "macwindow", action: onOpenWindow)
            Button(AppCopy.text("sidebar.usage"), systemImage: "chart.bar.xaxis") { showingUsage.toggle() }
                .popover(isPresented: $showingUsage, arrowEdge: .top) {
                    AccountLimitsSection(router: model.router)
                        .padding(.bottom, 4)
                        .frame(width: 320)
                }
            Spacer()
            Button(AppCopy.text("app.quit"), systemImage: "power", action: onQuit)
                .labelStyle(.iconOnly)
                .help(AppCopy.text("app.quit"))
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    // MARK: - Chats

    private struct ChatGroup: Identifiable {
        let id: String
        let title: String
        let rows: [Conversation]
    }

    @ViewBuilder
    private var chatList: some View {
        let groups = chatGroups
        if groups.isEmpty {
            Text(AppCopy.text("tray.noChats"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }
        ForEach(groups) { group in
            let showAll = expandedGroups.contains(group.id)
            HStack(spacing: 4) {
                if !group.id.isEmpty, model.isProjectPinned(group.id) {
                    Image(systemName: "pin.fill").font(.system(size: 8))
                }
                Text(group.title).lineLimit(1)
                Spacer(minLength: 4)
                if !group.id.isEmpty { projectMenu(group.id) }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
            ForEach(showAll ? group.rows : Array(group.rows.prefix(Self.groupLimit))) { conversation in
                let running = model.bridge.runningConversationIDs.contains(conversation.id)
                TrayChatRow(
                    title: conversation.title,
                    status: status(for: conversation),
                    running: running,
                    control: running
                        ? ("stop.fill", AppCopy.text("common.stop"))
                        : conversation.canContinue ? ("play.fill", AppCopy.text("agent.continue")) : nil,
                    open: {
                        focus(conversation)
                        showingChat = true
                    },
                    runControl: {
                        focus(conversation)
                        if running { model.stop() } else { model.continueCurrentRun() }
                    }
                )
            }
            if group.rows.count > Self.groupLimit {
                Button(AppCopy.text(showAll ? "sidebar.showLess" : "sidebar.showMore")) {
                    if showAll { expandedGroups.remove(group.id) } else { expandedGroups.insert(group.id) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
            }
        }
    }

    /// Pinning and chat order are the project's own settings, so a change here
    /// is the same change in the sidebar.
    private func projectMenu(_ path: String) -> some View {
        Menu {
            Button(AppCopy.text(model.isProjectPinned(path) ? "sidebar.unpinProject" : "sidebar.pinProject")) {
                model.toggleProjectPinned(path)
            }
            Divider()
            ForEach(
                [
                    (ConversationSortOrder.lastUpdate, "sidebar.sortLastUpdate"),
                    (.priority, "sidebar.sortPriority"),
                    (.manual, "sidebar.sortManual"),
                ],
                id: \.1
            ) { order, key in
                Button {
                    model.setSortOrder(order, forProject: path)
                } label: {
                    if model.sortOrder(forProject: path) == order {
                        Label(AppCopy.text(key), systemImage: "checkmark")
                    } else {
                        Text(AppCopy.text(key))
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 20, height: 14)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(AppCopy.text("sidebar.sortCriteria"))
    }

    /// The sidebar's picture: pinned projects first, each project's chats in its
    /// own sort order, then chats that belong to no connected project.
    private var chatGroups: [ChatGroup] {
        let paths = model.projectPaths.filter(model.isProjectPinned) + model.projectPaths.filter { !model.isProjectPinned($0) }
        var groups = paths.map { path in
            // The active project reads the loaded list so run state stays live.
            let chats = path == model.workspacePath ? model.conversations : model.bridge.conversations(inProject: path)
            return ChatGroup(id: path, title: model.projectTitle(for: path), rows: model.ordered(visible(chats), forProject: path))
        }
        groups.append(
            ChatGroup(
                id: "",
                title: AppCopy.text("sidebar.recent"),
                rows: model.ordered(
                    visible(model.bridge.conversations(outsideProjects: model.connectedProjectPaths)), forProject: nil
                )
            )
        )
        return groups.filter { !$0.rows.isEmpty }
    }

    private func visible(_ conversations: [Conversation]) -> [Conversation] {
        conversations.filter { !$0.archived && !$0.blank }
    }

    private func status(for conversation: Conversation) -> TrayChatStatus {
        if let approval = model.bridge.pendingApproval, approval.conversationID == conversation.id {
            return TrayChatStatus(text: AppCopy.text("plan.waitingApproval"), tint: .orange)
        }
        if model.bridge.runningConversationIDs.contains(conversation.id) {
            return TrayChatStatus(text: AppCopy.text("router.running"), tint: .green)
        }
        if let continuation = conversation.continuation {
            if continuation.reason == .toolStepLimit {
                return TrayChatStatus(text: AppCopy.text("agent.toolStepLimit"), tint: .orange)
            }
            return continuation.reason == .providerLimit
                ? TrayChatStatus(text: AppCopy.text("agent.providerLimitTitle"), tint: .red)
                : TrayChatStatus(text: AppCopy.text("agent.userStoppedTitle"), tint: .orange)
        }
        if conversation.pendingPlanMessageID != nil {
            return TrayChatStatus(text: AppCopy.text("queue.waitingForPlan"), tint: .orange)
        }
        if conversation.unread {
            return TrayChatStatus(text: AppCopy.text("tray.unread"), tint: .blue)
        }
        return TrayChatStatus(text: "", tint: .secondary)
    }

    /// Mirrors the sidebar row: switch the owning project first, then select.
    private func focus(_ conversation: Conversation) {
        let owner = conversation.cwd ?? ""
        if !owner.isEmpty, !conversation.projectless, model.isProjectLocationAvailable(owner) {
            if owner != model.workspacePath { model.selectProject(owner) }
            model.selectedConversationID = conversation.id
        } else {
            model.openRecentConversation(conversation)
        }
    }
}

private struct TrayChatStatus {
    let text: String
    let tint: Color
}

private struct TrayChatRow: View {
    let title: String
    let status: TrayChatStatus
    let running: Bool
    /// One intervention per chat: whatever the run needs right now.
    let control: (symbol: String, label: String)?
    let open: () -> Void
    let runControl: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 8) {
                    Group {
                        if running {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle().fill(status.tint).frame(width: 6, height: 6)
                                .opacity(status.text.isEmpty ? 0.35 : 1)
                        }
                    }
                    .frame(width: 14)

                    Text(title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(status.text)
                        .font(.system(size: 11))
                        .foregroundStyle(status.tint)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let control {
                Button(action: runControl) {
                    Image(systemName: control.symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help(control.label)
                .accessibilityLabel(control.label)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            isHovered ? Color.primary.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .onHover { isHovered = $0 }
    }
}
