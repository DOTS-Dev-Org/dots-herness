// Copyright (c) 2026 DOTS
// Conversation archive and memory transfer settings panes.

import AppKit
import UniformTypeIdentifiers
import SwiftUI
import HarnessPluginKit
import DotsHarnessCore
import PluginRuntime

private struct ConversationArchiveProject: Identifiable {
    let id: String
    let title: String
    let path: String?
    let conversations: [Conversation]
}

private enum ArchiveConversationFilter: String, CaseIterable, Identifiable {
    case all
    case unread
    case pinned

    var id: String { rawValue }
    var titleKey: String { "archive.filter.\(rawValue)" }

    var symbol: String {
        switch self {
        case .all: "bubble.left.and.bubble.right"
        case .unread: "circle.fill"
        case .pinned: "pin.fill"
        }
    }
}

struct ConversationArchiveView: View {
    @ObservedObject var model: AppModel
    @State private var pendingDeletion: PendingDeletion?
    @State private var selectedTranscript: Conversation?
    @State private var isLoadingOlderArchiveMessages = false
    @State private var olderArchivePageAnchorID: String?
    @State private var collapsedProjectIDs: Set<String> = []
    @State private var isDeletingConversations = false
    @State private var searchText = ""
    @State private var conversationFilter: ArchiveConversationFilter = .all
    @State private var selectedProjectID = "all"
    @AppStorage(ConversationArchiveRetention.preferenceKey) private var retentionDays = 0

    private enum PendingDeletion: Equatable {
        case conversation(String)
        case all
    }

    private var archivedConversations: [Conversation] {
        model.bridge.archivedConversations.sorted {
            $0.activityDate > $1.activityDate
        }
    }

    private var archivedProjects: [ConversationArchiveProject] {
        Dictionary(grouping: archivedConversations) {
            ConversationStore.normalizedPath($0.cwd) ?? ""
        }
        .map { pathKey, conversations in
            let path = pathKey.isEmpty ? nil : pathKey
            let sourcePath = conversations.first(where: { ConversationStore.normalizedPath($0.cwd) != nil })?.cwd
            return ConversationArchiveProject(
                id: path.map { "project:\($0)" } ?? "no-project",
                title: sourcePath.map { model.projectTitle(for: $0) } ?? AppCopy.text("archive.noProject"),
                path: path,
                conversations: conversations.sorted { $0.activityDate > $1.activityDate }
            )
        }
        .sorted {
            ($0.conversations.first?.activityDate ?? .distantPast)
                > ($1.conversations.first?.activityDate ?? .distantPast)
        }
    }

