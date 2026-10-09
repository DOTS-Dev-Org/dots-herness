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
    @State private var selectedTranscript: Conversation?

    private var archivedConversations: [Conversation] {
        model.bridge.archivedConversations.sorted {
            $0.activityDate > $1.activityDate
        }
    }

    var body: some View {
        Group {
            if let selectedTranscript {
                transcriptView(selectedTranscript, bridge: model.bridge)
            } else {
                Form {
                    conversationSection(
                        conversations: archivedConversations,
                        bridge: model.bridge
                    )
                }
                .formStyle(.grouped)
            }
        }
        .padding()
        .navigationTitle(AppCopy.text("archive.title"))
        // Conversation delete confirmation
        .confirmationDialog(
            AppCopy.text("archive.confirmDelete"),
            isPresented: Binding(
                get: { pendingDeleteConversationID != nil },
                set: { if !$0 { pendingDeleteConversationID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(AppCopy.text("archive.deletePermanently"), role: .destructive) {
                if let id = pendingDeleteConversationID {
                    model.bridge.deleteConversation(id)
                    if selectedTranscript?.id == id { selectedTranscript = nil }
                }
                pendingDeleteConversationID = nil
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) {
                pendingDeleteConversationID = nil
            }
        }
    }

    // MARK: - Shared conversation section

    @ViewBuilder
    private func conversationSection(conversations: [Conversation], bridge: AgentBridge) -> some View {
        Section(AppCopy.text("archive.title")) {
            if conversations.isEmpty {
                Text(AppCopy.text("archive.empty"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(conversations) { conversation in
                    HStack(spacing: 10) {
                        statusIcon(conversation)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(conversation.title)
                                .lineLimit(1)
                            if let cwd = conversation.cwd, !cwd.isEmpty {
                                Text(cwd)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            selectedTranscript = bridge.loadArchivedConversation(conversation.id)
                        } label: {
                            Label(AppCopy.text("common.view"), systemImage: "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(AppCopy.text("common.view"))
                        .accessibilityLabel(AppCopy.text("common.view"))

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
                    pendingDeleteConversationID = conversation.id
                } label: {
                    Label(AppCopy.text("sidebar.deleteChat"), systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }

            Text(conversation.title)
                .font(.title2.weight(.semibold))
                .lineLimit(2)

            if let cwd = conversation.cwd, !cwd.isEmpty {
                Text(cwd)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(conversation.messages) { message in
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
                }
                .padding(.vertical, 2)
            }
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
