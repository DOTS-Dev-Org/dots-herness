// Copyright (c) 2026 DOTS
// Conversation archive and workspace access settings panes.

import AppKit
import UniformTypeIdentifiers
import SwiftUI
import HarnessPluginKit
import DotsHarnessCore
import PluginRuntime

struct ConversationArchiveView: View {
    @ObservedObject var model: AppModel
    @State private var pendingDeleteConversationID: String?
    @State private var pendingDeleteProjectID: String?

    // MARK: - Chat area data

    private var archivedProjects: [ChatProject] {
        model.chatProjects
            .filter(\.archived)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var archivedChatConversations: [Conversation] {
        // Only standalone (unassigned) archived chat conversations.
        // Conversations that belong to an archived project are shown
        // under their project row, not listed separately here.
        let archivedProjectIDs = Set(archivedProjects.map(\.id))
        return model.chatBridge.archivedConversations
            .filter { conv in
                guard let pid = conv.chatProjectID else { return true }
                return !archivedProjectIDs.contains(pid)
            }
            .sorted {
                ($0.messages.map(\.createdAt).max() ?? .distantPast)
                    > ($1.messages.map(\.createdAt).max() ?? .distantPast)
            }
    }

    // MARK: - Coding area data

    private var archivedCodingConversations: [Conversation] {
        model.codingBridge.archivedConversations.sorted {
            ($0.messages.map(\.createdAt).max() ?? .distantPast)
                > ($1.messages.map(\.createdAt).max() ?? .distantPast)
        }
    }

    private var isChat: Bool { model.activeArea == .chat }

    var body: some View {
        Form {
            if isChat {
                chatArchiveContent
            } else {
                conversationSection(
                    conversations: archivedCodingConversations,
                    bridge: model.codingBridge
                )
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(AppCopy.text("sidebar.archived"))
        // Conversation delete confirmation
        .confirmationDialog(
            AppCopy.text("sidebar.deleteChat"),
            isPresented: Binding(
                get: { pendingDeleteConversationID != nil },
                set: { if !$0 { pendingDeleteConversationID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(AppCopy.text("sidebar.deleteChat"), role: .destructive) {
                if let id = pendingDeleteConversationID {
                    model.bridge.deleteConversation(id)
                }
                pendingDeleteConversationID = nil
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) {
                pendingDeleteConversationID = nil
            }
        }
        // Project delete confirmation
        .confirmationDialog(
            AppCopy.text("sidebar.deleteProject"),
            isPresented: Binding(
                get: { pendingDeleteProjectID != nil },
                set: { if !$0 { pendingDeleteProjectID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(AppCopy.text("sidebar.deleteProject"), role: .destructive) {
                if let id = pendingDeleteProjectID {
                    model.deleteChatProject(id)
                }
                pendingDeleteProjectID = nil
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) {
                pendingDeleteProjectID = nil
            }
        }
    }

    // MARK: - Chat archive content

    @ViewBuilder
    private var chatArchiveContent: some View {
        Section(AppCopy.text("sidebar.projects")) {
            if archivedProjects.isEmpty {
                Text(AppCopy.text("sidebar.noChats"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(archivedProjects) { project in
                    HStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .lineLimit(1)
                            let count = model.chatConversations(in: project.id).count
                            if count > 0 {
                                Text("\(count) chat\(count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if project.pinned {
                            Image(systemName: "pin.fill")
                                .foregroundStyle(Color.accentColor)
                        }

                        Button {
                            model.setChatProjectArchived(project.id, archived: false)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .help(AppCopy.text("sidebar.unarchiveProject"))
                        .accessibilityLabel(AppCopy.text("sidebar.unarchiveProject"))

                        Button {
                            pendingDeleteProjectID = project.id
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help(AppCopy.text("sidebar.deleteProject"))
                        .accessibilityLabel(AppCopy.text("sidebar.deleteProject"))
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        conversationSection(
            conversations: archivedChatConversations,
            bridge: model.chatBridge
        )
    }

    // MARK: - Shared conversation section

    @ViewBuilder
    private func conversationSection(conversations: [Conversation], bridge: AgentBridge) -> some View {
        Section(AppCopy.text("sidebar.archived")) {
            if conversations.isEmpty {
                Text(AppCopy.text("sidebar.noChats"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(conversations) { conversation in
                    HStack(spacing: 10) {
                        statusIcon(conversation)

                        Text(conversation.title)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if conversation.pinned {
                            Image(systemName: "pin.fill")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel(AppCopy.text("sidebar.pinChat"))
                        }

                        Button {
                            bridge.setArchived(conversation.id, archived: false)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .help(AppCopy.text("sidebar.unarchiveChat"))
                        .accessibilityLabel(AppCopy.text("sidebar.unarchiveChat"))

                        Button {
                            pendingDeleteConversationID = conversation.id
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help(AppCopy.text("sidebar.deleteChat"))
                        .accessibilityLabel(AppCopy.text("sidebar.deleteChat"))
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ conversation: Conversation) -> some View {
        if conversation.running {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
                .accessibilityLabel(AppCopy.text("sidebar.chatRunning"))
        } else if !conversation.blank {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.blue)
                .accessibilityLabel(AppCopy.text("sidebar.chatCompleted"))
        }
    }
}

struct WorkspaceAccessView: View {
    let bridge: AgentBridge
    @State private var inviteName = ""
    @State private var invitePublicKey = ""
    @State private var inviteRole: MemoryRole = .contributor
    @State private var inviteScore = 50
    @State private var inviteToken = ""
    @State private var acceptedToken = ""
    @State private var error = ""

    var body: some View {
        Form {
            let access = bridge.workspaceAccess
            Section(AppCopy.text("access.currentActor")) {
                LabeledContent(AppCopy.text("access.role")) { Text(access.role?.title ?? AppCopy.text("access.notAuthorized")) }
                LabeledContent(AppCopy.text("access.score")) { Text(String(access.score)) }
                LabeledContent(AppCopy.text("access.device")) {
                    Text(access.deviceID.isEmpty ? "—" : String(access.deviceID.prefix(20)))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let publicKey = bridge.memoryDevicePublicKey {
                    LabeledContent(AppCopy.text("access.publicKey")) {
                        Text(publicKey).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
                LabeledContent(AppCopy.text("access.memoryRevision")) { Text(String(access.revision)) }
            }

            Section(AppCopy.text("access.members")) {
                if bridge.workspaceMembers.isEmpty {
                    Text(AppCopy.text("access.noMembers"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bridge.workspaceMembers.indices, id: \.self) { index in
                        let member = bridge.workspaceMembers[index]
                        HStack {
                            VStack(alignment: .leading) {
                                Text(member["displayName"] ?? member["personId"] ?? AppCopy.text("access.unknown"))
                                Text("\(localizedRole(member["role"])) · \(member["score"] ?? "0") · \(String((member["deviceId"] ?? "").prefix(12)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if member["deviceId"] != access.deviceID,
                               access.role == .owner,
                               member["revoked"] != "true" {
                                Button(AppCopy.text("access.revoke"), role: .destructive) {
                                    do { try bridge.revokeWorkspaceDevice(member["deviceId"] ?? "") }
                                    catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                    }
                }
            }

            Section(AppCopy.text("access.inviteDevice")) {
                TextField(AppCopy.text("access.displayName"), text: $inviteName)
                TextField(AppCopy.text("access.newDevicePublicKey"), text: $invitePublicKey)
                    .font(.caption.monospaced())
                Picker(AppCopy.text("access.role"), selection: $inviteRole) {
                    ForEach(MemoryRole.allCases, id: \.self) { role in Text(role.title).tag(role) }
                }
                Stepper(AppCopy.format("access.scoreValue", inviteScore), value: $inviteScore, in: 0...100)
                Button(AppCopy.text("access.createInvitation")) {
                    do {
                        inviteToken = try bridge.createWorkspaceInvite(
                            displayName: inviteName,
                            role: inviteRole,
                            score: inviteScore,
                            publicKey: invitePublicKey
                        )
                        error = ""
                    } catch let caught { error = caught.localizedDescription }
                }
                .disabled(access.role != .owner || inviteName.isEmpty || invitePublicKey.isEmpty)
                if !inviteToken.isEmpty {
                    Text(inviteToken)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section(AppCopy.text("access.acceptInvitation")) {
                TextField(AppCopy.text("access.signedInvitation"), text: $acceptedToken, axis: .vertical)
                Button(AppCopy.text("access.accept")) {
                    do {
                        try bridge.acceptWorkspaceInvite(acceptedToken)
                        acceptedToken = ""
                        error = ""
                    } catch let caught { error = caught.localizedDescription }
                }
                .disabled(acceptedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section(AppCopy.text("access.pendingDecisions")) {
                if bridge.pendingWorkspaceDecisions.isEmpty {
                    Text(AppCopy.text("access.noPendingDecisions")).foregroundStyle(.secondary)
                } else {
                    ForEach(bridge.pendingWorkspaceDecisions.indices, id: \.self) { index in
                        let proposal = bridge.pendingWorkspaceDecisions[index]
                        let eventID = proposal["eventId"] as? String ?? ""
                        let payload = proposal["payload"] as? [String: Any]
                        VStack(alignment: .leading, spacing: 6) {
                            Text(payload?["summary"] as? String ?? eventID)
                            HStack {
                                Button(AppCopy.text("access.accept")) {
                                    do { try bridge.resolveWorkspaceDecision(eventID, accept: true) }
                                    catch { self.error = error.localizedDescription }
                                }
                                Button(AppCopy.text("access.reject"), role: .destructive) {
                                    do { try bridge.resolveWorkspaceDecision(eventID, accept: false) }
                                    catch { self.error = error.localizedDescription }
                                }
                            }
                            .disabled(bridge.workspaceAccess.role?.rank ?? 0 < MemoryRole.approver.rank)
                        }
                    }
                }
            }

            if !error.isEmpty {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(AppCopy.text("settings.tab.access"))
    }

    private func localizedRole(_ rawValue: String?) -> String {
        guard let rawValue, let role = MemoryRole(rawValue: rawValue) else {
            return rawValue ?? AppCopy.text("access.unknown")
        }
        return role.title
    }
}
