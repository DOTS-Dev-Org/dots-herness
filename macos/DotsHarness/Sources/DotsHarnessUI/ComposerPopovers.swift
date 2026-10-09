// Copyright (c) 2026 DOTS
// Composer popovers: project, work location, git branch, attachments, permissions.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore
import HarnessPluginKit

enum WorkLocationOption: String, Identifiable {
    case local
    case localWorktree

    static let localCases: [WorkLocationOption] = [.local, .localWorktree]

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .local: return "laptopcomputer"
        case .localWorktree: return "arrow.up.right.square"
        }
    }

    var setting: WorkLocationSetting {
        switch self {
        case .local: return .local
        case .localWorktree: return .localWorktree
        }
    }

    var title: String { AppCopy.text("workLocation.\(rawValue)") }
    var detail: String { AppCopy.text("workLocation.\(rawValue)Detail") }
}

struct ProjectPickerPopover: View {
    let workspacePath: String
    var projects: [String] = []
    var projectTitle: ((String) -> String)? = nil
    var onSelect: ((String) -> Void)? = nil
    let onChoose: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AppCopy.text("composer.projectPickerTitle"))
                .font(.headline)
                .padding(.horizontal, 9)
                .padding(.top, 7)
                .padding(.bottom, 5)

            if projects.isEmpty {
                if workspacePath.isEmpty {
                    Text(AppCopy.text("composer.noProject"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                } else {
                    projectRowContent(path: workspacePath, isSelected: true)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(projects, id: \.self) { path in
                            let isSelected = ConversationStore.normalizedPath(path) == ConversationStore.normalizedPath(workspacePath)
                            Button {
                                onSelect?(path)
                            } label: {
                                projectRowContent(path: path, isSelected: isSelected)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            Divider().padding(.vertical, 5)

            projectAction(icon: "plus", title: AppCopy.text("composer.chooseProject"), action: onChoose)
            projectAction(
                icon: "bubble.left.and.bubble.right",
                title: AppCopy.text("composer.dontWorkInProject"),
                action: onClear
            )
            .disabled(workspacePath.isEmpty)
            .opacity(workspacePath.isEmpty ? 0.45 : 1)
        }
        .padding(8)
        .frame(width: 360)
    }

    private func projectRowContent(path: String, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 17)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(projectTitle?(path) ?? URL(fileURLWithPath: path).lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(isSelected ? Color.primary.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }

    private func projectAction(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 17)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct WorkLocationPopover: View {
    let selection: WorkLocationSetting
    let hosts: [SSHHost]
    let sshAvailable: Bool
    let remotePath: String?
    let onSelect: (WorkLocationSetting) -> Void
    let onManageHosts: () -> Void
    let onChooseFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AppCopy.text("workLocation.title"))
                .font(.headline)
                .padding(.horizontal, 9)
                .padding(.top, 7)
                .padding(.bottom, 5)

            ForEach(WorkLocationOption.localCases) { option in
                row(
                    icon: option.icon,
                    title: option.title,
                    detail: option.detail,
                    isSelected: selection == option.setting,
                    isEnabled: true
                ) { onSelect(option.setting) }
            }

            Divider().padding(.vertical, 5)

            Text(AppCopy.text("workLocation.remoteHosts"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.bottom, 2)

            if !sshAvailable {
                Text(AppCopy.text("ssh.error.unavailable"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
            } else if hosts.isEmpty {
                Text(AppCopy.text("workLocation.noHosts"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
            } else {
                ForEach(hosts) { host in
                    row(
                        icon: "network",
                        title: host.alias,
                        detail: detail(for: host),
                        isSelected: selection.remoteAlias == host.alias,
                        isEnabled: true
                    ) { onSelect(.remote(alias: host.alias)) }
                }
            }

            if selection.isRemote {
                action(icon: "folder", title: AppCopy.text("workLocation.chooseRemoteFolder"), action: onChooseFolder)
            }
            action(icon: "plus", title: AppCopy.text("workLocation.addHost"), action: onManageHosts)
        }
        .padding(8)
        .frame(width: 350)
    }

    private func detail(for host: SSHHost) -> String {
        guard selection.remoteAlias == host.alias, let remotePath, !remotePath.isEmpty else {
            return host.displayDestination
        }
        return "\(host.displayDestination) · \(remotePath)"
    }

    private func row(
        icon: String,
        title: String,
        detail: String,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 17)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(isSelected ? .medium : .regular))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.primary.opacity(0.10) : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private func action(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 17)
                    .foregroundStyle(.secondary)
                Text(title).font(.callout)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct GitBranchPopover: View {
    let snapshot: GitSnapshot
    let error: String?
    let busy: Bool
    let onSelect: (String) -> Void
    let onSelectRemote: (String) -> Void
    let onCreate: () -> Void
    let onFetch: () -> Void
    let onPush: () -> Void

    @State private var searchText = ""

    private var filteredBranches: [String] {
        guard !searchText.isEmpty else { return snapshot.branches }
        return snapshot.branches.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredRemoteBranches: [String] {
        guard !searchText.isEmpty else { return snapshot.remoteBranches }
        return snapshot.remoteBranches.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(AppCopy.text("git.search"), text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(AppCopy.text("git.branches"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.top, 5)

            if filteredBranches.isEmpty {
                Text(AppCopy.text("git.noBranches"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ForEach(filteredBranches, id: \.self) { branch in
                    Button {
                        onSelect(branch)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(width: 17)
                                    .foregroundStyle(.secondary)
                                Text(branch)
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if branch == snapshot.currentBranch {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if branch == snapshot.currentBranch, snapshot.uncommittedCount > 0 {
                                Text(AppCopy.format("git.uncommitted", snapshot.uncommittedCount))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 27)
                            }
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            branch == snapshot.currentBranch ? Color.primary.opacity(0.10) : .clear,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if !filteredRemoteBranches.isEmpty {
                Text(AppCopy.text("git.remoteBranches"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.top, 5)

                ForEach(filteredRemoteBranches, id: \.self) { branch in
                    Button {
                        onSelectRemote(branch)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "cloud")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 17)
                                .foregroundStyle(.secondary)
                            Text(branch)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
            }

            Divider().padding(.vertical, 5)

            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppCopy.text("git.working"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
            } else {
                actionRow(icon: "arrow.down.circle", title: AppCopy.text("git.fetch"), action: onFetch)
                    .disabled(!snapshot.hasRemote)
                    .opacity(snapshot.hasRemote ? 1 : 0.45)
                actionRow(icon: "arrow.up.circle", title: AppCopy.text("git.push"), action: onPush)
                    .disabled(!snapshot.hasRemote || snapshot.currentBranch == nil)
                    .opacity(snapshot.hasRemote && snapshot.currentBranch != nil ? 1 : 0.45)
                actionRow(icon: "plus", title: AppCopy.text("git.createBranch"), action: onCreate)
            }
        }
        .padding(8)
        .frame(width: 360)
    }

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 17)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AttachmentMenu: View {
    let onChooseFiles: () -> Void
    let onChooseWorkspace: () -> Void
    let showsWorkspace: Bool
    let onOpenSkills: () -> Void
    let onSetGoal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AppCopy.text("composer.add"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.bottom, 4)
            attachmentRow(icon: "paperclip", title: AppCopy.text("attachment.files"), action: onChooseFiles)
            attachmentRow(icon: "rectangle.stack", title: AppCopy.text("attachment.addApp")) {}
            if showsWorkspace {
                attachmentRow(icon: "folder", title: AppCopy.text("attachment.project"), detail: AppCopy.text("attachment.projectDetail"), action: onChooseWorkspace)
            }
            attachmentRow(icon: "scope", title: AppCopy.text("attachment.goal"), detail: AppCopy.text("attachment.goalDetail"), action: onSetGoal)
            attachmentRow(icon: "target", title: AppCopy.text("attachment.saveSkill"), action: onOpenSkills)

            Divider().padding(.vertical, 5)
            Text(AppCopy.text("attachment.plugins"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
            attachmentRow(icon: "doc.text", title: "Documents", detail: AppCopy.text("attachment.documentsDetail")) {}
            attachmentRow(icon: "doc.richtext", title: "PDF", detail: AppCopy.text("attachment.pdfDetail")) {}
            attachmentRow(icon: "tablecells", title: "Spreadsheets", detail: AppCopy.text("attachment.spreadsheetsDetail")) {}
        }
        .padding(8)
        .frame(width: 395)
    }

    private func attachmentRow(
        icon: String,
        title: String,
        detail: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 17)
                    .foregroundStyle(.secondary)
                Text(title)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .frame(minHeight: 29)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PermissionMenu: View {
    @Binding var selection: AgentPermissionMode

    private var helpURL: URL? {
        var components = URLComponents(string: "https://dots.net.tr/harness/sandboxing")
        components?.queryItems = [URLQueryItem(name: "lang", value: AppCopy.effectiveLanguage.rawValue)]
        return components?.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(AppCopy.text("permission.title"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let helpURL {
                    Link(destination: helpURL) {
                        Text(AppCopy.text("permission.moreInfo"))
                            .font(.caption)
                            .underline()
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            ForEach(AgentPermissionMode.allCases) { level in
                Button {
                    selection = level
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: level.icon)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 17)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.title)
                                .font(.callout.weight(level == selection ? .medium : .regular))
                            Text(level.detail)
                                .font(.caption)
                                .foregroundStyle(level == .full ? Color.orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if level == selection {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(level == .full ? Color.orange : .secondary)
                        }
                    }
                    .foregroundStyle(level == .full ? Color.orange : .primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        level == selection ? Color.primary.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 475)
    }
}