    private var visibleProjects: [ConversationArchiveProject] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return archivedProjects.compactMap { project in
            guard selectedProjectID == "all" || project.id == selectedProjectID else { return nil }
            let projectMatches = !query.isEmpty && (
                project.title.localizedCaseInsensitiveContains(query)
                    || (project.path?.localizedCaseInsensitiveContains(query) ?? false)
            )
            let matches = project.conversations.filter { conversation in
                let matchesFilter: Bool
                switch conversationFilter {
                case .all: matchesFilter = true
                case .unread: matchesFilter = conversation.unread
                case .pinned: matchesFilter = conversation.pinned
                }
                guard matchesFilter else { return false }
                guard !query.isEmpty, !projectMatches else { return true }
                if conversation.title.localizedCaseInsensitiveContains(query)
                    || (conversation.cwd?.localizedCaseInsensitiveContains(query) ?? false) {
                    return true
                }
                return model.bridge.contentMatches(conversation, query: query)
            }
            guard !matches.isEmpty else { return nil }
            return ConversationArchiveProject(
                id: project.id,
                title: project.title,
                path: project.path,
                conversations: matches
            )
        }
    }

    var body: some View {
        let deletionAtPresentation = pendingDeletion

        Group {
            if let selectedTranscript {
                transcriptView(selectedTranscript, bridge: model.bridge)
                    .padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        archiveHeader
                        filterControls
                        retentionControl

                        if archivedConversations.isEmpty {
                            emptyState("archive.empty", symbol: "archivebox")
                        } else if visibleProjects.isEmpty {
                            emptyState("archive.noResults", symbol: "magnifyingglass")
                        } else {
                            LazyVStack(spacing: 14) {
                                ForEach(visibleProjects) { project in
                                    archivedProjectCard(project)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 1180, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                }
                .disabled(isDeletingConversations)
            }
        }
        .navigationTitle(AppCopy.text("archive.title"))
        .onChange(of: retentionDays) { _, days in
            Task { @MainActor in
                await model.bridge.deleteExpiredArchivedConversationsInBackground(retentionDays: days)
            }
        }
        .onChange(of: archivedProjects.map(\.id)) { _, projectIDs in
            if selectedProjectID != "all", !projectIDs.contains(selectedProjectID) {
                selectedProjectID = "all"
            }
        }
        .task {
            await model.bridge.deleteExpiredArchivedConversationsInBackground(retentionDays: retentionDays)
        }
        .confirmationDialog(
            AppCopy.text(deletionAtPresentation == .all ? "archive.confirmDeleteAll" : "archive.confirmDelete"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(
                AppCopy.text(deletionAtPresentation == .all ? "archive.deleteAll" : "archive.deletePermanently"),
                role: .destructive
            ) {
                switch deletionAtPresentation {
                case .all:
                    let ids = archivedConversations.map(\.id)
                    deleteArchivedConversations(ids)
                case .conversation(let id):
                    deleteArchivedConversations([id])
                case nil:
                    break
                }
            }
            .keyboardShortcut(.defaultAction)
            Button(AppCopy.text("common.cancel"), role: .cancel) {
                pendingDeletion = nil
            }
        }
    }

    private var archiveHeader: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppCopy.text("archive.title"))
                    .font(.largeTitle.weight(.semibold))
                Text(AppCopy.format("archive.conversationCount", archivedConversations.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isDeletingConversations {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(AppCopy.text("archive.deleteAll"))
            }

            Button(role: .destructive) {
                pendingDeletion = .all
            } label: {
                Label(AppCopy.text("archive.deleteAll"), systemImage: "trash")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(archivedConversations.isEmpty || isDeletingConversations)
        }
    }

    private func deleteArchivedConversations(_ ids: [String]) {
        guard !ids.isEmpty, !isDeletingConversations else {
            pendingDeletion = nil
            return
        }
        if let selectedTranscript, ids.contains(selectedTranscript.id) {
            self.selectedTranscript = nil
        }
        isDeletingConversations = true
        pendingDeletion = nil
        Task { @MainActor in
            await Task.yield()
            await model.bridge.deleteConversationsInBackground(ids)
            isDeletingConversations = false
        }
    }

    private var filterControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                searchField
                filterMenu
                projectMenu
            }
            VStack(alignment: .leading, spacing: 10) {
                searchField
                HStack(spacing: 10) {
                    filterMenu
                    projectMenu
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(AppCopy.text("archive.searchPlaceholder"), text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel(AppCopy.text("archive.searchPlaceholder"))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppCopy.text("archive.clearSearch"))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Color.secondary.opacity(0.11), in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.2), lineWidth: 1))
        .frame(minWidth: 220, maxWidth: .infinity)
    }

    private var filterMenu: some View {
        Menu {
            Picker(AppCopy.text("archive.filter.title"), selection: $conversationFilter) {
                ForEach(ArchiveConversationFilter.allCases) { filter in
                    Label(AppCopy.text(filter.titleKey), systemImage: filter.symbol)
                        .tag(filter)
                }
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(AppCopy.text(conversationFilter.titleKey))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 46)
            .padding(.horizontal, 14)
            .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var projectMenu: some View {
        Menu {
            Picker(AppCopy.text("archive.allProjects"), selection: $selectedProjectID) {
                Text(AppCopy.text("archive.allProjects")).tag("all")
                ForEach(archivedProjects) { project in
                    Text(project.title).tag(project.id)
                }
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "folder")
                Text(selectedProjectTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 46)
            .padding(.horizontal, 14)
            .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var selectedProjectTitle: String {
        guard selectedProjectID != "all",
              let project = archivedProjects.first(where: { $0.id == selectedProjectID }) else {
            return AppCopy.text("archive.allProjects")
        }
        return project.title
    }

    private var retentionControl: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 4) {
                Text(AppCopy.text("archive.autoDelete"))
                    .font(.headline)
                Text(AppCopy.text("archive.retentionHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker(AppCopy.text("archive.autoDelete"), selection: $retentionDays) {
                Text(AppCopy.text("archive.retentionNever")).tag(0)
                ForEach(ConversationArchiveRetention.dayOptions, id: \.self) { days in
                    Text(AppCopy.format("archive.retentionDays", days)).tag(days)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    private func archivedProjectCard(_ project: ConversationArchiveProject) -> some View {
        VStack(spacing: 0) {
            Button {
                if collapsedProjectIDs.contains(project.id) {
                    collapsedProjectIDs.remove(project.id)
                } else {
                    collapsedProjectIDs.insert(project.id)
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "folder")
                        .font(.title3)
                        .foregroundStyle(.primary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.title)
                            .font(.headline)
                        if let path = project.path {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(AppCopy.format("archive.conversationCount", project.conversations.count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsedProjectIDs.contains(project.id) ? -90 : 0))
                        .animation(.easeInOut(duration: 0.18), value: collapsedProjectIDs.contains(project.id))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(AppCopy.text("archive.toggleProject"))

            if !collapsedProjectIDs.contains(project.id) {
                VStack(spacing: 0) {
                    ForEach(Array(project.conversations.enumerated()), id: \.element.id) { index, conversation in
                        archivedConversationRow(conversation, bridge: model.bridge)
                        if index < project.conversations.count - 1 {
                            Divider().padding(.leading, 18)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.secondary.opacity(0.17), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 17))
        .animation(.easeInOut(duration: 0.18), value: collapsedProjectIDs.contains(project.id))
    }

    private func archivedConversationRow(_ conversation: Conversation, bridge: AgentBridge) -> some View {
        HStack(spacing: 14) {
            Button {
                selectedTranscript = bridge.loadArchivedConversation(conversation.id)
                isLoadingOlderArchiveMessages = false
                olderArchivePageAnchorID = nil
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(conversation.displayTitle)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(conversation.activityDate.formatted(
                        Date.FormatStyle(date: .abbreviated, time: .shortened, locale: AppCopy.locale)
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(AppCopy.text("common.view"))

            if conversation.pinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(AppCopy.text("sidebar.pinned"))
            }

            Button {
                pendingDeletion = .conversation(conversation.id)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 28, height: 30)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(AppCopy.text("sidebar.deleteChat"))
            .accessibilityLabel(AppCopy.text("sidebar.deleteChat"))

            Button {
                bridge.setArchived(conversation.id, archived: false)
            } label: {
                Text(AppCopy.text("sidebar.unarchiveChat"))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
    }

    private func emptyState(_ key: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(AppCopy.text(key))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    @ViewBuilder
    private func transcriptView(_ conversation: Conversation, bridge: AgentBridge) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    selectedTranscript = nil
                } label: {
                    Label(AppCopy.text("archive.title"), systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button {
                    bridge.setArchived(conversation.id, archived: false)
                    selectedTranscript = nil
                } label: {
                    Label(AppCopy.text("sidebar.unarchiveChat"), systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    pendingDeletion = .conversation(conversation.id)
                } label: {
                    Label(AppCopy.text("sidebar.deleteChat"), systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }

            Text(conversation.displayTitle)
                .font(.title2.weight(.semibold))
                .lineLimit(2)

            if let cwd = conversation.cwd, !cwd.isEmpty {
                Text(cwd)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if conversation.hasOlderTranscriptMessages {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .onAppear {
                                    loadOlderArchiveMessages(conversation, bridge: bridge)
                                }
                        }
                        ForEach(conversation.messages) { message in
                            Group {
                                if message.kind == .tool {
                                    DisclosureGroup {
                                        Text(toolDetails(message))
                                            .font(.callout.monospaced())
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    } label: {
                                        Label(toolSummary(message.text), systemImage: "wrench.and.screwdriver")
                                            .lineLimit(1)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                } else {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(speakerLabel(message.kind))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)

                                        Text(messageBody(message))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                            .id(message.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .defaultScrollAnchor(.bottom)
                .onAppear {
                    if let lastMessageID = conversation.messages.last?.id {
                        proxy.scrollTo(lastMessageID, anchor: .bottom)
                    }
                }
                .onChange(of: conversation.messages.count) { _, _ in
                    guard let anchorID = olderArchivePageAnchorID else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(anchorID, anchor: .top)
                        if olderArchivePageAnchorID == anchorID { olderArchivePageAnchorID = nil }
                    }
                }
            }
        }
    }

    private func loadOlderArchiveMessages(_ conversation: Conversation, bridge: AgentBridge) {
        guard !isLoadingOlderArchiveMessages,
              conversation.hasOlderTranscriptMessages else { return }
        isLoadingOlderArchiveMessages = true
        let endIndex = conversation.messageStartIndex
        olderArchivePageAnchorID = conversation.messages.first?.id
        Task { @MainActor in
            guard let page = await bridge.loadArchivedMessagePage(
                id: conversation.id,
                endingBefore: endIndex,
                limit: 10
            ),
            selectedTranscript?.id == conversation.id,
            selectedTranscript?.messageStartIndex == endIndex,
            var updated = selectedTranscript else {
                isLoadingOlderArchiveMessages = false
                olderArchivePageAnchorID = nil
                return
            }
            let currentIDs = Set(updated.messages.map(\.id))
            let older = page.messages.filter { !currentIDs.contains($0.id) }
            updated.messages.insert(contentsOf: older, at: 0)
            updated.loadedTranscriptMessageIDs.formUnion(page.messages.map(\.id))
            updated.messageStartIndex = page.startIndex
            updated.transcriptComplete = page.startIndex == 0
            selectedTranscript = updated
            isLoadingOlderArchiveMessages = false
        }
    }

    private func speakerLabel(_ kind: ChatMessage.Kind) -> String {
        switch kind {
        case .user: AppCopy.text("conversation.you")
        case .assistant: AppCopy.text("conversation.assistant")
        case .plan: AppCopy.text("conversation.plan")
        case .tool: AppCopy.text("conversation.tool")
        case .system: AppCopy.text("conversation.system")
        }
    }

    private func messageBody(_ message: ChatMessage) -> String {
        let body = ([message.text] + message.attachments.map(\.name))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return body.isEmpty ? "—" : body
    }

    private func toolSummary(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let summary = String(firstLine.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        return summary.isEmpty ? AppCopy.text("conversation.tool") : summary
    }

    private func toolDetails(_ message: ChatMessage) -> String {
        if let output = message.rawToolOutput, !output.isEmpty { return output }
        return message.text
    }
}

struct MemoryTransferView: View {
    let bridge: AgentBridge
    @State private var status = ""
    @State private var error = ""

    var body: some View {
        Form {
            Section {
                Text(AppCopy.text("memory.transfer.description"))
                    .foregroundStyle(.secondary)
            }
            Section(AppCopy.text("memory.transfer.project")) {
                Text(AppCopy.text("memory.transfer.projectHelp"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(AppCopy.text("memory.transfer.export")) { export(.project) }
                        .disabled(bridge.workspacePath == nil)
                    Button(AppCopy.text("memory.transfer.import")) { importArchive(.project) }
                        .disabled(bridge.workspacePath == nil)
                }
            }
            Section(AppCopy.text("memory.transfer.personal")) {
                Text(AppCopy.text("memory.transfer.personalHelp"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(AppCopy.text("memory.transfer.export")) { export(.personal) }
                    Button(AppCopy.text("memory.transfer.import")) { importArchive(.personal) }
                }
            }
            if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(AppCopy.text("memory.transfer.title"))
    }

    private func export(_ scope: MemoryTransferScope) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = scope == .project ? "project-memory.dotsmemory.json" : "personal-memory.dotsmemory.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try bridge.exportMemory(scope).write(to: destination, options: .atomic)
            status = AppCopy.text("memory.transfer.exported")
            error = ""
        } catch {
            self.error = error.localizedDescription
            status = ""
        }
    }

    private func importArchive(_ scope: MemoryTransferScope) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let count = try bridge.importMemory(Data(contentsOf: source), scope: scope)
            status = AppCopy.text("memory.transfer.imported") + " (\(count))"
            error = ""
        } catch {
            self.error = error.localizedDescription
            status = ""
        }
    }
}
